#!/bin/bash

set -euo pipefail

# Syncs the latest bootstrap files from S3 and re-stages all manifests on a
# controlplane node via SSM. Run after `tofu apply` uploads new manifests.
# The node is located by its Nickname tag; any running controlplane node can run it.
#
# Both scripts run in one shell so `&&` short-circuits on a refresh failure
# before the update is attempted.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/common.sh"

# GLOBAL VARIABLES
IAC_NAME_CLUSTER="standard_cluster"
IAC_TFVARS="$(get_tfvar_filepath "${SCRIPT_DIR}" "${IAC_NAME_CLUSTER}")"

SIMPLEK3S_SCRIPT_DIR="$(get_node_script_dir)"
SIMPLEK3S_REFRESH="${SIMPLEK3S_SCRIPT_DIR}/node_refresh-bootstrap-files.sh"
SIMPLEK3S_UPDATE="${SIMPLEK3S_SCRIPT_DIR}/node_init-services.sh"

POLL_INTERVAL=5
POLL_MAX=180  # 15 minutes

function usage() {
    echo "Usage: $(basename "$0") <profile> [<nickname> <region>]" >&2
    echo "" >&2
    echo "  profile   AWS CLI profile (required)" >&2
    echo "  nickname  Cluster nickname (default: inferred from terraform.tfvars)" >&2
    echo "  region    AWS region      (default: inferred from terraform.tfvars)" >&2
    exit 2
}

function update_services() {
    # VARIABLES
    local _REMOTE_COMMAND
    local _INSTANCE_ID _COMMAND_ID _RESULT

    echo "Cluster  : nickname=${NICKNAME}  region=${REGION}  profile=${PROFILE}"

    _REMOTE_COMMAND="$(build_remote_command "${SIMPLEK3S_REFRESH}") && $(build_remote_command "${SIMPLEK3S_UPDATE}")"

    # Find any running controlplane instance for this cluster
    _INSTANCE_ID=$(get_controlplane_instance_id "${REGION}" "${PROFILE}" "${NICKNAME}")

    echo "Instance : ${_INSTANCE_ID}"
    echo "Chain    : ${SIMPLEK3S_REFRESH} && ${SIMPLEK3S_UPDATE}"
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

# EXECUTE SCRIPT
update_services
