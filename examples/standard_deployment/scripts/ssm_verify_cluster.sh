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
    echo "Usage: $(basename "$0") <profile> [<nickname> <region>]" >&2
    echo "" >&2
    echo "  profile   AWS CLI profile (required)" >&2
    echo "  nickname  Cluster nickname (default: inferred from terraform.tfvars)" >&2
    echo "  region    AWS region      (default: inferred from terraform.tfvars)" >&2
    exit 2
}

function verify_cluster() {
    # VARIABLES
    local _ENV_VARS _REMOTE_COMMAND
    local _INSTANCE_ID _COMMAND_ID _RESULT

    echo "Cluster  : nickname=${NICKNAME}  region=${REGION}  profile=${PROFILE}"

    # Build Environment Variables (STABILITY_WINDOW_SECONDS)
    # How far back node_verify-all.sh looks for pod restarts (Default: 300)
    _ENV_VARS=""
    if [[ -n "${STABILITY_WINDOW}" ]]; then
        _ENV_VARS="STABILITY_WINDOW_SECONDS=${STABILITY_WINDOW}"
    fi
    _REMOTE_COMMAND="$(build_remote_command "${SIMPLEK3S_VERIFY}" "${_ENV_VARS}")"

    # Find any running controlplane instance for this cluster
    _INSTANCE_ID=$(get_controlplane_instance_id "${REGION}" "${PROFILE}" "${NICKNAME}")

    echo "Instance : ${_INSTANCE_ID}"
    echo "Script   : ${SIMPLEK3S_VERIFY}"
    echo "Env Vars : ${_ENV_VARS:-"--N/A--"}"
    echo ""

    # Send the SSM command, wait it out, then report what came back
    _COMMAND_ID=$(ssm_send_command "${REGION}" "${PROFILE}" "${_INSTANCE_ID}" "${_REMOTE_COMMAND}")
    _RESULT=$(ssm_await_completion "${REGION}" "${PROFILE}" "${_INSTANCE_ID}" "${_COMMAND_ID}" \
        "${POLL_MAX}" "${POLL_INTERVAL}")
    ssm_report_result "${_RESULT}"
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
# Nickname and region are supplied as a pair, consistently across every ssm_*.sh,
# so 2 positionals is always a mistake.
if (( $# == 2 || $# > 3 )); then
    echo "Error: expected <profile>, or <profile> <nickname> <region>." >&2
    echo "       Got $#: $*" >&2
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
