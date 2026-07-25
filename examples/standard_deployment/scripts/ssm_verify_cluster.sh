#!/bin/bash

set -euo pipefail

# Executes node_verify-all.sh on a controlplane node via SSM. 
# The node is located by its Nickname tag; any running controlplane node can run it.
#
# NOTE: Environment Variable
# - STABILITY_WINDOW_SECONDS is passed through to the remote script

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/common.sh"

# GLOBAL VARIABLES
IAC_NAME_CLUSTER="standard_cluster"
IAC_TFVARS="$(get_tfvar_filepath "${SCRIPT_DIR}" "${IAC_NAME_CLUSTER}")"

SIMPLEK3S_SCRIPT_DIR="$(get_node_script_dir)"
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

# _ENV_VARS is optional: "KEY=VALUE [KEY=VALUE ...]" prefixed to the remote
# command, or empty for none. Taken as an input rather than read from the
# environment so the command sent is a function of the arguments alone.
function ssm_send_command() {
    # VARIABLES
    local _REGION _PROFILE _INSTANCE_ID _COMMAND _ENV_VARS
    local _ENV_PREFIX
    local _OUTPUT
    # INPUTS
    _REGION="${1}"
    _PROFILE="${2}"
    _INSTANCE_ID="${3}"
    _COMMAND="${4}"
    _ENV_VARS="${5:-}"
    # PROCESS
    # Separate the assignments from the command, only when there are any
    _ENV_PREFIX=""
    if [[ -n "${_ENV_VARS}" ]]; then
        _ENV_PREFIX="${_ENV_VARS} "
    fi
    # Send the command via SSM
    _OUTPUT=$(aws ssm send-command \
        --region "$_REGION" \
        --profile "$_PROFILE" \
        --instance-ids "$_INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters "commands=[\"sudo ${_ENV_PREFIX}bash ${_COMMAND}\"]" \
        --query "Command.CommandId" \
        --output text)
    # OUTPUT VALUES
    echo "${_OUTPUT}"
}

function ssm_get_command_invocation() {
    # VARIABLES
    local _REGION _PROFILE _INSTANCE_ID _COMMAND_ID
    local _OUTPUT
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

    # Build Environment Variables (STABILITY_WINDOW_SECONDS)
    # How far back node_verify-all.sh looks for pod restarts (Default: 300)
    SSM_ENV_VARS=""
    if [[ -n "${STABILITY_WINDOW}" ]]; then
        SSM_ENV_VARS="STABILITY_WINDOW_SECONDS=${STABILITY_WINDOW}"
    fi

    # Find any running controlplane instance for this cluster
    INSTANCE_ID=$(get_instance_id "$REGION" "$PROFILE" "$NICKNAME")

    echo "Instance : ${INSTANCE_ID}"
    echo "Script   : ${SIMPLEK3S_VERIFY}"
    echo "Env Vars : ${SSM_ENV_VARS:-"--N/A--"}"
    echo ""

    # Send the SSM command
    COMMAND_ID=$(ssm_send_command "${REGION}" "${PROFILE}" "${INSTANCE_ID}" "${SIMPLEK3S_VERIFY}" "${SSM_ENV_VARS}")

    echo "Command ID: ${COMMAND_ID}"
    echo "Polling for output (up to $((POLL_MAX * POLL_INTERVAL / 60)) min)..."
    echo ""

    # Poll until the command finishes
    RESULT=""
    STATUS=""
    for ((i=1; i<=POLL_MAX; i++)); do
        # Get the result of the command invocation
        RESULT=$(ssm_get_command_invocation "${REGION}" "${PROFILE}" "${INSTANCE_ID}" "${COMMAND_ID}")
        # Get the status of the command invocation
        STATUS=$(parse_command_invocation_result "${RESULT}" "Status")
        # If the status IS NOT "in progress", "pending", or *null*, then exit the loop and output the result
        if [[ "$STATUS" != "InProgress" && "$STATUS" != "Pending" && -n "$STATUS" ]]; then
            break
        fi
        echo "  (${i}/${POLL_MAX}) ${STATUS:-Pending} — waiting ${POLL_INTERVAL}s..."
        sleep "$POLL_INTERVAL"
    done

    # Print output
    STDOUT=$(parse_command_invocation_result "${RESULT}" "StandardOutputContent")
    STDERR=$(parse_command_invocation_result "${RESULT}" "StandardErrorContent")

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

    [[ "$STATUS" == "Success" ]]
}

# GATHER INPUTS
PROFILE="${1:-}"
NICKNAME="${2:-$(infer_tfvar "${IAC_TFVARS}" "nickname")}"
REGION="${3:-$(infer_tfvar "${IAC_TFVARS}" "aws_region")}"
STABILITY_WINDOW="${STABILITY_WINDOW_SECONDS:-}"

# VERIFY INPUTS
if [[ -z "$PROFILE" ]]; then
    usage
fi
if [[ -z "$NICKNAME" || -z "$REGION" ]]; then
    echo "Error: could not infer nickname/region from $IAC_TFVARS — supply them as arguments." >&2
    usage
fi
# Reject anything but a positive integer: the value is interpolated into the
# remote command, and node_verify-all.sh discards the resulting error, so a
# malformed window silently skips the pod-restart check and still reports PASS.
if [[ -n "${STABILITY_WINDOW}" && ! "${STABILITY_WINDOW}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: STABILITY_WINDOW_SECONDS must be a positive integer (got '${STABILITY_WINDOW}')." >&2
    exit 2
fi

# EXECUTE SCRIPT
verify_cluster
