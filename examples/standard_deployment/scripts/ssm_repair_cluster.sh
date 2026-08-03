#!/bin/bash

set -euo pipefail

# Repairs a control-plane node that cannot rejoin the cluster on its own.
#
# The case this exists for: node-0 is terminated and Terraform rebuilds it. The
# replacement cannot rejoin unaided, for two reasons —
#   1. CONTROLLER_HOST is node-0's own IP, so its join target is itself.
#   2. The terminated node's etcd member still holds the hostname (same static IP
#      means same name), and etcd rejects the duplicate.
# See RUNBOOKS.md for the manual form of this procedure.
#
# GROUND TRUTH, NOT GUESSWORK. A Node is only treated as stale when it is absent
# from the cluster's running EC2 instances — never on NotReady alone. NotReady can
# mean a hung kubelet or a network partition, and removing a member that is merely
# unreachable is how a recoverable blip becomes a split brain.
#
# QUORUM SAFETY. Removing an etcd member lowers the member count, and with it the
# number of failures the cluster tolerates: 3 members tolerate 1 loss, 2 members
# tolerate none. The repair therefore refuses to remove anything unless enough
# nodes are Ready to survive the operation.
#
# Exit codes: 0 repaired (or nothing to do), 1 failed, 2 bad usage.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=examples/standard_deployment/scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

DRY_RUN=0
NO_COLOR=0
POLL_MAX=60
POLL_INTERVAL=5

function usage() {
    echo "Usage: $(basename "$0") <profile> [<nickname> <region>] [--dry-run] [--no-color]" >&2
    echo "" >&2
    echo "  profile     AWS CLI profile (required)" >&2
    echo "  nickname    Cluster nickname (default: inferred from terraform.tfvars)" >&2
    echo "  region      AWS region      (default: inferred from terraform.tfvars)" >&2
    echo "  --dry-run   Report the plan and change nothing" >&2
    echo "  --no-color  Never emit colour" >&2
    echo "" >&2
    echo "Exit: 0 repaired or nothing to do; 1 failed; 2 bad usage" >&2
    exit 2
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

# Run a command on a node and print its stdout. SSM executes with /bin/sh (dash),
# so anything touching the bootstrap libraries must ask for bash explicitly.
function remote() {
    local _INSTANCE_ID="$1"
    local _CMD="$2"
    local _COMMAND_ID _RESULT

    _COMMAND_ID=$(ssm_send_command "${REGION}" "${PROFILE}" "${_INSTANCE_ID}" "${_CMD}") || return 1
    _RESULT=$(ssm_await_completion "${REGION}" "${PROFILE}" "${_INSTANCE_ID}" "${_COMMAND_ID}" \
        "${POLL_MAX}" "${POLL_INTERVAL}") || true
    parse_command_invocation_result "${_RESULT}" "StandardOutputContent"
}

# EC2 is the source of truth for "does this machine exist". Returns TSV:
#   <instance-id>\t<name>\t<private-ip>
function running_controlplane_instances() {
    aws ec2 describe-instances \
        --region "${REGION}" --profile "${PROFILE}" \
        --filters \
            "Name=tag:Nickname,Values=${NICKNAME}" \
            "Name=tag:Name,Values=*_controlplane-*" \
            "Name=instance-state-name,Values=running" \
        --query "Reservations[].Instances[].[InstanceId,Tags[?Key=='Name']|[0].Value,PrivateIpAddress]" \
        --output text
}

# k3s names nodes after their private IP: 10.0.1.100 -> ip-10-0-1-100
function ip_to_nodename() {
    echo "ip-${1//./-}"
}

# ─── Phase 1: gather ────────────────────────────────────────────────────────────

INSTANCE_IDS=() ; INSTANCE_NAMES=() ; INSTANCE_IPS=() ; INSTANCE_K3S=()
NODE_NAMES=() ; NODE_STATES=()
SURVIVOR_ID="" ; SURVIVOR_IP=""
STALE_NODES=() ; UNJOINED_IDS=() ; UNJOINED_IPS=()

function gather_instances() {
    local _ID _NAME _IP
    while IFS=$'\t' read -r _ID _NAME _IP; do
        [[ -z "${_ID}" ]] && continue
        INSTANCE_IDS[${#INSTANCE_IDS[@]}]="${_ID}"
        INSTANCE_NAMES[${#INSTANCE_NAMES[@]}]="${_NAME}"
        INSTANCE_IPS[${#INSTANCE_IPS[@]}]="${_IP}"
    done < <(running_controlplane_instances)

    if (( ${#INSTANCE_IDS[@]} == 0 )); then
        echo "Error: no running controlplane instances for nickname '${NICKNAME}'." >&2
        return 1
    fi
}

# Ask every instance whether k3s is actually running on it.
#
# This is the discriminator that IP matching cannot provide. A replaced node-0
# inherits the terminated node's static IP, so the stale Node object and the live
# replacement share a name — "is there an instance at this address" answers yes for
# both. Whether k3s is running on that instance is what separates them.
function gather_instance_states() {
    local _IDX _OUT
    for ((_IDX=0; _IDX<${#INSTANCE_IDS[@]}; _IDX++)); do
        _OUT=$(remote "${INSTANCE_IDS[$_IDX]}" "systemctl is-active k3s 2>/dev/null || true" || true)
        _OUT="$(echo "${_OUT}" | tr -d '[:space:]')"
        INSTANCE_K3S[${#INSTANCE_K3S[@]}]="${_OUT:-unknown}"
    done
}

# k3s state for the instance holding an IP; "none" when no instance holds it.
function k3s_state_for_ip() {
    local _IP="$1" _IDX
    for ((_IDX=0; _IDX<${#INSTANCE_IPS[@]}; _IDX++)); do
        if [[ "${INSTANCE_IPS[$_IDX]}" == "${_IP}" ]]; then
            echo "${INSTANCE_K3S[$_IDX]}"
            return 0
        fi
    done
    echo "none"
}

# Find a node that is actually serving. Without one there is nothing to repair
# against, and nothing safe to do.
function find_survivor() {
    local _IDX _OUT
    for ((_IDX=0; _IDX<${#INSTANCE_IDS[@]}; _IDX++)); do
        [[ "${INSTANCE_K3S[$_IDX]}" == "active" ]] || continue
        _OUT=$(remote "${INSTANCE_IDS[$_IDX]}" "kubectl get nodes --no-headers 2>/dev/null | head -1" || true)
        if [[ "${_OUT}" == *"ip-"* ]]; then
            SURVIVOR_ID="${INSTANCE_IDS[$_IDX]}"
            SURVIVOR_IP="${INSTANCE_IPS[$_IDX]}"
            return 0
        fi
    done
    return 1
}

function gather_nodes() {
    local _OUT _NAME _STATE _REST
    _OUT=$(remote "${SURVIVOR_ID}" "kubectl get nodes --no-headers 2>/dev/null") || return 1
    while read -r _NAME _STATE _REST; do
        [[ -z "${_NAME}" ]] && continue
        NODE_NAMES[${#NODE_NAMES[@]}]="${_NAME}"
        NODE_STATES[${#NODE_STATES[@]}]="${_STATE}"
    done <<< "${_OUT}"
}

# ─── Phase 2: diagnose ──────────────────────────────────────────────────────────

# Node name (ip-10-0-1-100) back to an address (10.0.1.100).
function nodename_to_ip() {
    local _N="${1#ip-}"
    echo "${_N//-/.}"
}

function diagnose() {
    local _I _J _IP _STATE

    # A Node object is stale when it is NotReady AND nothing is serving from its
    # address — either no instance holds it, or the instance that does is not
    # running k3s (the replaced-node-0 case, where the ghost and the replacement
    # share an IP).
    #
    # NotReady alone is never enough. A node whose k3s IS active but is reporting
    # NotReady may be partitioned or briefly wedged, and removing its etcd member
    # would turn a recoverable blip into a membership change we cannot undo.
    for ((_I=0; _I<${#NODE_NAMES[@]}; _I++)); do
        [[ "${NODE_STATES[$_I]}" == "Ready" ]] && continue
        _IP="$(nodename_to_ip "${NODE_NAMES[$_I]}")"
        _STATE="$(k3s_state_for_ip "${_IP}")"
        if [[ "${_STATE}" != "active" ]]; then
            STALE_NODES[${#STALE_NODES[@]}]="${NODE_NAMES[$_I]}"
        fi
    done

    # An instance needs joining when k3s is not running on it. Its Node object may
    # still exist (the ghost above), so presence in the node list proves nothing.
    for ((_J=0; _J<${#INSTANCE_IDS[@]}; _J++)); do
        if [[ "${INSTANCE_K3S[$_J]}" != "active" ]]; then
            UNJOINED_IDS[${#UNJOINED_IDS[@]}]="${INSTANCE_IDS[$_J]}"
            UNJOINED_IPS[${#UNJOINED_IPS[@]}]="${INSTANCE_IPS[$_J]}"
        fi
    done
}

function count_ready() {
    local _I _N=0
    for ((_I=0; _I<${#NODE_STATES[@]}; _I++)); do
        [[ "${NODE_STATES[$_I]}" == "Ready" ]] && _N=$((_N + 1))
    done
    echo "${_N}"
}

# ─── Phase 3: report ────────────────────────────────────────────────────────────

function report() {
    local _I _READY
    _READY=$(count_ready)

    echo "Cluster  : nickname=${NICKNAME}  region=${REGION}  profile=${PROFILE}"
    echo "Survivor : ${SURVIVOR_ID} (${SURVIVOR_IP})"
    echo ""
    echo "--- running controlplane instances (EC2 = ground truth) ---"
    for ((_I=0; _I<${#INSTANCE_IDS[@]}; _I++)); do
        printf '  %-20s %-40s %s\n' "${INSTANCE_IDS[$_I]}" "${INSTANCE_NAMES[$_I]}" "${INSTANCE_IPS[$_I]}"
    done
    echo ""
    echo "--- cluster node objects ---"
    for ((_I=0; _I<${#NODE_NAMES[@]}; _I++)); do
        printf '  %-20s %s\n' "${NODE_NAMES[$_I]}" "${NODE_STATES[$_I]}"
    done
    echo ""
    echo "Ready nodes: ${_READY}"
    echo ""
    echo "--- diagnosis ---"
    if (( ${#STALE_NODES[@]} == 0 )); then
        echo "  stale members  : none"
    else
        local _SIP _SSTATE _WHY
        for _I in "${STALE_NODES[@]}"; do
            # State the actual reason. In the replaced-node-0 case an instance DOES
            # hold the address — it just is not serving — and saying otherwise is
            # exactly the wrong thing to tell someone deciding whether to trust a
            # control-plane mutation.
            _SIP="$(nodename_to_ip "${_I}")"
            _SSTATE="$(k3s_state_for_ip "${_SIP}")"
            if [[ "${_SSTATE}" == "none" ]]; then
                _WHY="no running instance holds ${_SIP}"
            else
                _WHY="instance at ${_SIP} is not running k3s (state: ${_SSTATE})"
            fi
            echo "  stale member   : ${C_YLW}${_I}${C_RST}  (${_WHY})"
        done
    fi
    if (( ${#UNJOINED_IDS[@]} == 0 )); then
        echo "  unjoined nodes : none"
    else
        for ((_I=0; _I<${#UNJOINED_IDS[@]}; _I++)); do
            echo "  unjoined node  : ${C_YLW}${UNJOINED_IDS[$_I]}${C_RST} (${UNJOINED_IPS[$_I]})"
        done
    fi
    echo ""
}

# Refuse when removing a member would leave the cluster unable to survive a
# further loss. Members drop with the removal, and quorum is floor(n/2)+1.
function quorum_is_safe() {
    local _READY _MEMBERS_AFTER _QUORUM_AFTER
    _READY=$(count_ready)
    _MEMBERS_AFTER=$(( ${#NODE_NAMES[@]} - ${#STALE_NODES[@]} ))
    _QUORUM_AFTER=$(( _MEMBERS_AFTER / 2 + 1 ))

    if (( _READY < _QUORUM_AFTER )); then
        echo "${C_RED}Refusing to remove members.${C_RST}" >&2
        echo "  Ready nodes            : ${_READY}" >&2
        echo "  Members after removal  : ${_MEMBERS_AFTER} (quorum ${_QUORUM_AFTER})" >&2
        echo "  Removing now would leave the cluster below quorum. Restore a node first." >&2
        return 1
    fi
    return 0
}

# ─── Phase 4: repair ────────────────────────────────────────────────────────────

function remove_stale_members() {
    local _NAME
    for _NAME in "${STALE_NODES[@]}"; do
        echo "  removing stale member ${_NAME} ..."
        remote "${SURVIVOR_ID}" "kubectl delete node ${_NAME}" >/dev/null || {
            echo "${C_RED}  failed to remove ${_NAME}${C_RST}" >&2
            return 1
        }
        echo "  ${C_GRN}removed${C_RST} ${_NAME}"
    done
}

# Join via the survivor, not CONTROLLER_HOST — for a replaced node-0 that would
# point at itself. install_k3s_server's second argument exists for exactly this.
function join_unjoined_nodes() {
    local _I _ID _CMD
    for ((_I=0; _I<${#UNJOINED_IDS[@]}; _I++)); do
        _ID="${UNJOINED_IDS[$_I]}"
        echo "  joining ${_ID} via ${SURVIVOR_IP} ..."
        _CMD="bash -c \"systemctl stop k3s 2>/dev/null; rm -rf /var/lib/rancher/k3s/server/db; \
cd /opt/simplek3s/bootstrap/default; . ./lib/common.sh; . ./lib/providers/aws.sh; \
TOKEN=\\\$(get_ssm k3s-token decrypt); install_k3s_server \\\"\\\$TOKEN\\\" ${SURVIVOR_IP}\""
        remote "${_ID}" "${_CMD}" >/dev/null || true
        local _STATE
        _STATE=$(remote "${_ID}" "systemctl is-active k3s" || true)
        if [[ "${_STATE}" == *"active"* ]]; then
            echo "  ${C_GRN}joined${C_RST} ${_ID}"
        else
            echo "${C_RED}  ${_ID} did not come up (state: ${_STATE:-unknown})${C_RST}" >&2
            return 1
        fi
    done
}

# ─── Main ───────────────────────────────────────────────────────────────────────

PROFILE="" ; NICKNAME="" ; REGION=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "${1}" in
        --dry-run)  DRY_RUN=1 ; shift ;;
        --no-color) NO_COLOR=1 ; shift ;;
        -h|--help)  usage ;;
        -*)         echo "Unknown option: ${1}" >&2 ; usage ;;
        *)          POSITIONAL[${#POSITIONAL[@]}]="${1}" ; shift ;;
    esac
done
set -- ${POSITIONAL[@]+"${POSITIONAL[@]}"}

PROFILE="${1:-}"
[[ -z "${PROFILE}" ]] && usage
if (( $# == 2 || $# > 3 )); then
    echo "Error: expected <profile>, or <profile> <nickname> <region>." >&2
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

gather_instances || exit 1
gather_instance_states

if ! find_survivor; then
    echo "${C_RED}No healthy controlplane node found.${C_RST}" >&2
    echo "Repair needs at least one node serving the API to act through." >&2
    echo "See RUNBOOKS.md for the fully manual procedure." >&2
    exit 1
fi

gather_nodes || exit 1
diagnose
report

if (( ${#STALE_NODES[@]} == 0 && ${#UNJOINED_IDS[@]} == 0 )); then
    echo "${C_GRN}Nothing to repair.${C_RST}"
    exit 0
fi

if (( DRY_RUN == 1 )); then
    echo "--- plan (dry run, nothing changed) ---"
    for _N in ${STALE_NODES[@]+"${STALE_NODES[@]}"}; do
        echo "  would remove stale member : ${_N}"
    done
    for _N in ${UNJOINED_IDS[@]+"${UNJOINED_IDS[@]}"}; do
        echo "  would join node           : ${_N} via ${SURVIVOR_IP}"
    done
    quorum_is_safe || exit 1
    echo ""
    echo "Re-run without --dry-run to apply."
    exit 0
fi

if (( ${#STALE_NODES[@]} > 0 )); then
    quorum_is_safe || exit 1
    echo "--- removing stale members ---"
    remove_stale_members || exit 1
    echo ""
fi

if (( ${#UNJOINED_IDS[@]} > 0 )); then
    echo "--- joining unjoined nodes ---"
    join_unjoined_nodes || exit 1
    echo ""
fi

echo "--- post-repair state ---"
remote "${SURVIVOR_ID}" "kubectl get nodes" || true
echo ""
echo "${C_GRN}Repair complete.${C_RST} Run cluster_verify.yml to confirm — allow for the"
echo "pod-restart stability window before expecting a pass (see RUNBOOKS.md)."
