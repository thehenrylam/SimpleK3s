#!/bin/bash

set -euo pipefail

# Lists the cluster's EC2 instances, grouped by availability zone.
#
# A thin wrapper over pick_instance.py so every ssm_*.sh script shares one
# argument convention: <profile> [<nickname> <region>].
#
# Usage:
#   ./ssm_list_instances.sh <profile> [<nickname> <region>] [--json [pretty|compact]]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/common.sh"

# GLOBAL VARIABLES
IAC_NAME_CLUSTER="standard_cluster"
IAC_TFVARS="$(get_tfvar_filepath "${SCRIPT_DIR}" "${IAC_NAME_CLUSTER}")"

EXIT_USAGE=2

# An explicit --help is a successful request: stdout and exit 0, so it can be
# piped and is not mistaken for the exit-2 usage error.
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
    echo "Usage: $(basename "$0") <profile> [<nickname> <region>] [--json [pretty|compact]]"
    echo ""
    echo "  profile   AWS CLI profile (required)"
    echo "  nickname  Cluster nickname (default: inferred from terraform.tfvars)"
    echo "  region    AWS region      (default: inferred from terraform.tfvars)"
    echo "  --json    Emit JSON; 'compact' is single-line for machine use"
    echo ""
    echo "Instances are grouped by availability zone, ordered by launch time."
    echo "Only 'running' instances accept commands from ssm_execute.sh."
    echo ""
    echo "--json fields:"
    echo "  nickname, region, profile   the cluster this listing describes"
    echo "  instances[]                 instance_id, name, role, state, instance_type,"
    echo "                              az, private_ip, public_ip, launched"
}

function list_instances() {
    if [[ -n "${JSON_MODE}" ]]; then
        pick_instance "${REGION}" "${PROFILE}" "${NICKNAME}" --json | format_json "${JSON_MODE}"
    else
        echo "Cluster  : nickname=${NICKNAME}  region=${REGION}  profile=${PROFILE}"
        echo ""
        pick_instance "${REGION}" "${PROFILE}" "${NICKNAME}" --table
    fi
}

# GATHER INPUTS
JSON_MODE=""
POSITIONAL=()
while (( $# > 0 )); do
    case "${1}" in
        --json=*)
            JSON_MODE="${1#--json=}"
            if [[ "${JSON_MODE}" != "pretty" && "${JSON_MODE}" != "compact" ]]; then
                echo "Error: unknown --json mode '${JSON_MODE}' (expected pretty or compact)." >&2
                usage
            fi
            shift
            ;;
        --json)
            # Only a recognised specifier is consumed; anything else stays a
            # positional and is caught by the arity check below.
            if [[ "${2:-}" == "pretty" || "${2:-}" == "compact" ]]; then
                JSON_MODE="${2}"
                shift 2
            else
                JSON_MODE="pretty"
                shift
            fi
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
# nickname and region are a pair, so 2 positionals is always a mistake — and it
# is what turns a mistyped `--json josn` into an error rather than a silent
# retarget at a cluster named "josn".
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
list_instances
