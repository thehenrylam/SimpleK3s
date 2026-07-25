#!/bin/bash

set -euo pipefail

# Run verify_cluster.sh on a controlplane node via SSM without needing to look
# up an instance ID manually. The controlplane node is located by the Nickname
# tag; any running controlplane node can run the check.
#
# Usage:
#   ./scripts/ssm_verify_cluster.sh <profile> [<nickname> [<region>]]
#
# Arguments:
#   profile   AWS CLI profile to use (required)
#   nickname  Cluster nickname tag (default: inferred from examples/ex_basic/terraform.tfvars)
#   region    AWS region          (default: inferred from examples/ex_basic/terraform.tfvars)
#
# Environment variables:
#   STABILITY_WINDOW_SECONDS  Passed through to verify_cluster.sh (default: 300)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/common.sh"

# GLOBAL VARIABLES
IAC_NAME_CLUSTER="standard_cluster"
IAC_TFVARS="$(get_tfvar_filepath "${SCRIPT_DIR}" "${IAC_NAME_CLUSTER}")"

SIMPLEK3S_SCRIPT_DIR="$(get_node_script_dir "${SCRIPT_DIR}")"
SIMPLEK3S_VERIFY="${SIMPLEK3S_SCRIPT_DIR}/node_verify-all.sh"

POLL_INTERVAL=5
POLL_MAX=120  # 10 minutes

function usage() {
    echo "Usage: $(basename "$0") <profile> [<nickname> [<region>]]" >&2
    echo "" >&2
    echo "  profile   AWS CLI profile (required)" >&2
    echo "  nickname  Cluster nickname (default: inferred from terraform.tfvars)" >&2
    echo "  region    AWS region      (default: inferred from terraform.tfvars)" >&2
    exit 2
}

function get_instance_id() {
    # VARIABLES
    local _REGION _PROFILE _NICKNAME
    local _OUTPUT
    # INPUTS
    _REGION="${1}"
    _PROFILE="${2}"
    _NICKNAME="${3}"
    # PROCESS
    # Find any running controlplane instance for this cluster
    _OUTPUT=$(aws ec2 describe-instances \
        --region "${_REGION}" \
        --profile "${_PROFILE}" \
        --filters \
            "Name=tag:Nickname,Values=${_NICKNAME}" \
            "Name=tag:Name,Values=*_controlplane-*" \
            "Name=instance-state-name,Values=running" \
        --query "Reservations[0].Instances[0].InstanceId" \
        --output text)
    # VERIFY
    if [[ -z "${_OUTPUT}" || "${_OUTPUT}" == "None" ]]; then
        echo "Error: no running controlplane instance found for nickname '${_NICKNAME}' in ${_REGION}." >&2
        return 1
    fi
    # OUTPUT VALUES
    echo "${_OUTPUT}"
}

function ssm_send_command() {
    # VARIABLES
    local _REGION _PROFILE _INSTANCE_ID _COMMAND
    local _STABILITY_ENV
    local _OUTPUT
    # INPUTS
    _REGION="${1}"
    _PROFILE="${2}"
    _INSTANCE_ID="${3}"
    _COMMAND="${4}"
    # PROCESS
    # Determine the stability env
    _STABILITY_ENV=""
    if [[ -n "${STABILITY_WINDOW_SECONDS:-}" ]]; then
        _STABILITY_ENV="STABILITY_WINDOW_SECONDS=${STABILITY_WINDOW_SECONDS} "
    fi
    # Send the command via SSM
    _OUTPUT=$(aws ssm send-command \
        --region "$_REGION" \
        --profile "$_PROFILE" \
        --instance-ids "$_INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters "commands=[\"sudo ${_STABILITY_ENV}bash ${_COMMAND}\"]" \
        --query "Command.CommandId" \
        --output text)
    # OUTPUT VALUES
    echo "${_OUTPUT}"
}

function ssm_get_command_invocation() {
    # VARIABLES
    local _REGION _PROFILE _INSTANCE_ID _COMMAND_ID
    # INPUTS
    _REGION="${1}"
    _PROFILE="${2}"
    _INSTANCE_ID="${3}"
    _COMMAND_ID="${4}"
    # PROCESS
    _OUTPUT=$(aws ssm get-command-invocation \
        --region "${_REGION}" \
        --profile "${_PROFILE}" \
        --command-id "${_COMMAND_ID}" \
        --instance-id "${_INSTANCE_ID}" 2>/dev/null || true)
    # OUTPUT VALUES
    echo "${_OUTPUT}"
}

function parse_command_invocation_result() {
    # VARIABLES
    local _RESULT _KEY
    local _OUTPUT
    # INPUTS
    _RESULT="${1}"
    _KEY="${2}"
    # PROCESS
    _OUTPUT=$(echo "$_RESULT" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('${_KEY}',''))" 2>/dev/null || true)
    # OUTPUT VALUES
    echo "${_OUTPUT}"
}

function verify_cluster() {
    echo "Cluster  : nickname=${NICKNAME}  region=${REGION}  profile=${PROFILE}"

    # Find any running controlplane instance for this cluster
    INSTANCE_ID=$(get_instance_id "$REGION" "$PROFILE" "$NICKNAME" || exit 1)

    echo "Instance : ${INSTANCE_ID}"
    echo "Script   : ${SIMPLEK3S_VERIFY}"
    echo ""

    # Send the SSM command
    COMMAND_ID=$(ssm_send_command "${REGION}" "${PROFILE}" "${INSTANCE_ID}" "${SIMPLEK3S_VERIFY}" || exit 1)

    echo "Command ID: ${COMMAND_ID}"
    echo "Polling for output (up to $((POLL_MAX * POLL_INTERVAL / 60)) min)..."
    echo ""

    # Poll until the command finishes
    RESULT=""
    STATUS=""
    for ((i=1; i<=POLL_MAX; i++)); do
        # Get the result of the command invocation
        RESULT=$(ssm_get_command_invocation "${REGION}" "${PROFILE}" "${INSTANCE_ID}" "${COMMAND_ID}" || exit 1)
        # Get the status of the command invocation
        STATUS=$(parse_command_invocation_result "${RESULT}" "Status" || exit 1)
        # If the status IS NOT "in progress", "pending", or *null*, then exit the loop and output the result
        if [[ "$STATUS" != "InProgress" && "$STATUS" != "Pending" && -n "$STATUS" ]]; then
            break
        fi
        echo "  (${i}/${POLL_MAX}) ${STATUS:-Pending} — waiting ${POLL_INTERVAL}s..."
        sleep "$POLL_INTERVAL"
    done

    # Print output
    STDOUT=$(parse_command_invocation_result "${RESULT}" "StandardOutputContent" || exit 1)
    STDERR=$(parse_command_invocation_result "${RESULT}" "StandardErrorContent" || exit 1)

    if [[ -n "$STDOUT" ]]; then
        echo "--- stdout ---"
        echo "$STDOUT"
    fi

    if [[ -n "$STDERR" ]]; then
        echo "--- stderr ---"
        echo "$STDERR"
    fi

    echo ""
    echo "Result: ${STATUS}"

    [[ "$STATUS" == "Success" ]] && return 0 || return 1
}

# GATHER INPUTS
PROFILE="${1:-}"
NICKNAME="${2:-$(infer_tfvar "${IAC_TFVARS}" "nickname")}"
REGION="${3:-$(infer_tfvar "${IAC_TFVARS}" "aws_region")}"

# VERIFY INPUTS
if [[ -z "$PROFILE" ]]; then
    usage
fi
if [[ -z "$NICKNAME" || -z "$REGION" ]]; then
    echo "Error: could not infer nickname/region from $IAC_TFVARS — supply them as arguments." >&2
    usage
fi

# EXECUTE SCRIPT
verify_cluster || exit 1
