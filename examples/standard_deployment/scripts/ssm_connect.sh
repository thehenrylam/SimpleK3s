#!/bin/bash

set -euo pipefail

# Opens an interactive SSM shell on a cluster node.
# Without --instance-id, ssm_pick_instance.py presents a live picker of the
# cluster's instances instead of making you look one up in the console.
#
# Usage:
#   ./ssm_connect.sh <profile> [<nickname> <region>] [--instance-id <instance-id>]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/common.sh"

# GLOBAL VARIABLES
IAC_NAME_CLUSTER="standard_cluster"
IAC_TFVARS="$(get_tfvar_filepath "${SCRIPT_DIR}" "${IAC_NAME_CLUSTER}")"

EXIT_USAGE=2

function usage() {
    # An explicit --help is a successful request: stdout, exit 0. Usage shown
    # because the invocation was wrong goes to stderr and exits EXIT_USAGE.
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
    echo "Usage: $(basename "$0") <profile> [<nickname> <region>] [--instance-id <instance-id>]"
    echo ""
    echo "  profile       AWS CLI profile (required)"
    echo "  nickname      Cluster nickname (default: inferred from terraform.tfvars)"
    echo "  region        AWS region      (default: inferred from terraform.tfvars)"
    echo "  --instance-id Connect straight to this instance, skipping the picker"
}

function ssm_start_session() {
    # VARIABLES
    local _REGION _PROFILE _INSTANCE_ID
    # INPUTS
    _REGION="${1}"
    _PROFILE="${2}"
    _INSTANCE_ID="${3}"
    # PROCESS
    aws ssm start-session \
        --target "${_INSTANCE_ID}" \
        --region "${_REGION}" \
        --profile "${_PROFILE}" \
        --document-name AWS-StartInteractiveCommand \
        --parameters command="bash"
}

function connect_to_node() {
    # VARIABLES
    local _INSTANCE_ID
    # PROCESS
    echo "Cluster  : nickname=${NICKNAME}  region=${REGION}  profile=${PROFILE}"
    if [[ -n "${INSTANCE_ID}" ]]; then
        verify_instance_id "${INSTANCE_ID}" "${REGION}" "${PROFILE}" "${NICKNAME}" "true"
        _INSTANCE_ID="${INSTANCE_ID}"
    else
        # The picker reports its own errors and exits non-zero, which `set -e`
        # propagates: 1 for no instances or no terminal, 130 for cancelled.
        _INSTANCE_ID="$(pick_instance "${REGION}" "${PROFILE}" "${NICKNAME}")"
    fi
    echo "Instance : ${_INSTANCE_ID}"
    echo ""
    ssm_start_session "${REGION}" "${PROFILE}" "${_INSTANCE_ID}"
}

# GATHER INPUTS
INSTANCE_ID=""
POSITIONAL=()
while (( $# > 0 )); do
    case "${1}" in
        --instance-id)
            if (( $# < 2 )); then
                echo "Error: --instance-id requires a value." >&2
                usage
            fi
            INSTANCE_ID="${2}"
            shift 2
            ;;
        -h|--help)
            usage 0
            ;;
        -*)
            echo "Error: unknown option '${1}'." >&2
            usage
            ;;
        *)
            POSITIONAL+=("${1}")
            shift
            ;;
    esac
done

PROFILE="${POSITIONAL[0]:-}"
NICKNAME="${POSITIONAL[1]:-$(infer_tfvar "${IAC_TFVARS}" "nickname")}"
REGION="${POSITIONAL[2]:-$(infer_tfvar "${IAC_TFVARS}" "aws_region")}"

# VERIFY INPUTS
if [[ -z "${PROFILE}" ]]; then
    usage
fi
# Nickname and region are supplied as a pair, consistently across every ssm_*.sh,
# so 2 positionals is always a mistake.
if (( ${#POSITIONAL[@]} == 2 || ${#POSITIONAL[@]} > 3 )); then
    echo "Error: expected <profile>, or <profile> <nickname> <region>." >&2
    echo "       Got ${#POSITIONAL[@]}: ${POSITIONAL[*]}" >&2
    usage
fi
if [[ -z "${NICKNAME}" || -z "${REGION}" ]]; then
    echo "Error: could not infer nickname/region from ${IAC_TFVARS} — supply them as arguments." >&2
    usage
fi
require_pick_instance

# EXECUTE SCRIPT
connect_to_node
