#!/bin/bash

# Shared helpers for the ssm_* scripts. Every function takes what it needs as
# arguments and reads nothing from the ambient environment, so what a script
# sends is a function of its inputs alone.

# ─── Terraform inputs ────────────────────────────────────────────────────────

# Get TFVAR filepaths
function get_tfvar_filepath() {
    # VARIABLES
    local _SCRIPT_DIR _IAC_MODULE
    local _REPO_ROOT _MODULE_DIR
    local _OUTPUT
    # INPUTS
    _SCRIPT_DIR="$1"
    _IAC_MODULE="$2"
    # PROCESS
    _REPO_ROOT="$(cd "${_SCRIPT_DIR}/.." && pwd)"
    _MODULE_DIR="${_REPO_ROOT}/terraform/${_IAC_MODULE}"
    _OUTPUT="${_MODULE_DIR}/terraform.tfvars"
    # VERIFY
    if [[ ! -d "${_MODULE_DIR}" ]]; then
        echo "Error: no terraform module '${_IAC_MODULE}' at ${_MODULE_DIR}." >&2
        return 1
    fi
    # OUTPUT VALUES
    printf '%s\n' "${_OUTPUT}"
}

# Get the node script directory (that is found within the cluster)
function get_node_script_dir() {
    # HARDCODED: This is a convention for SimpleK3s (Points to SimpleK3s bootstrap dir)
    echo "/opt/simplek3s/bootstrap/default"
}

# Infer a TFVAR value (takes the tfvars filepath and the variable name)
function infer_tfvar() {
    # VARIABLES
    local _VARIABLE _TFVARS
    # INPUTS
    _TFVARS="$1"
    _VARIABLE="$2"
    # VERIFY
    if [[ ! -f "${_TFVARS}" ]]; then
        echo "Error: ${_TFVARS} does not exist." >&2
        echo "       Create it from $(dirname "${_TFVARS}")/terraform.TEMPLATE.tfvars" >&2
        echo "       (see README 'First Time Setup')," >&2
        echo "       or pass the nickname and region as arguments." >&2
        return 1
    fi
    # OUTPUT VALUES
    grep -m1 "^${_VARIABLE}[[:space:]]*=" "${_TFVARS}" \
        | awk -F'"' '{print $2}' || true
}

# ─── Cluster discovery ───────────────────────────────────────────────────────

# Find any running controlplane node for a cluster; any of them can run the
# node scripts, so the first match is as good as the rest.
function get_controlplane_instance_id() {
    # VARIABLES
    local _REGION _PROFILE _NICKNAME
    local _OUTPUT
    # INPUTS
    _REGION="${1}"
    _PROFILE="${2}"
    _NICKNAME="${3}"
    # PROCESS
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

# ─── Remote execution ────────────────────────────────────────────────────────

# Compose one remote command: "sudo [KEY=VALUE ...] bash <script>".
# _ENV_VARS is optional and must land after `sudo` — assignments placed before
# it are dropped by sudo's env reset. Chain with " && " to run several.
function build_remote_command() {
    # VARIABLES
    local _SCRIPT _ENV_VARS
    local _ENV_PREFIX
    # INPUTS
    _SCRIPT="${1}"
    _ENV_VARS="${2:-}"
    # PROCESS
    _ENV_PREFIX=""
    if [[ -n "${_ENV_VARS}" ]]; then
        _ENV_PREFIX="${_ENV_VARS} "
    fi
    # OUTPUT VALUES
    printf '%s\n' "sudo ${_ENV_PREFIX}bash ${_SCRIPT}"
}

# Dispatch a remote command and return its CommandId.
function ssm_send_command() {
    # VARIABLES
    local _REGION _PROFILE _INSTANCE_ID _COMMAND
    local _OUTPUT
    # INPUTS
    _REGION="${1}"
    _PROFILE="${2}"
    _INSTANCE_ID="${3}"
    _COMMAND="${4}"
    # PROCESS
    _OUTPUT=$(aws ssm send-command \
        --region "${_REGION}" \
        --profile "${_PROFILE}" \
        --instance-ids "${_INSTANCE_ID}" \
        --document-name "AWS-RunShellScript" \
        --parameters "commands=[\"${_COMMAND}\"]" \
        --query "Command.CommandId" \
        --output text)
    # OUTPUT VALUES
    echo "${_OUTPUT}"
}

# Retrieve the command's invocation data (Contains values like status, stdout, stderr, etc)
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
    _OUTPUT=$(echo "${_RESULT}" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('${_KEY}',''))" 2>/dev/null || true)
    # OUTPUT VALUES
    echo "${_OUTPUT}"
}

# Poll until the invocation reaches a terminal status, then return its raw JSON.
# Progress is written to stderr so the caller can capture the JSON from stdout.
function ssm_await_completion() {
    # VARIABLES
    local _REGION _PROFILE _INSTANCE_ID _COMMAND_ID _POLL_MAX _POLL_INTERVAL
    local _RESULT _STATUS _I
    # INPUTS
    _REGION="${1}"
    _PROFILE="${2}"
    _INSTANCE_ID="${3}"
    _COMMAND_ID="${4}"
    _POLL_MAX="${5}"
    _POLL_INTERVAL="${6}"
    # PROCESS
    echo "Command ID: ${_COMMAND_ID}" >&2
    echo "Polling for output (up to $((_POLL_MAX * _POLL_INTERVAL / 60)) min)..." >&2
    echo "" >&2
    _RESULT=""
    _STATUS=""
    for ((_I=1; _I<=_POLL_MAX; _I++)); do
        _RESULT=$(ssm_get_command_invocation "${_REGION}" "${_PROFILE}" "${_INSTANCE_ID}" "${_COMMAND_ID}")
        _STATUS=$(parse_command_invocation_result "${_RESULT}" "Status")
        # Anything that is not in-flight (or not yet visible) is terminal
        if [[ "${_STATUS}" != "InProgress" && "${_STATUS}" != "Pending" && -n "${_STATUS}" ]]; then
            break
        fi
        echo "  (${_I}/${_POLL_MAX}) ${_STATUS:-Pending} — waiting ${_POLL_INTERVAL}s..." >&2
        sleep "${_POLL_INTERVAL}"
    done
    # OUTPUT VALUES
    printf '%s\n' "${_RESULT}"
}

# Print the remote command's output and verdict. Returns 0 only on Success, so
# a poll that ran out of attempts (still InProgress) reports as a failure.
function ssm_report_result() {
    # VARIABLES
    local _RESULT
    local _STATUS _STDOUT _STDERR
    # INPUTS
    _RESULT="${1}"
    # PROCESS
    _STATUS=$(parse_command_invocation_result "${_RESULT}" "Status")
    _STDOUT=$(parse_command_invocation_result "${_RESULT}" "StandardOutputContent")
    _STDERR=$(parse_command_invocation_result "${_RESULT}" "StandardErrorContent")
    if [[ -n "${_STDOUT}" ]]; then
        echo "--- stdout ---"
        echo "${_STDOUT}"
    fi
    if [[ -n "${_STDERR}" ]]; then
        echo "--- stderr ---"
        echo "${_STDERR}"
    fi
    echo ""
    echo "Result: ${_STATUS}"
    # OUTPUT VALUES
    [[ "${_STATUS}" == "Success" ]]
}
