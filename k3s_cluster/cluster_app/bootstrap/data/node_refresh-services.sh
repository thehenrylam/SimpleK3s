#!/bin/bash

# Set bash flags
set -euo pipefail
# -u            : Error if an unset variable is referenced
# -e            : Exits on ANY command failure
# -o pipefail   : Make pipeline fail if any command in them fails

# Restarts platform workloads that are deployed but not working.
#
# This is the actuator for what node_verify-all.sh observes. It deliberately
# holds NO policy about which components deserve a restart — the host decides
# that from a verify report and names them here. Keeping the decision out of
# this script is what makes it testable: "restart these" has one meaning.
#
# SCOPE. Everything here acts through the Kubernetes API, so its effect is
# cluster-wide and this script runs on exactly ONE node. It deliberately does
# not touch systemd: restarting k3s itself drops an etcd member, and that
# hazard already has one owner (ssm_repair_cluster.sh, which knows about
# quorum). A second path to it behind a flag on a different verb is how the two
# get out of step. For the systemd layer, use `sk3s exec`.
#
# Usage: node_refresh-services.sh --components <a,b,c> [--hard] [--dry-run] [--json]
#        node_refresh-services.sh --list [--json]
#
# Exit: 0 every requested component was restarted and rolled out (or --dry-run);
#       1 at least one could not be; 2 misconfigured.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

# ─── Component registry ──────────────────────────────────────────────────────

# component|namespace|workloads|note
#
# Component names mirror node_verify-all.sh's verify_section names exactly, so
# a failing check maps to a refresh target without a translation table in
# between. Two tables that must agree are two tables that will disagree.
#
# The workload list is explicit rather than "every workload in the namespace".
# A named list means the operator can see the precise blast radius in the
# preview before anything is restarted, and no Helm-generated name can join the
# set without someone deciding it should.
#
# An entry with NO workloads is not an omission — it records that the section
# exists and cannot be fixed by restarting something, with the reason. That is
# the difference between "refresh handled it" and "refresh silently did
# nothing", which is the failure this project keeps re-learning.
REFRESH_REGISTRY=(
    "k3s_api|||the API server itself is not a workload; a failure here is a repair case (see: sk3s repair)"
    "nodes|||node readiness is a repair case, not a refresh (see: sk3s repair)"
    "pod_stability|||a symptom spanning namespaces, not a component; refresh the component that owns the restarting pods"
    "kube_system|kube-system|deploy/coredns deploy/local-path-provisioner|"
    "traefik|kube-system|deploy/traefik|"
    "kyverno|kyverno|deploy/kyverno-admission-controller deploy/kyverno-background-controller deploy/kyverno-cleanup-controller|"
    "longhorn|longhorn-system|daemonset/longhorn-manager daemonset/longhorn-csi-plugin|"
    "external_secrets|external-secrets|deploy/external-secrets|"
    "karpenter|kube-system|deploy/karpenter|"
    "descheduler|kube-system||runs as a CronJob on a schedule; there is no rollout to restart"
    "tailscale|tailscale|deploy/operator|"
    "argocd|argocd|deploy/argocd-server|"
    "monitoring|monitoring|deploy/prometheus-kube-prometheus-operator deploy/prometheus-grafana statefulset/prometheus-prometheus-kube-prometheus-prometheus statefulset/alertmanager-prometheus-kube-prometheus-alertmanager|"
)

# field <entry> <n>  — nth |-separated field, 1-indexed
function field() {
    local _ENTRY="${1}" _N="${2}" _I
    for ((_I = 1; _I < _N; _I++)); do
        _ENTRY="${_ENTRY#*|}"
    done
    printf '%s' "${_ENTRY%%|*}"
}

function registry_entry() {
    local _WANT="${1}" _ENTRY
    for _ENTRY in "${REFRESH_REGISTRY[@]}"; do
        if [[ "$(field "${_ENTRY}" 1)" == "${_WANT}" ]]; then
            printf '%s' "${_ENTRY}"
            return 0
        fi
    done
    return 1
}

function known_components() {
    local _ENTRY _OUT=""
    for _ENTRY in "${REFRESH_REGISTRY[@]}"; do
        _OUT+="$(field "${_ENTRY}" 1) "
    done
    printf '%s' "${_OUT% }"
}

# ─── Reporting ───────────────────────────────────────────────────────────────

# One record per workload, US/RS separated for the same reason node_verify-all.sh
# does it: control characters cannot appear in a kubectl message, so no message
# can forge a field boundary.
#   component US namespace US workload US result US detail RS
REFRESH_RECORDS=""

function refresh_record() {
    REFRESH_RECORDS+="${1}"$'\x1f'"${2}"$'\x1f'"${3}"$'\x1f'"${4}"$'\x1f'"${5:-}"$'\x1e'
}

function emit_json() {
    printf '%s' "${REFRESH_RECORDS}" | python3 -c '
import json, sys

RS, US = "\x1e", "\x1f"
node, mode, method, dry_run = sys.argv[1:5]

# Per-workload results roll up into a component verdict. The rules are written
# out rather than inferred so that an unexpected result value can never be
# quietly counted as a success.
def verdict(results, workloads):
    if not workloads:
        return "not_restartable"
    if all(r == "planned" for r in results):
        return "planned"
    if all(r == "absent" for r in results):
        return "not_deployed"
    if all(r == "rolled_out" for r in results):
        return "refreshed"
    return "failed"

components, order = {}, []
for record in sys.stdin.read().split(RS):
    if not record:
        continue
    component, namespace, workload, result, detail = record.split(US, 4)
    if component not in components:
        components[component] = {
            "component": component,
            "namespace": namespace or None,
            "workloads": [],
        }
        order.append(component)
    entry = components[component]
    if workload:
        item = {"workload": workload, "result": result}
        if detail:
            item["detail"] = detail
        entry["workloads"].append(item)
    else:
        # A component-level record with no workload carries its own verdict
        # (not_restartable, unknown) and the reason it has no workloads.
        entry["result"] = result
        if detail:
            entry["detail"] = detail

out = []
for name in order:
    entry = components[name]
    results = [w["result"] for w in entry["workloads"]]
    entry.setdefault("result", verdict(results, entry["workloads"]))
    out.append(entry)

# A run is a success only when every requested component actually ended up
# restarted and rolled out. not_deployed and not_restartable are NOT successes:
# the request could not be satisfied, and saying otherwise is how "nothing
# happened" gets reported as "all good".
satisfied = {"refreshed", "planned"}
failed = [c["component"] for c in out if c["result"] not in satisfied]

document = {
    "schema": 1,
    "node": node,
    "mode": mode,
    "method": method,
    "dry_run": dry_run == "true",
    "result": "failed" if failed else "passed",
    "summary": {
        "requested": len(out),
        "refreshed": sum(1 for c in out if c["result"] == "refreshed"),
        "planned": sum(1 for c in out if c["result"] == "planned"),
        "unsatisfied": len(failed),
    },
    "components": out,
}
print(json.dumps(document, indent=2))
' "$(hostname)" "${MODE}" "${METHOD}" "${DRY_RUN}"
}

function emit_registry_json() {
    local _ENTRY _PAYLOAD=""
    for _ENTRY in "${REFRESH_REGISTRY[@]}"; do
        _PAYLOAD+="$(field "${_ENTRY}" 1)"$'\x1f'"$(field "${_ENTRY}" 2)"$'\x1f'
        _PAYLOAD+="$(field "${_ENTRY}" 3)"$'\x1f'"$(field "${_ENTRY}" 4)"$'\x1e'
    done
    printf '%s' "${_PAYLOAD}" | python3 -c '
import json, sys

RS, US = "\x1e", "\x1f"
components = []
for record in sys.stdin.read().split(RS):
    if not record:
        continue
    name, namespace, workloads, note = record.split(US, 3)
    entry = {
        "component": name,
        "namespace": namespace or None,
        "workloads": workloads.split() if workloads else [],
        "restartable": bool(workloads),
    }
    if note:
        entry["note"] = note
    components.append(entry)
print(json.dumps({"schema": 1, "components": components}, indent=2))
'
}

# ─── Restart primitives ──────────────────────────────────────────────────────

ROLLOUT_TIMEOUT_SECONDS="${REFRESH_ROLLOUT_TIMEOUT_SECONDS:-180}"

function workload_exists() {
    sudo kubectl -n "${1}" get "${2}" >/dev/null 2>&1
}

# Soft: let the controller roll the workload. Respects the update strategy and
# any PodDisruptionBudget, which is what makes it the default.
function restart_soft() {
    sudo kubectl -n "${1}" rollout restart "${2}" >/dev/null 2>&1
}

# Hard: delete the pods outright.
#
# This exists because `rollout restart` cannot fix a workload whose rollout is
# itself stuck — a CrashLooping pod blocks its own replacement from becoming
# ready, so the new revision never progresses and the restart is a no-op. Going
# straight at the pods is the only thing that clears that state.
function restart_hard() {
    local _NS="${1}" _WORKLOAD="${2}" _SELECTOR
    _SELECTOR="$(workload_pod_selector "${_NS}" "${_WORKLOAD}")" || return 1
    [[ -n "${_SELECTOR}" ]] || return 1
    sudo kubectl -n "${_NS}" delete pod -l "${_SELECTOR}" --wait=false >/dev/null 2>&1
}

function await_rollout() {
    sudo kubectl -n "${1}" rollout status "${2}" \
        --timeout="${ROLLOUT_TIMEOUT_SECONDS}s" >/dev/null 2>&1
}

# ─── Refresh ─────────────────────────────────────────────────────────────────

function refresh_component() {
    local _COMPONENT="${1}"
    local _ENTRY _NS _WORKLOADS _NOTE _WORKLOAD

    if ! _ENTRY="$(registry_entry "${_COMPONENT}")"; then
        log_fail "Unknown component '${_COMPONENT}'"
        refresh_record "${_COMPONENT}" "" "" "unknown" \
            "not a known component; known: $(known_components)"
        return 0
    fi

    _NS="$(field "${_ENTRY}" 2)"
    _WORKLOADS="$(field "${_ENTRY}" 3)"
    _NOTE="$(field "${_ENTRY}" 4)"

    if [[ -z "${_WORKLOADS}" ]]; then
        log_warn "${_COMPONENT}: nothing to restart — ${_NOTE}"
        refresh_record "${_COMPONENT}" "${_NS}" "" "not_restartable" "${_NOTE}"
        return 0
    fi

    log_info "--- ${_COMPONENT} (${_NS}) ---"
    for _WORKLOAD in ${_WORKLOADS}; do
        refresh_workload "${_COMPONENT}" "${_NS}" "${_WORKLOAD}"
    done
}

function refresh_workload() {
    local _COMPONENT="${1}" _NS="${2}" _WORKLOAD="${3}"

    if ! workload_exists "${_NS}" "${_WORKLOAD}"; then
        # Not a failure of the restart, but not a success either: the operator
        # asked for a component that is not there, and the roll-up says so.
        log_warn "  ABSENT: ${_NS}/${_WORKLOAD} (component not deployed?)"
        refresh_record "${_COMPONENT}" "${_NS}" "${_WORKLOAD}" "absent" \
            "workload not present on the cluster"
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "  PLAN: ${METHOD} ${_NS}/${_WORKLOAD}"
        refresh_record "${_COMPONENT}" "${_NS}" "${_WORKLOAD}" "planned" \
            "would ${METHOD} and wait up to ${ROLLOUT_TIMEOUT_SECONDS}s for rollout"
        return 0
    fi

    local _OK=0
    if [[ "${METHOD}" == "delete-pod" ]]; then
        restart_hard "${_NS}" "${_WORKLOAD}" || _OK=1
    else
        restart_soft "${_NS}" "${_WORKLOAD}" || _OK=1
    fi

    if (( _OK != 0 )); then
        log_fail "  FAIL: could not ${METHOD} ${_NS}/${_WORKLOAD}"
        refresh_record "${_COMPONENT}" "${_NS}" "${_WORKLOAD}" "failed" \
            "${METHOD} command did not succeed"
        return 0
    fi

    # Waiting is the point. Issuing a restart proves only that the API accepted
    # it; the rollout completing is the evidence that the component came back.
    if await_rollout "${_NS}" "${_WORKLOAD}"; then
        log_okay "  OK: ${_NS}/${_WORKLOAD} rolled out"
        refresh_record "${_COMPONENT}" "${_NS}" "${_WORKLOAD}" "rolled_out" ""
    else
        log_fail "  TIMEOUT: ${_NS}/${_WORKLOAD} did not roll out in ${ROLLOUT_TIMEOUT_SECONDS}s"
        refresh_record "${_COMPONENT}" "${_NS}" "${_WORKLOAD}" "timeout" \
            "rollout did not complete within ${ROLLOUT_TIMEOUT_SECONDS}s"
    fi
}

# ─── Usage ───────────────────────────────────────────────────────────────────

function usage() {
    local _CODE="${1:-2}"
    local _FD=2
    (( _CODE == 0 )) && _FD=1
    {
        echo "Usage: $(basename "$0") --components <a,b,c> [--hard] [--dry-run] [--json]"
        echo "       $(basename "$0") --list [--json]"
        echo ""
        echo "  --components  Comma-separated component names to restart"
        echo "  --list        Print the component registry and exit"
        echo "  --hard        Delete pods instead of rolling the workload"
        echo "  --dry-run     Report the plan and change nothing"
        echo "  --json        Emit the report as JSON on stdout; prose to stderr"
        echo ""
        echo "Components: $(known_components)"
        echo ""
        echo "Environment:"
        echo "  REFRESH_ROLLOUT_TIMEOUT_SECONDS  rollout wait (default: 180)"
        echo ""
        echo "Exit: 0 every requested component refreshed (or --dry-run);"
        echo "      1 at least one could not be; 2 misconfigured."
    } >&"${_FD}"
    exit "${_CODE}"
}

# ─── Main ────────────────────────────────────────────────────────────────────

COMPONENTS=""
LIST_MODE="false"
JSON_MODE="false"
DRY_RUN="false"
METHOD="rollout"
MODE="refresh"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --components) COMPONENTS="${2:-}" ; shift 2 ;;
        --list)       LIST_MODE="true" ; shift ;;
        --hard)       METHOD="delete-pod" ; shift ;;
        --dry-run)    DRY_RUN="true" ; shift ;;
        --json)       JSON_MODE="true" ; shift ;;
        -h | --help)  usage 0 ;;
        *) echo "Error: unknown option '$1'." >&2 ; usage 2 ;;
    esac
done

if [[ ! "${ROLLOUT_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
    log_fail "REFRESH_ROLLOUT_TIMEOUT_SECONDS must be a positive integer (got '${ROLLOUT_TIMEOUT_SECONDS}')"
    exit 2
fi

if [[ "${LIST_MODE}" == "true" ]]; then
    MODE="list"
    if [[ "${JSON_MODE}" == "true" ]]; then
        emit_registry_json
    else
        printf '%-18s %-18s %s\n' "COMPONENT" "NAMESPACE" "WORKLOADS"
        for ENTRY in "${REFRESH_REGISTRY[@]}"; do
            printf '%-18s %-18s %s\n' \
                "$(field "${ENTRY}" 1)" \
                "$(field "${ENTRY}" 2)" \
                "$(field "${ENTRY}" 3)$(field "${ENTRY}" 4)"
        done
    fi
    exit 0
fi

[[ -n "${COMPONENTS}" ]] || { echo "Error: --components is required." >&2 ; usage 2 ; }

# In --json mode stdout is reserved for the document, so prose is parked on
# stderr and the real stdout held on fd 3 until emit_json. Same reasoning as
# node_verify-all.sh: SSM truncates stdout mid-stream at 24000 characters, which
# would silently eat the tail of a document appended after the prose.
if [[ "${JSON_MODE}" == "true" ]]; then
    exec 3>&1 1>&2
fi

log_info "$0: LAUNCHED"
log_info "Method: ${METHOD}   Dry run: ${DRY_RUN}   Rollout timeout: ${ROLLOUT_TIMEOUT_SECONDS}s"

# An unreachable API means every component below would report "absent" — a
# broken cluster described as an undeployed one. Fail before that can happen.
if ! sudo kubectl get --raw='/readyz' >/dev/null 2>&1; then
    log_fail "K3s API is not reachable from this node; refusing to report on components"
    exit 1
fi

IFS=',' read -r -a REQUESTED <<< "${COMPONENTS}"
for COMPONENT in "${REQUESTED[@]}"; do
    [[ -n "${COMPONENT}" ]] || continue
    refresh_component "${COMPONENT}"
done

if [[ "${JSON_MODE}" == "true" ]]; then
    emit_json >&3
fi

# Grep-able prose, mirroring node_verify-all.sh, so a host that cannot parse the
# document still has an unambiguous verdict line.
if printf '%s' "${REFRESH_RECORDS}" | grep -qE $'\x1f'"(failed|timeout|absent|not_restartable|unknown)"$'\x1f'; then
    log_fail "$0: FAILED (one or more components could not be refreshed)"
    exit 1
fi

log_okay "$0: PASSED"
exit 0
