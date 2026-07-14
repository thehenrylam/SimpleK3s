#!/bin/bash

# Set bash flags
set -euo pipefail
# -u            : Error if an unset variable is referenced
# -e            : Exits on ANY command failure
# -o pipefail   : Make pipeline fail if any command in them fails

# Point-in-time cluster health check. Runs all checks and accumulates failures
# rather than exiting on the first one, so a single run gives the full picture.
# Exit 0 = all checks passed; exit 1 = one or more checks failed.
#
# Run via SSM on node-0 after convergence to confirm the cluster is healthy:
#   aws ssm send-command --instance-ids <node-0-id> \
#     --document-name AWS-RunShellScript \
#     --parameters commands=["/opt/simplek3s/bootstrap/default/verify_cluster.sh"]
#
# Environment variables:
#   STABILITY_WINDOW_SECONDS  How far back to look for pod restarts (default: 300)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

STABILITY_WINDOW_SECONDS="${STABILITY_WINDOW_SECONDS:-300}"

VERIFY_FAILURES=0

function verify_pass() {
    log_okay "  PASS: $1"
}

function verify_fail() {
    log_fail "  FAIL: $1"
    VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
}

# Returns 0 if the rollout is currently complete, 1 if not.
# Usage: rollout_ready <namespace> <type> <name>
# --timeout=5s: if ready, kubectl returns immediately; if not, we wait up to 5s.
function rollout_ready() {
    local NS="$1" TYPE="$2" NAME="$3"
    sudo kubectl -n "$NS" rollout status "${TYPE}/${NAME}" --timeout=5s >/dev/null 2>&1
}

# ─── K3s API ─────────────────────────────────────────────────────────────────

function check_k3s_api() {
    log_info "--- K3s API ---"
    if sudo kubectl get --raw=/readyz >/dev/null 2>&1; then
        verify_pass "K3s API is reachable"
    else
        verify_fail "K3s API is not reachable"
    fi
}

# ─── Nodes ───────────────────────────────────────────────────────────────────

function check_nodes_ready() {
    log_info "--- Nodes ---"
    local NOT_READY
    NOT_READY="$(sudo kubectl get nodes --no-headers 2>/dev/null \
        | grep -v " Ready" || true)"
    if [[ -z "$NOT_READY" ]]; then
        verify_pass "All nodes are Ready"
    else
        verify_fail "Some nodes are not Ready"
        echo "$NOT_READY"
    fi
}

# ─── kube-system ─────────────────────────────────────────────────────────────

function check_kube_system() {
    log_info "--- kube-system ---"
    local NS="kube-system"
    local DEPLOY
    for DEPLOY in coredns local-path-provisioner; do
        if rollout_ready "$NS" deploy "$DEPLOY"; then
            verify_pass "kube-system/$DEPLOY is ready"
        else
            verify_fail "kube-system/$DEPLOY is not ready"
        fi
    done
}

# ─── Traefik ─────────────────────────────────────────────────────────────────

function check_traefik() {
    if ! sudo kubectl -n kube-system get deploy traefik >/dev/null 2>&1; then
        log_info "--- Traefik: not deployed, skipping ---"
        return
    fi
    log_info "--- Traefik ---"
    if rollout_ready kube-system deploy traefik; then
        verify_pass "kube-system/traefik deployment is ready"
    else
        verify_fail "kube-system/traefik deployment is not ready"
    fi
    local RES
    for RES in "middleware/https-redirect" "ingressroute/web-http-catchall-redirect"; do
        if sudo kubectl -n kube-system get "$RES" >/dev/null 2>&1; then
            verify_pass "kube-system/$RES exists"
        else
            verify_fail "kube-system/$RES is missing"
        fi
    done
}

# ─── Kyverno ─────────────────────────────────────────────────────────────────

function check_kyverno() {
    if ! sudo kubectl get ns kyverno >/dev/null 2>&1; then
        log_info "--- Kyverno: not deployed, skipping ---"
        return
    fi
    log_info "--- Kyverno ---"
    local NS="kyverno"
    local DEPLOYS=(
        "kyverno-admission-controller"
        "kyverno-background-controller"
        "kyverno-cleanup-controller"
    )
    local D
    for D in "${DEPLOYS[@]}"; do
        if rollout_ready "$NS" deploy "$D"; then
            verify_pass "kyverno/$D is ready"
        else
            verify_fail "kyverno/$D is not ready"
        fi
    done
    local CRD
    for CRD in clusterpolicies.kyverno.io policies.kyverno.io; do
        if sudo kubectl get crd "$CRD" >/dev/null 2>&1; then
            verify_pass "CRD $CRD exists"
        else
            verify_fail "CRD $CRD is missing"
        fi
    done
}

# ─── Longhorn ────────────────────────────────────────────────────────────────

function check_longhorn() {
    if ! sudo kubectl get ns longhorn-system >/dev/null 2>&1; then
        log_info "--- Longhorn: not deployed, skipping ---"
        return
    fi
    log_info "--- Longhorn ---"
    local NS="longhorn-system"
    local DS
    for DS in longhorn-manager longhorn-csi-plugin; do
        if rollout_ready "$NS" daemonset "$DS"; then
            verify_pass "longhorn-system/$DS daemonset is ready"
        else
            verify_fail "longhorn-system/$DS daemonset is not ready"
        fi
    done
    local NODES
    NODES="$(sudo kubectl get nodes -o jsonpath='{.items[*].metadata.name}')"
    local NODE
    for NODE in $NODES; do
        if sudo kubectl get csinode "$NODE" \
            -o jsonpath='{.spec.drivers[*].name}' 2>/dev/null \
            | grep -q 'driver.longhorn.io'; then
            verify_pass "Node $NODE: driver.longhorn.io CSI registered"
        else
            verify_fail "Node $NODE: driver.longhorn.io CSI not registered"
        fi
    done
}

# ─── External Secrets ────────────────────────────────────────────────────────

function check_external_secrets() {
    if ! sudo kubectl get ns external-secrets >/dev/null 2>&1; then
        log_info "--- External Secrets: not deployed, skipping ---"
        return
    fi
    log_info "--- External Secrets ---"
    local NS="external-secrets"
    if rollout_ready "$NS" deploy external-secrets; then
        verify_pass "external-secrets/external-secrets deployment is ready"
    else
        verify_fail "external-secrets/external-secrets deployment is not ready"
    fi
    local CRD
    for CRD in \
        externalsecrets.external-secrets.io \
        secretstores.external-secrets.io \
        clustersecretstores.external-secrets.io; do
        if sudo kubectl get crd "$CRD" >/dev/null 2>&1; then
            verify_pass "CRD $CRD exists"
        else
            verify_fail "CRD $CRD is missing"
        fi
    done
}

# ─── Karpenter ───────────────────────────────────────────────────────────────

function check_karpenter() {
    if ! sudo kubectl get crd nodepools.karpenter.sh >/dev/null 2>&1; then
        log_info "--- Karpenter: not deployed, skipping ---"
        return
    fi
    log_info "--- Karpenter ---"
    if rollout_ready kube-system deploy karpenter; then
        verify_pass "kube-system/karpenter deployment is ready"
    else
        verify_fail "kube-system/karpenter deployment is not ready"
    fi
    local CRD
    for CRD in \
        ec2nodeclasses.karpenter.k8s.aws \
        nodepools.karpenter.sh \
        nodeclaims.karpenter.sh; do
        if sudo kubectl get crd "$CRD" >/dev/null 2>&1; then
            verify_pass "CRD $CRD exists"
        else
            verify_fail "CRD $CRD is missing"
        fi
    done
}

# ─── Descheduler ─────────────────────────────────────────────────────────────

function check_descheduler() {
    if ! sudo kubectl -n kube-system get cronjob descheduler >/dev/null 2>&1; then
        log_info "--- Descheduler: not deployed, skipping ---"
        return
    fi
    log_info "--- Descheduler ---"
    verify_pass "kube-system/descheduler CronJob exists"
}

# ─── Tailscale ───────────────────────────────────────────────────────────────

function check_tailscale() {
    if ! sudo kubectl get ns tailscale >/dev/null 2>&1; then
        log_info "--- Tailscale: not deployed, skipping ---"
        return
    fi
    log_info "--- Tailscale ---"
    local NS="tailscale"
    if rollout_ready "$NS" deploy operator; then
        verify_pass "tailscale/operator deployment is ready"
    else
        verify_fail "tailscale/operator deployment is not ready"
    fi
    if sudo kubectl get ingressclass tailscale >/dev/null 2>&1; then
        verify_pass "IngressClass 'tailscale' exists"
    else
        verify_fail "IngressClass 'tailscale' is missing"
    fi
    if sudo kubectl wait --for=condition=ProxyClassReady proxyclass --all --timeout=5s >/dev/null 2>&1; then
        verify_pass "Tailscale ProxyClass is Ready"
    else
        verify_fail "Tailscale ProxyClass is not Ready"
    fi
    local SEL="tailscale.com/parent-resource=tailnet-entrypoint,tailscale.com/parent-resource-type=ingress"
    local SS_COUNT
    SS_COUNT="$(sudo kubectl -n "$NS" get statefulset -l "$SEL" -o name 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$SS_COUNT" -gt 0 ]]; then
        verify_pass "Tailscale proxy StatefulSet for tailnet-entrypoint exists"
    else
        verify_fail "Tailscale proxy StatefulSet for tailnet-entrypoint is missing"
    fi
}

# ─── ArgoCD ──────────────────────────────────────────────────────────────────

function check_argocd() {
    if ! sudo kubectl get ns argocd >/dev/null 2>&1; then
        log_info "--- ArgoCD: not deployed, skipping ---"
        return
    fi
    log_info "--- ArgoCD ---"
    local NS="argocd"
    if rollout_ready "$NS" deploy argocd-server; then
        verify_pass "argocd/argocd-server deployment is ready"
    else
        verify_fail "argocd/argocd-server deployment is not ready"
    fi
    if sudo kubectl -n "$NS" get secret argocd-oidc --ignore-not-found \
        -o jsonpath='{.data.oidc\.cognito\.issuer}' 2>/dev/null | grep -q .; then
        verify_pass "argocd/argocd-oidc secret has OIDC issuer populated"
    else
        verify_fail "argocd/argocd-oidc secret is missing or empty (ESO may still be syncing)"
    fi
}

# ─── Monitoring ──────────────────────────────────────────────────────────────

function check_monitoring() {
    if ! sudo kubectl get ns monitoring >/dev/null 2>&1; then
        log_info "--- Monitoring: not deployed, skipping ---"
        return
    fi
    log_info "--- Monitoring ---"
    local NS="monitoring"
    # Deployments: Prometheus operator and Grafana (release name: prometheus)
    local DEPLOY
    for DEPLOY in prometheus-kube-prometheus-operator prometheus-grafana; do
        if rollout_ready "$NS" deploy "$DEPLOY"; then
            verify_pass "monitoring/$DEPLOY is ready"
        else
            verify_fail "monitoring/$DEPLOY is not ready"
        fi
    done
    # StatefulSets: Prometheus and Alertmanager
    local STS
    for STS in \
        "prometheus-prometheus-kube-prometheus-prometheus" \
        "alertmanager-prometheus-kube-prometheus-alertmanager"; do
        if rollout_ready "$NS" statefulset "$STS"; then
            verify_pass "monitoring/$STS statefulset is ready"
        else
            verify_fail "monitoring/$STS statefulset is not ready"
        fi
    done
}

# ─── Pod stability ───────────────────────────────────────────────────────────

function check_pod_stability() {
    log_info "--- Pod stability (restarts in the last ${STABILITY_WINDOW_SECONDS}s) ---"

    local UNSTABLE_PODS
    UNSTABLE_PODS="$(sudo kubectl get pods -A -o json 2>/dev/null | python3 -c "
import json, sys, datetime

window = int('${STABILITY_WINDOW_SECONDS}')
now = datetime.datetime.now(datetime.timezone.utc)
cutoff = now - datetime.timedelta(seconds=window)

pods = json.load(sys.stdin)['items']
unstable = []

for pod in pods:
    ns = pod['metadata']['namespace']
    name = pod['metadata']['name']
    phase = pod.get('status', {}).get('phase', '')

    # Completed Jobs (Succeeded) are expected to have restart history
    if phase == 'Succeeded':
        continue

    for cs in pod.get('status', {}).get('containerStatuses', []):
        last = cs.get('lastState', {}).get('terminated', {})
        finished_at = last.get('finishedAt', '')
        if not finished_at:
            continue
        try:
            ts = datetime.datetime.fromisoformat(finished_at.replace('Z', '+00:00'))
        except ValueError:
            continue
        if ts > cutoff:
            unstable.append(
                f'{ns}/{name} (container: {cs[\"name\"]}, last restart: {finished_at})'
            )
            break

for line in unstable:
    print(line)
" 2>/dev/null || true)"

    if [[ -z "$UNSTABLE_PODS" ]]; then
        verify_pass "No pod restarts in the last ${STABILITY_WINDOW_SECONDS}s"
    else
        verify_fail "Pods with recent restarts (within ${STABILITY_WINDOW_SECONDS}s)"
        echo "$UNSTABLE_PODS"
    fi
}

# ─── Main ────────────────────────────────────────────────────────────────────

log_info "$0: LAUNCHED"
log_info "Stability window: ${STABILITY_WINDOW_SECONDS}s"

check_k3s_api
check_nodes_ready
check_kube_system
check_traefik
check_kyverno
check_longhorn
check_external_secrets
check_karpenter
check_descheduler
check_tailscale
check_argocd
check_monitoring
check_pod_stability

if [[ "$VERIFY_FAILURES" -gt 0 ]]; then
    log_fail "$0: FAILED ($VERIFY_FAILURES check(s) failed)"
    exit 1
fi

log_okay "$0: PASSED"
exit 0
