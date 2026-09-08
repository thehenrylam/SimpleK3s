#!/bin/bash

set -euo pipefail

# Restarts platform workloads that are deployed but not working.
#
# The gap this fills: `pull` fixes stale desired state and `repair` fixes
# cluster membership, but neither helps when the manifests are current, the
# node is healthy, and a workload is simply wedged. `status` reports that and
# stops. This is the actuator for what `status` observes, so the two share one
# vocabulary — the section names in the verify report.
#
# SCOPE: ONE NODE. Every action here goes through the Kubernetes API, so its
# effect is cluster-wide; restarting the same workload from three nodes is three
# rollouts of one deployment. Unlike manifest staging there is no on-disk state,
# so no ownership lock is needed — any healthy, reachable control-plane node
# will do.
#
# PREVIEW BY DEFAULT. Restarting live workloads is disruptive, so an invocation
# with no target selection reports the plan and changes nothing, following
# cluster_repair.yml. Acting requires naming a target set (--auto or --only).
#
# Exit codes: 0 refreshed (or previewed), 1 failed, 2 bad usage.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=examples/standard_deployment/scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

AUTO=0
ONLY=""
HARD=0
DRY_RUN=0
NO_COLOR=0
INSTANCE_ID=""
POLL_MAX=90
POLL_INTERVAL=5

EXIT_USAGE=2

# Sections that are not workloads. A failure in either means nothing downstream
# can be trusted, and neither is fixable by restarting a pod — reporting a tidy
# "refreshed 0 components" against a dead API server would be the worst possible
# answer, so the run refuses instead.
BLOCKING_SECTIONS="k3s_api nodes"

# Reported, never acted on. pod_stability is a symptom spanning namespaces
# rather than a component, and — decisively — refresh CAUSES it: pods restarted
# by this very run are recent restarts. Feeding it back in would make every
# successful refresh look like a new failure.
EXCLUDED_SECTIONS="pod_stability"

function usage() {
    local _CODE
    _CODE="${1:-${EXIT_USAGE}}"
    if (( _CODE == 0 )); then
        print_usage
    else
        print_usage >&2
    fi
    exit "${_CODE}"
}

function print_usage() {
    echo "Usage: $(basename "$0") <profile> [<nickname> <region>] [options]"
    echo ""
    echo "  profile        AWS CLI profile (required)"
    echo "  nickname       Cluster nickname (default: inferred from terraform.tfvars)"
    echo "  region         AWS region      (default: inferred from terraform.tfvars)"
    echo ""
    echo "  --auto         Restart whatever the cluster health check reports as failing"
    echo "  --only a,b,c   Restart the named components, regardless of health"
    echo "  --hard         Delete pods instead of rolling the workload"
    echo "  --instance-id  Act through a specific node (default: first reachable)"
    echo "  --dry-run      Report the plan and change nothing"
    echo "  --no-color     Never emit colour"
    echo ""
    echo "With neither --auto nor --only, the plan is previewed and nothing changes."
    echo ""
    echo "Exit: 0 refreshed or previewed; 1 failed; 2 bad usage"
}

# ─── Colours ────────────────────────────────────────────────────────────────────

C_RED="" ; C_GRN="" ; C_YLW="" ; C_RST=""
function setup_colors() {
    if [[ "${NO_COLOR}" -eq 0 && -t 1 ]]; then
        C_RED=$'\033[31m' ; C_GRN=$'\033[32m'
        C_YLW=$'\033[33m' ; C_RST=$'\033[0m'
    fi
}

# ─── Remote helpers ─────────────────────────────────────────────────────────────

REMOTE_STDOUT=""
REMOTE_STATUS=""

# Run a node script and capture its stdout into REMOTE_STDOUT. Globals rather
# than a return value because both the payload and the invocation status matter,
# and a command substitution would discard the latter.
function remote_script() {
    local _INSTANCE_ID="${1}" _ARGS="${2}"
    local _CMD _COMMAND_ID _RESULT

    _CMD="$(build_remote_command "${_ARGS}")"
    _COMMAND_ID="$(ssm_send_command "${REGION}" "${PROFILE}" "${_INSTANCE_ID}" "${_CMD}")" || return 1
    _RESULT="$(ssm_await_completion "${REGION}" "${PROFILE}" "${_INSTANCE_ID}" \
        "${_COMMAND_ID}" "${POLL_MAX}" "${POLL_INTERVAL}")" || true

    REMOTE_STATUS="$(parse_command_invocation_result "${_RESULT}" "Status")"
    REMOTE_STDOUT="$(parse_command_invocation_result "${_RESULT}" "StandardOutputContent")"

    # A truncated document parses as malformed rather than as "fewer findings",
    # but say so explicitly — a silent cut is how a partial answer becomes a
    # confident one.
    if output_is_truncated "${REMOTE_STDOUT}" "${SSM_STDOUT_LIMIT}"; then
        echo "WARNING: node output hit the SSM cap of ${SSM_STDOUT_LIMIT} characters and was cut." >&2
    fi
    [[ -n "${REMOTE_STDOUT}" ]]
}

# ─── Node selection ─────────────────────────────────────────────────────────────

TARGET_ID="" ; TARGET_NAME="" ; TARGET_WHY=""

function resolve_target() {
    local _INSTANCES _UNREACHABLE _ID _NAME _ROLE _BAD_ID _BAD_STATUS

    _INSTANCES="$(get_cluster_instances "${REGION}" "${PROFILE}" "${NICKNAME}" "controlplane")" || return 1

    if [[ -n "${INSTANCE_ID}" ]]; then
        while IFS=$'\t' read -r _ID _NAME _ROLE; do
            [[ "${_ID}" == "${INSTANCE_ID}" ]] || continue
            TARGET_ID="${_ID}" ; TARGET_NAME="${_NAME}"
            TARGET_WHY="named with --instance-id"
        done <<< "${_INSTANCES}"
        if [[ -z "${TARGET_ID}" ]]; then
            echo "Error: ${INSTANCE_ID} is not a running control-plane node of '${NICKNAME}'." >&2
            return 1
        fi
    else
        # First reachable by the shared sort. Impartial and reproducible: no node
        # is privileged, and the same command picks the same node on every run.
        local _ALL_IDS=()
        while read -r _ID; do
            [[ -n "${_ID}" ]] && _ALL_IDS[${#_ALL_IDS[@]}]="${_ID}"
        done < <(printf '%s\n' "${_INSTANCES}" | cut -f1)
        _UNREACHABLE="$(ssm_unreachable_instances "${REGION}" "${PROFILE}" "${_ALL_IDS[@]}")" || true
        while IFS=$'\t' read -r _ID _NAME _ROLE; do
            [[ -n "${_ID}" ]] || continue
            local _SKIP=0
            while IFS=$'\t' read -r _BAD_ID _BAD_STATUS; do
                [[ "${_BAD_ID}" == "${_ID}" ]] && _SKIP=1
            done <<< "${_UNREACHABLE}"
            (( _SKIP == 1 )) && continue
            TARGET_ID="${_ID}" ; TARGET_NAME="${_NAME}"
            TARGET_WHY="first reachable control-plane node"
            break
        done <<< "${_INSTANCES}"
        if [[ -z "${TARGET_ID}" ]]; then
            echo "${C_RED}No control-plane node is reachable over SSM.${C_RST}" >&2
            echo "Refresh acts through a node; without one there is nothing to act through." >&2
            return 1
        fi
    fi

    # Reachability is asserted even for an explicitly named node — being told
    # which node to use is not evidence that SSM can dispatch to it.
    _UNREACHABLE="$(ssm_unreachable_instances "${REGION}" "${PROFILE}" "${TARGET_ID}")" || true
    if [[ -n "${_UNREACHABLE}" ]]; then
        echo "${C_RED}Target ${TARGET_ID} is not reachable over SSM${C_RST} (${_UNREACHABLE#*$'\t'})." >&2
        return 1
    fi
}

# ─── Status ─────────────────────────────────────────────────────────────────────

FAILING="" ; BLOCKED="" ; EXCLUDED_HITS=""

# Sections with at least one failed check, split into three buckets by policy.
function read_status() {
    local _NODE_DIR _JSON _PARSED
    _NODE_DIR="$(get_node_script_dir)"

    echo "Reading cluster health from ${TARGET_ID} ..." >&2
    remote_script "${TARGET_ID}" "${_NODE_DIR}/node_verify-all.sh --json" || {
        echo "${C_RED}Could not read the cluster health report from ${TARGET_ID}.${C_RST}" >&2
        echo "Refusing to continue: an unreadable report has no failing sections, and" >&2
        echo "acting on that empty set would report 'nothing to refresh' for a cluster" >&2
        echo "whose state is unknown." >&2
        return 1
    }
    _JSON="${REMOTE_STDOUT}"

    _PARSED="$(printf '%s' "${_JSON}" | python3 -c '
import json, sys

blocking = set(sys.argv[1].split())
excluded = set(sys.argv[2].split())

try:
    document = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(3)

# Refuse a document we cannot read rather than half-reading a future shape.
if not isinstance(document, dict) or document.get("schema") != 1:
    sys.exit(3)

# A report carrying no checks is not a healthy cluster, it is a broken report.
# Reading it as "nothing is failing" would be the purest form of the mistake
# this whole path exists to avoid: absence reported as success.
checks = document.get("checks")
if not checks:
    sys.exit(3)

# Order-preserving and deduped: the report lists a section once per check.
failing = []
for check in checks:
    if check.get("result") != "failed":
        continue
    section = check.get("section")
    if section and section not in failing:
        failing.append(section)

print(" ".join(s for s in failing if s in blocking))
print(" ".join(s for s in failing if s in excluded))
print(" ".join(s for s in failing if s not in blocking and s not in excluded))
' "${BLOCKING_SECTIONS}" "${EXCLUDED_SECTIONS}")" || {
        echo "${C_RED}The health report from ${TARGET_ID} could not be read.${C_RST}" >&2
        echo "It was not valid JSON, carried an unrecognised schema, or contained no" >&2
        echo "checks at all. Refusing to continue: none of those mean 'healthy', and" >&2
        echo "each would yield an empty failing set that reads as 'nothing to refresh'." >&2
        return 1
    }

    BLOCKED="$(printf '%s' "${_PARSED}" | sed -n '1p')"
    EXCLUDED_HITS="$(printf '%s' "${_PARSED}" | sed -n '2p')"
    FAILING="$(printf '%s' "${_PARSED}" | sed -n '3p')"
}

# ─── Reporting ──────────────────────────────────────────────────────────────────

function render_report() {
    printf '%s' "${REMOTE_STDOUT}" | python3 -c '
import json, sys

red, grn, ylw, rst = sys.argv[1:5]

try:
    document = json.load(sys.stdin)
except json.JSONDecodeError:
    print("Could not parse the refresh report from the node.", file=sys.stderr)
    sys.exit(1)

colour = {
    "refreshed": grn, "rolled_out": grn,
    "planned": "", "not_deployed": ylw, "not_restartable": ylw,
    "absent": ylw, "failed": red, "timeout": red, "unknown": red,
}

for component in document["components"]:
    verdict = component["result"]
    tint = colour.get(verdict, "")
    print("  %s%-18s %s%s" % (tint, component["component"], verdict, rst))
    if component.get("detail"):
        print("      %s" % component["detail"])
    for workload in component["workloads"]:
        wtint = colour.get(workload["result"], "")
        print("      %-52s %s%s%s" % (
            "%s/%s" % (component["namespace"], workload["workload"]),
            wtint, workload["result"], rst))
        if workload.get("detail"):
            print("          %s" % workload["detail"])

summary = document["summary"]
print("")
print("Requested %d | refreshed %d | planned %d | unsatisfied %d" % (
    summary["requested"], summary["refreshed"],
    summary["planned"], summary["unsatisfied"]))
' "${C_RED}" "${C_GRN}" "${C_YLW}" "${C_RST}"
}

# ─── Main ───────────────────────────────────────────────────────────────────────

PROFILE="" ; NICKNAME="" ; REGION=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "${1}" in
        --auto)        AUTO=1 ; shift ;;
        --only)        ONLY="${2:-}" ; shift 2 ;;
        --hard)        HARD=1 ; shift ;;
        --instance-id) INSTANCE_ID="${2:-}" ; shift 2 ;;
        --dry-run)     DRY_RUN=1 ; shift ;;
        --no-color)    NO_COLOR=1 ; shift ;;
        -h|--help)     usage 0 ;;
        -*)            echo "Unknown option: ${1}" >&2 ; usage ;;
        *)             POSITIONAL[${#POSITIONAL[@]}]="${1}" ; shift ;;
    esac
done
set -- ${POSITIONAL[@]+"${POSITIONAL[@]}"}

PROFILE="${1:-}"
[[ -z "${PROFILE}" ]] && usage
if (( $# == 2 || $# > 3 )); then
    echo "Error: expected <profile>, or <profile> <nickname> <region>." >&2
    usage
fi
if (( AUTO == 1 )) && [[ -n "${ONLY}" ]]; then
    echo "Error: --auto and --only select the target set two different ways; pick one." >&2
    usage
fi

IAC_NAME_CLUSTER="standard_cluster"
IAC_TFVARS="$(get_tfvar_filepath "${SCRIPT_DIR}" "${IAC_NAME_CLUSTER}")"
NICKNAME="${2:-$(infer_tfvar "${IAC_TFVARS}" "nickname")}"
REGION="${3:-$(infer_tfvar "${IAC_TFVARS}" "aws_region")}"
if [[ -z "${NICKNAME}" || -z "${REGION}" ]]; then
    echo "Error: could not infer nickname/region from ${IAC_TFVARS}." >&2
    usage
fi

setup_colors

# No target selection means "show me what you would do" — the preview, not a
# no-op and not an implicit act.
PREVIEW=0
if (( AUTO == 0 )) && [[ -z "${ONLY}" ]]; then
    PREVIEW=1
fi
(( DRY_RUN == 1 )) && PREVIEW=1

METHOD="rollout restart"
(( HARD == 1 )) && METHOD="delete pods"

resolve_target || exit 1

echo "Cluster  : nickname=${NICKNAME}  region=${REGION}  profile=${PROFILE}"
echo "Target   : ${TARGET_ID} (${TARGET_NAME})  — ${TARGET_WHY}"
echo "Method   : ${METHOD}"
echo ""

# --only names the set outright, so no health read is needed. Anything else
# derives it from the cluster's own report.
COMPONENTS=""
if [[ -n "${ONLY}" ]]; then
    COMPONENTS="${ONLY}"
    echo "--- target set (named with --only) ---"
    echo "  ${COMPONENTS}"
    echo ""
else
    read_status || exit 1

    echo "--- cluster health ---"
    echo "  failing        : ${FAILING:-none}"
    echo "  not actionable : ${EXCLUDED_HITS:-none}"
    echo "  blocking       : ${BLOCKED:-none}"
    echo ""

    if [[ -n "${BLOCKED}" ]]; then
        echo "${C_RED}Refusing to refresh.${C_RST}" >&2
        echo "  Failing: ${BLOCKED}" >&2
        echo "  These are not workloads — the API server and node readiness cannot be" >&2
        echo "  fixed by restarting a pod, and nothing else can be trusted while they" >&2
        echo "  are failing. This is a repair case: run 'sk3s repair' first." >&2
        exit 1
    fi

    if [[ -n "${EXCLUDED_HITS}" ]]; then
        echo "  ${C_YLW}Note${C_RST}: ${EXCLUDED_HITS} is reported but not acted on — it spans"
        echo "        namespaces rather than naming a component, and a refresh's own"
        echo "        restarts would register as new instability."
        echo ""
    fi

    if [[ -z "${FAILING}" ]]; then
        echo "${C_GRN}Nothing to refresh.${C_RST} Every actionable section is healthy."
        exit 0
    fi
    COMPONENTS="${FAILING// /,}"
fi

NODE_DIR="$(get_node_script_dir)"
ARGS="${NODE_DIR}/node_refresh-services.sh --components ${COMPONENTS} --json"
(( HARD == 1 )) && ARGS="${ARGS} --hard"
(( PREVIEW == 1 )) && ARGS="${ARGS} --dry-run"

if (( PREVIEW == 1 )); then
    echo "--- plan (preview, nothing changed) ---"
else
    echo "--- refreshing ---"
fi

REFRESH_OK=0
remote_script "${TARGET_ID}" "${ARGS}" || REFRESH_OK=1

if (( REFRESH_OK != 0 )) || [[ -z "${REMOTE_STDOUT}" ]]; then
    echo "${C_RED}No report came back from ${TARGET_ID} (SSM status: ${REMOTE_STATUS:-unknown}).${C_RST}" >&2
    echo "Whether anything was restarted is unknown — check the node before re-running." >&2
    exit 1
fi

render_report || exit 1
echo ""

if (( PREVIEW == 1 )); then
    echo "Preview only — nothing was restarted."
    if [[ -z "${ONLY}" ]]; then
        echo "Re-run with --auto to apply, or --only <components> to choose the set."
    else
        echo "Re-run without --dry-run to apply."
    fi
    exit 0
fi

# The node's own exit status is the verdict; SSM reports Failed when it is
# non-zero. Trusting the document over the status would let a component that
# could not be refreshed pass as a success.
if [[ "${REMOTE_STATUS}" != "Success" ]]; then
    echo "${C_RED}Refresh did not fully succeed.${C_RST}" >&2
    echo "Components above that are not 'refreshed' were not restarted and rolled out." >&2
    exit 1
fi

echo "${C_GRN}Refresh complete.${C_RST} Run 'sk3s status' to confirm — allow for the"
echo "pod-restart stability window before expecting a pass."
