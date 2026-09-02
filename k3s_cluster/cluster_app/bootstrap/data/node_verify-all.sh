#!/bin/bash

# Set bash flags
set -euo pipefail
# -u            : Error if an unset variable is referenced
# -e            : Exits on ANY command failure
# -o pipefail   : Make pipeline fail if any command in them fails

# Point-in-time cluster health check. Runs all checks and accumulates failures
# rather than exiting on the first one, so a single run gives the full picture.
# Exit 0 = all checks passed; 1 = one or more checks failed; 2 = misconfigured.
#
# Run via SSM on node-0 after convergence to confirm the cluster is healthy:
#   aws ssm send-command --instance-ids <node-0-id> \
#     --document-name AWS-RunShellScript \
#     --parameters commands=["/opt/simplek3s/bootstrap/default/node_verify-all.sh"]
#
# Two output modes. Prose is the default, for a human reading the node's log.
# --json emits a machine-readable report on stdout (prose moves to stderr), and
# is what the host-side verify tool consumes so it reads fields instead of
# grepping log lines.
#
# Environment variables:
#   STABILITY_WINDOW_SECONDS  How far back to look for pod restarts (default: 300)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

function usage() {
    # Explicit --help goes to stdout and exits 0; usage shown because of an
    # error goes to stderr and exits 2.
    local _CODE="${1:-2}"
    local _FD=2
    (( _CODE == 0 )) && _FD=1
    {
        echo "Usage: $(basename "$0") [--json]"
        echo ""
        echo "  --json   Emit the report as JSON on stdout; all prose goes to"
        echo "           stderr. Field names are stable, and 'schema' is bumped"
        echo "           whenever they change."
        echo ""
        echo "Environment:"
        echo "  STABILITY_WINDOW_SECONDS           restart lookback (default: 300)"
        echo "  KARPENTER_NODECLAIM_STUCK_MINUTES  stuck NodeClaim threshold (default: 20)"
        echo ""
        echo "Exit: 0 every check passed; 1 one or more failed; 2 misconfigured."
    } >&"${_FD}"
    exit "${_CODE}"
}

JSON_MODE="false"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) JSON_MODE="true" ; shift ;;
        -h | --help) usage 0 ;;
        *) echo "Error: unknown option '$1'." >&2 ; usage 2 ;;
    esac
done

STABILITY_WINDOW_SECONDS="${STABILITY_WINDOW_SECONDS:-300}"
if [[ ! "$STABILITY_WINDOW_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    log_fail "STABILITY_WINDOW_SECONDS must be a positive integer (got '${STABILITY_WINDOW_SECONDS}')"
    exit 2
fi

VERIFY_PASSES=0
VERIFY_FAILURES=0
VERIFY_SKIPS=0

# Which component the assertions below belong to; set by verify_section.
VERIFY_SECTION="unknown"

# One record per assertion, consumed by emit_json. Fields are separated by US
# (0x1f) and records by RS (0x1e) — control characters that cannot appear in a
# kubectl message, so no message can forge a field boundary.
VERIFY_RECORDS=""

function verify_record() {
    VERIFY_RECORDS+="${VERIFY_SECTION}"$'\x1f'"${1}"$'\x1f'"${2}"$'\x1f'"${3:-}"$'\x1e'
}

# Announce the component that the following assertions belong to.
function verify_section() {
    VERIFY_SECTION="$1"
    log_info "--- $2 ---"
}

function verify_pass() {
    verify_record "passed" "$1"
    VERIFY_PASSES=$((VERIFY_PASSES + 1))
    log_okay "  PASS: $1"
}

# $2 is optional supporting output (typically a kubectl dump). It is printed as
# before and also carried in the JSON, so the host can show why a check failed
# without shipping the whole log.
function verify_fail() {
    verify_record "failed" "$1" "${2:-}"
    VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
    log_fail "  FAIL: $1"
    if [[ -n "${2:-}" ]]; then
        printf '%s\n' "$2"
    fi
    # Explicit: the last command must not decide this function's exit status,
    # since every caller runs under `set -e`.
    return 0
}

# A check that could not run. Deliberately distinct from passed: a subsystem
# that is not deployed has not been verified, and reporting absence as success
# is the defect class of #110.
function verify_skip() {
    verify_record "skipped" "$1"
    VERIFY_SKIPS=$((VERIFY_SKIPS + 1))
    log_info "  SKIP: $1"
}

# Serialise the records as JSON. python3 is stdlib-only here, per the node-side
# rule; it does the quoting so a message containing a quote cannot break out.
function emit_json() {
    printf '%s' "$VERIFY_RECORDS" | python3 -c '
import json, sys

RS = "\x1e"
US = "\x1f"

node, passed, failed, skipped = sys.argv[1:5]

checks = []
for record in sys.stdin.read().split(RS):
    if not record:
        continue
    section, result, message, detail = record.split(US, 3)
    entry = {"section": section, "result": result, "message": message}
    if detail:
        entry["detail"] = detail
    checks.append(entry)

# schema is the contract version: the host refuses a document it cannot read
# rather than silently misreading a future shape.
document = {
    "schema": 1,
    "node": node,
    "result": "failed" if int(failed) else "passed",
    "summary": {
        "passed": int(passed),
        "failed": int(failed),
        "skipped": int(skipped),
        "total": len(checks),
    },
    "checks": checks,
}
print(json.dumps(document, indent=2))
' "$(hostname)" "$VERIFY_PASSES" "$VERIFY_FAILURES" "$VERIFY_SKIPS"
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
    verify_section "k3s_api" "K3s API"
    if sudo kubectl get --raw=/readyz >/dev/null 2>&1; then
        verify_pass "K3s API is reachable"
    else
        verify_fail "K3s API is not reachable"
    fi
}

# ─── Nodes ───────────────────────────────────────────────────────────────────

function check_nodes_ready() {
    verify_section "nodes" "Nodes"
    local NOT_READY
    NOT_READY="$(sudo kubectl get nodes --no-headers 2>/dev/null \
        | grep -v " Ready" || true)"
    if [[ -z "$NOT_READY" ]]; then
        verify_pass "All nodes are Ready"
    else
        verify_fail "Some nodes are not Ready" "$NOT_READY"
    fi
}

# ─── kube-system ─────────────────────────────────────────────────────────────

function check_kube_system() {
    verify_section "kube_system" "kube-system"
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
    verify_section "traefik" "Traefik"
    if ! sudo kubectl -n kube-system get deploy traefik >/dev/null 2>&1; then
        verify_skip "deployment kube-system/traefik not present (subsystem not enabled)"
        return
    fi
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
    verify_section "kyverno" "Kyverno"
    if ! sudo kubectl get ns kyverno >/dev/null 2>&1; then
        verify_skip "namespace 'kyverno' not present (subsystem not enabled)"
        return
    fi
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
    verify_section "longhorn" "Longhorn"
    if ! sudo kubectl get ns longhorn-system >/dev/null 2>&1; then
        verify_skip "namespace 'longhorn-system' not present (subsystem not enabled)"
        return
    fi
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
    verify_section "external_secrets" "External Secrets"
    if ! sudo kubectl get ns external-secrets >/dev/null 2>&1; then
        verify_skip "namespace 'external-secrets' not present (subsystem not enabled)"
        return
    fi
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
    verify_section "karpenter" "Karpenter"
    if ! sudo kubectl get crd nodepools.karpenter.sh >/dev/null 2>&1; then
        verify_skip "CRD nodepools.karpenter.sh not present (subsystem not enabled)"
        return
    fi
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
    check_karpenter_nodeclaims_progressing
}

# A NodeClaim that never finishes is the failure mode of issue #123: Karpenter
# asks to remove a node, something refuses to release it, and the instance bills
# indefinitely. Nothing errors — Karpenter simply retries forever — so without an
# explicit check the only symptom is the AWS invoice.
#
# Two stuck states are reported:
#   deleting  - deletionTimestamp set but the NodeClaim is still here. Drain is
#               blocked, most likely by a PodDisruptionBudget that never releases.
#   launching - never reached Ready. The instance exists but never joined, which
#               is what a broken bootstrap entry point looks like (issue #121).
#
# The threshold is deliberately generous: a healthy node takes ~3 minutes to boot,
# install packages and register, and Karpenter's own registration timeout is 15
# minutes. Anything past that is genuinely stuck, not merely slow.
function check_karpenter_nodeclaims_progressing() {
    local STUCK_MINUTES="${KARPENTER_NODECLAIM_STUCK_MINUTES:-20}"
    local STUCK

    STUCK="$(sudo kubectl get nodeclaims -o json 2>/dev/null | python3 -c "
import json, sys, datetime

limit = int('${STUCK_MINUTES}')
now = datetime.datetime.now(datetime.timezone.utc)
cutoff = now - datetime.timedelta(minutes=limit)


def parsed(ts):
    if not ts:
        return None
    try:
        return datetime.datetime.fromisoformat(ts.replace('Z', '+00:00'))
    except ValueError:
        return None


try:
    items = json.load(sys.stdin).get('items', [])
except (json.JSONDecodeError, ValueError):
    sys.exit(0)

for nc in items:
    meta = nc.get('metadata', {})
    name = meta.get('name', '<unknown>')

    deleting = parsed(meta.get('deletionTimestamp'))
    if deleting is not None:
        if deleting < cutoff:
            mins = int((now - deleting).total_seconds() // 60)
            print(f'{name}: deleting for {mins}m — drain is blocked (check PDBs)')
        continue

    ready = ''
    for cond in nc.get('status', {}).get('conditions', []):
        if cond.get('type') == 'Ready':
            ready = cond.get('status', '')
            break
    if ready == 'True':
        continue

    created = parsed(meta.get('creationTimestamp'))
    if created is not None and created < cutoff:
        mins = int((now - created).total_seconds() // 60)
        print(f'{name}: not Ready after {mins}m — node never joined')
" 2>/dev/null || true)"

    if [[ -z "$STUCK" ]]; then
        verify_pass "No NodeClaims stuck longer than ${STUCK_MINUTES}m"
    else
        verify_fail "NodeClaims stuck longer than ${STUCK_MINUTES}m" "$STUCK"
    fi
}

# ─── Descheduler ─────────────────────────────────────────────────────────────

function check_descheduler() {
    verify_section "descheduler" "Descheduler"
    if ! sudo kubectl -n kube-system get cronjob descheduler >/dev/null 2>&1; then
        verify_skip "cronjob kube-system/descheduler not present (subsystem not enabled)"
        return
    fi
    verify_pass "kube-system/descheduler CronJob exists"
}

# ─── Tailscale ───────────────────────────────────────────────────────────────

function check_tailscale() {
    verify_section "tailscale" "Tailscale"
    if ! sudo kubectl get ns tailscale >/dev/null 2>&1; then
        verify_skip "namespace 'tailscale' not present (subsystem not enabled)"
        return
    fi
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
    verify_section "argocd" "ArgoCD"
    if ! sudo kubectl get ns argocd >/dev/null 2>&1; then
        verify_skip "namespace 'argocd' not present (application not enabled)"
        return
    fi
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
    verify_section "monitoring" "Monitoring"
    if ! sudo kubectl get ns monitoring >/dev/null 2>&1; then
        verify_skip "namespace 'monitoring' not present (application not enabled)"
        return
    fi
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

function list_recent_restarts() {
    # List the recent restarted pods inside of the window

    local PODS_JSON RESTART_WINDOW
    # The kubectl get pods output (in JSON format)
    PODS_JSON="$1"
    # The cutoff time for restarts to be counted (i.e. restarts are old enough to be outside of the window are ignored)
    RESTART_WINDOW="$2"

    # Python-blob is single-quoted: bash must not interpolate into the python source; window via argv.
    printf '%s' "$PODS_JSON" | python3 -c '
import json, sys, datetime

window = int(sys.argv[1])
now = datetime.datetime.now(datetime.timezone.utc)
cutoff = now - datetime.timedelta(seconds=window)


def describe(term, kind):
    """Describe a termination record if it lands inside the window, else None."""
    finished_at = term.get("finishedAt", "")
    if not finished_at:
        return None
    try:
        when = datetime.datetime.fromisoformat(finished_at.replace("Z", "+00:00"))
    except ValueError:
        # Reported, not skipped: a timestamp we cannot read must not pass as healthy.
        return kind + " with unreadable timestamp " + finished_at
    if when > cutoff:
        return kind + " at " + finished_at
    return None


def finding(container, count_restarts):
    """Why this container looks unstable inside the window, or None."""
    if count_restarts:
        # lastState is a PREVIOUS incarnation: evidence of a restart, any exit code.
        found = describe(container.get("lastState", {}).get("terminated", {}), "restarted")
        if found:
            return found
    # state is the CURRENT incarnation. Exit 0 is a normal completion, not instability.
    current = container.get("state", {}).get("terminated", {})
    if current.get("exitCode", 0) != 0:
        return describe(current, "terminated")
    return None


output = []
pods = json.load(sys.stdin)["items"]

for pod in pods:
    ns = pod["metadata"]["namespace"]
    name = pod["metadata"]["name"]
    status = pod.get("status", {})

    # If the pod is succeeded, then move onto the next pod
    if status.get("phase", "") == "Succeeded":
        continue

    # Construct a list candidates to be processed
    candidates = list()
    candidates += [(container_status, False) for container_status in status.get("initContainerStatuses", [])]
    candidates += [(container_status, True) for container_status in status.get("containerStatuses", [])]

    for container_status, count_restarts in candidates:
        # Determine what is wrong with the candidate, 
        found = finding(container_status, count_restarts)
        if found:
            # Once found, append the data about the failure into the output to be displayed later
            container_name = container_status["name"]
            output.append(f"{ns}/{name} (container: {container_name}, {found})")
            break

# Display the output
for line in output:
    print(line)
' "$RESTART_WINDOW"
}

function check_pod_stability() {
    verify_section "pod_stability" "Pod stability (restarts in the last ${STABILITY_WINDOW_SECONDS}s)"

    # Declared before assignment: `local X="$(...)"` returns local's status, not the
    # substitution's, so the `||` handlers below would never fire.
    local PODS_JSON UNSTABLE_PODS

    PODS_JSON="$(sudo kubectl get pods -A -o json)" || {
        verify_fail "Pod stability: could not query pods"
        return 0
    }

    UNSTABLE_PODS="$(list_recent_restarts "$PODS_JSON" "$STABILITY_WINDOW_SECONDS")" || {
        verify_fail "Pod stability: restart analysis failed"
        return 0
    }

    if [[ -z "$UNSTABLE_PODS" ]]; then
        verify_pass "No pod restarts in the last ${STABILITY_WINDOW_SECONDS}s"
    else
        verify_fail "Pods with recent restarts (within ${STABILITY_WINDOW_SECONDS}s)" "$UNSTABLE_PODS"
    fi
}

# ─── Main ────────────────────────────────────────────────────────────────────

# In --json mode stdout is reserved for the JSON document, so every prose line
# (including the checks' own kubectl dumps) is redirected to stderr and the real
# stdout is parked on fd 3 until emit_json. Doing this here, rather than
# appending a JSON block after the prose, is what keeps the document intact:
# SSM truncates stdout at 24000 characters mid-stream, which would silently eat
# the tail of a trailing block on a verbose run.
if [[ "$JSON_MODE" == "true" ]]; then
    exec 3>&1 1>&2
fi

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

if [[ "$JSON_MODE" == "true" ]]; then
    emit_json >&3
fi

# The PASSED/FAILED prose lines below are retained deliberately: the host still
# greps them when a node predates --json, so both contracts hold during the
# transition.
if [[ "$VERIFY_FAILURES" -gt 0 ]]; then
    log_fail "$0: FAILED ($VERIFY_FAILURES check(s) failed)"
    exit 1
fi

log_okay "$0: PASSED"
exit 0
