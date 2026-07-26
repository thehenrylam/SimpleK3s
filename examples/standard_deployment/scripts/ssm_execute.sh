#!/bin/bash

set -euo pipefail

# Runs a shell command on a cluster node via SSM.
#
# Three mutually exclusive modes:
#   --exec-cmd    send, wait, print the output
#   --exec-async  send and return the command id immediately
#   --exec-get    print the output of an earlier command id
#
# NOTE: the command runs as root (SSM's AWS-RunShellScript already does), so it
# does not need a sudo prefix.
#
# NOTE: SSM returns at most 24000 characters of stdout and 8000 of stderr; past
# that the result is cut and the remainder is unrecoverable through this API.
# Truncation is reported (WARNING, or "stdout_truncated" in --json) — narrow the
# output on the node rather than trusting a partial result.
#
# Exit codes: 0 succeeded, 1 failed, 2 bad usage, 3 still running.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/common.sh"

# GLOBAL VARIABLES
IAC_NAME_CLUSTER="standard_cluster"
IAC_TFVARS="$(get_tfvar_filepath "${SCRIPT_DIR}" "${IAC_NAME_CLUSTER}")"

POLL_INTERVAL=5
POLL_MAX=120  # 10 minutes

EXIT_OK=0
EXIT_FAIL=1
EXIT_USAGE=2
EXIT_RUNNING=3

# An explicit --help is a successful request: it prints to stdout and exits 0, so a
# caller can pipe it and cannot mistake it for the exit-2 usage error.
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
    echo "Usage: $(basename "$0") <profile> [<nickname> <region>] --instance-id <instance-id>"
    echo "         (--exec-cmd <command> | --exec-async <command> | --exec-get <command-id>)"
    echo "         [--json [pretty|compact]]"
    echo ""
    echo "  profile        AWS CLI profile (required)"
    echo "  nickname       Cluster nickname (default: inferred from terraform.tfvars)"
    echo "  region         AWS region      (default: inferred from terraform.tfvars)"
    echo "  --instance-id  Target node (required; must belong to the cluster)"
    echo ""
    echo "  --exec-cmd     Run a command and wait for its output"
    echo "  --exec-async   Run a command, print its command id, return immediately"
    echo "  --exec-get     Print the output of a previously issued command id"
    echo "  --json         Emit JSON; 'compact' is single-line for machine use"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") myprofile --instance-id i-0abc --exec-cmd \"kubectl get nodes\""
    echo "  $(basename "$0") myprofile --instance-id i-0abc --exec-cmd \"kubectl get pods -A\" --json compact"
    echo "  ID=\$($(basename "$0") myprofile --instance-id i-0abc --exec-async \"long-job.sh\")"
    echo "  $(basename "$0") myprofile --instance-id i-0abc --exec-get \"\$ID\" --json compact"
    echo ""
    echo "Exit codes: 0 succeeded, 1 failed, 2 bad usage, 3 still running"
    echo ""
    echo "--json fields:"
    echo "  nickname, region, instance_id   the cluster and node actually targeted"
    echo "  command_id, status, response_code (the remote command's exit code),"
    echo "  stdout_truncated, stderr_truncated, stdout, stderr,"
    echo "  truncation_note   present only when output was cut"
    echo ""
    echo "ALWAYS check stdout_truncated before drawing conclusions from stdout. SSM caps"
    echo "output at 24000 chars (stdout) / 8000 (stderr) and cuts mid-stream; the rest is"
    echo "unrecoverable. Filter on the node instead, e.g."
    echo "  --exec-cmd \"ls -la /usr/bin | tail -n 200\""
}

# Reject a second mode rather than silently honouring the last one
function set_mode() {
    if [[ -n "${MODE}" ]]; then
        echo "Error: --exec-cmd, --exec-async and --exec-get are mutually exclusive." >&2
        usage
    fi
    MODE="${1}"
    MODE_ARG="${2}"
}

# Status is authoritative; the process exit code just mirrors it for shell use.
function status_exit_code() {
    case "${1}" in
        Success)             echo "${EXIT_OK}" ;;
        InProgress|Pending)  echo "${EXIT_RUNNING}" ;;
        *)                   echo "${EXIT_FAIL}" ;;
    esac
}

function report() {
    # VARIABLES
    local _RESULT _STATUS
    # INPUTS
    _RESULT="${1}"
    # PROCESS
    _STATUS="$(parse_command_invocation_result "${_RESULT}" "Status")"
    if [[ -n "${JSON_MODE}" ]]; then
        invocation_to_json "${_RESULT}" "${INSTANCE_ID}" "${NICKNAME}" "${REGION}" \
            | format_json "${JSON_MODE}"
    else
        ssm_report_result "${_RESULT}" || true
    fi
    # OUTPUT VALUES
    return "$(status_exit_code "${_STATUS}")"
}

function execute_command() {
    # VARIABLES
    local _COMMAND_ID _RESULT
    # PROCESS
    verify_instance_id "${INSTANCE_ID}" "${REGION}" "${PROFILE}" "${NICKNAME}" "true"
    _COMMAND_ID="$(ssm_send_command "${REGION}" "${PROFILE}" "${INSTANCE_ID}" "${MODE_ARG}")"
    _RESULT="$(ssm_await_completion "${REGION}" "${PROFILE}" "${INSTANCE_ID}" "${_COMMAND_ID}" \
        "${POLL_MAX}" "${POLL_INTERVAL}")"
    report "${_RESULT}"
}

function execute_async() {
    # VARIABLES
    local _COMMAND_ID
    # PROCESS
    verify_instance_id "${INSTANCE_ID}" "${REGION}" "${PROFILE}" "${NICKNAME}" "true"
    _COMMAND_ID="$(ssm_send_command "${REGION}" "${PROFILE}" "${INSTANCE_ID}" "${MODE_ARG}")"
    if [[ -n "${JSON_MODE}" ]]; then
        dispatch_to_json "${INSTANCE_ID}" "${NICKNAME}" "${REGION}" "${_COMMAND_ID}" \
            | format_json "${JSON_MODE}"
    else
        echo "Command ID: ${_COMMAND_ID}"
    fi
}

function execute_get() {
    # VARIABLES
    local _RESULT
    # PROCESS
    # A finished command's output outlives the node, so do not demand it is running
    verify_instance_id "${INSTANCE_ID}" "${REGION}" "${PROFILE}" "${NICKNAME}" "false"
    _RESULT="$(ssm_get_command_invocation "${REGION}" "${PROFILE}" "${INSTANCE_ID}" "${MODE_ARG}")"
    if [[ -z "${_RESULT}" ]]; then
        echo "Error: no invocation found for command id '${MODE_ARG}' on ${INSTANCE_ID}." >&2
        return "${EXIT_FAIL}"
    fi
    report "${_RESULT}"
}

# GATHER INPUTS
INSTANCE_ID=""
MODE=""
MODE_ARG=""
JSON_MODE=""
POSITIONAL=()
while (( $# > 0 )); do
    case "${1}" in
        --instance-id|--exec-cmd|--exec-async|--exec-get)
            if (( $# < 2 )); then
                echo "Error: ${1} requires a value." >&2
                usage
            fi
            case "${1}" in
                --instance-id) INSTANCE_ID="${2}" ;;
                --exec-cmd)    set_mode "cmd" "${2}" ;;
                --exec-async)  set_mode "async" "${2}" ;;
                --exec-get)    set_mode "get" "${2}" ;;
            esac
            shift 2
            ;;
        --json=*)
            JSON_MODE="${1#--json=}"
            if [[ "${JSON_MODE}" != "pretty" && "${JSON_MODE}" != "compact" ]]; then
                echo "Error: unknown --json mode '${JSON_MODE}' (expected pretty or compact)." >&2
                usage
            fi
            shift
            ;;
        --json)
            # The specifier is optional, so only a recognised one is consumed.
            # Anything else stays a positional and is caught by the arity check
            # below — it must not slide silently into the nickname slot.
            if [[ "${2:-}" == "pretty" || "${2:-}" == "compact" ]]; then
                JSON_MODE="${2}"
                shift 2
            else
                JSON_MODE="pretty"
                shift
            fi
            ;;
        -h|--help)
            usage "${EXIT_OK}"
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
# nickname and region are a pair, so 2 positionals is always a mistake. This is
# also what turns a mistyped `--json josn` into an error instead of silently
# retargeting the run at a cluster named "josn".
if (( ${#POSITIONAL[@]} == 2 || ${#POSITIONAL[@]} > 3 )); then
    echo "Error: expected <profile>, or <profile> <nickname> <region>." >&2
    echo "       Got ${#POSITIONAL[@]}: ${POSITIONAL[*]}" >&2
    usage
fi
if [[ -z "${NICKNAME}" || -z "${REGION}" ]]; then
    echo "Error: could not infer nickname/region from ${IAC_TFVARS} — supply them as arguments." >&2
    usage
fi
if [[ -z "${INSTANCE_ID}" ]]; then
    echo "Error: --instance-id is required." >&2
    echo "       List the cluster's instances with: ./pick_instance.py --region ${REGION} --profile ${PROFILE} --nickname ${NICKNAME} --list" >&2
    usage
fi
if [[ -z "${MODE}" ]]; then
    echo "Error: one of --exec-cmd, --exec-async or --exec-get is required." >&2
    usage
fi
# Only checks with a definite right answer live here. The command body itself is
# deliberately not inspected: it is arbitrary remote shell, so there is nothing
# to validate it against, and escaping it at the payload boundary is what makes
# it safe to send. See build_command_parameters in common.sh.
if [[ "${MODE}" != "get" && ! "${MODE_ARG}" =~ [^[:space:]] ]]; then
    echo "Error: the command given to --exec-${MODE} is empty." >&2
    usage
fi
if [[ "${MODE}" == "get" ]]; then
    UUID_RE='^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
    if [[ ! "${MODE_ARG}" =~ ${UUID_RE} ]]; then
        echo "Error: '${MODE_ARG}' is not a valid command id." >&2
        echo "       SSM command ids are UUIDs, e.g. 1d3a4b5c-6789-4012-b345-6789abcdef01" >&2
        usage
    fi
fi
require_pick_instance

# EXECUTE SCRIPT
case "${MODE}" in
    cmd)   execute_command ;;
    async) execute_async ;;
    get)   execute_get ;;
esac
