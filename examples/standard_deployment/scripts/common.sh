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

# ─── Output truncation ───────────────────────────────────────────────────────

# GetCommandInvocation caps what it returns and appends a marker at the cut
# point; the rest is simply not retrievable through this API. Limits come from
# the SSM service model (StandardOutputContent / StandardErrorContent max).
SSM_STDOUT_LIMIT=24000
SSM_STDERR_LIMIT=8000
SSM_TRUNCATION_MARKER="--output truncated--"

function output_is_truncated() {
    # VARIABLES
    local _TEXT _LIMIT
    # INPUTS
    _TEXT="${1}"
    _LIMIT="${2}"
    # OUTPUT VALUES
    [[ "${_TEXT}" == *"${SSM_TRUNCATION_MARKER}" ]] || (( ${#_TEXT} >= _LIMIT ))
}

# ─── JSON output ─────────────────────────────────────────────────────────────

# Normalise a get-command-invocation payload into a stable shape, so callers
# parse our keys rather than scraping AWS's.
function invocation_to_json() {
    # VARIABLES
    local _RESULT _INSTANCE_ID _NICKNAME _REGION
    # INPUTS
    _RESULT="${1}"
    _INSTANCE_ID="${2}"
    _NICKNAME="${3}"
    _REGION="${4}"
    # OUTPUT VALUES
    printf '%s' "${_RESULT}" | python3 -c '
import json, sys

MARKER = "--output truncated--"

def cut(text, limit):
    """SSM appends the marker at the cut point; the rest is unrecoverable here."""
    return text.endswith(MARKER) or len(text) >= limit

try:
    raw = json.load(sys.stdin)
except ValueError:
    raw = {}
out = raw.get("StandardOutputContent", "")
err = raw.get("StandardErrorContent", "")
out_cut, err_cut = cut(out, 24000), cut(err, 8000)

# Cluster identity first, then flags, then content. stdout can be 24KB, so a
# reader that only sees the head of this object must still learn which cluster
# was targeted and whether the result is complete.
payload = {
    "nickname": sys.argv[2],
    "region": sys.argv[3],
    "instance_id": sys.argv[1],
    "command_id": raw.get("CommandId", ""),
    "status": raw.get("Status", ""),
    "response_code": raw.get("ResponseCode", -1),
    "stdout_truncated": out_cut,
    "stderr_truncated": err_cut,
}
if out_cut or err_cut:
    which = " and ".join(
        [n for n, c in (("stdout", out_cut), ("stderr", err_cut)) if c])
    # No single quotes anywhere in this block: it lives inside python3 -c '...'
    # and one would close the shell string.
    payload["truncation_note"] = (
        "INCOMPLETE OUTPUT: " + which + " hit the SSM size cap "
        "(stdout 24000 chars, stderr 8000) and was cut mid-stream at the marker "
        "--output truncated-- . The rest cannot be retrieved for this command id. "
        "Do not treat this result as the full output. To see the missing part, run "
        "the command again with the output narrowed on the node, for example by "
        "appending | tail -n 200 or | grep PATTERN or | head -c 20000."
    )
payload["stdout"] = out
payload["stderr"] = err
print(json.dumps(payload))
' "${_INSTANCE_ID}" "${_NICKNAME}" "${_REGION}"
}

# Payload for a command that has been dispatched but not yet collected. Built in
# python so a nickname containing a quote cannot break the JSON.
function dispatch_to_json() {
    # VARIABLES
    local _INSTANCE_ID _NICKNAME _REGION _COMMAND_ID
    # INPUTS
    _INSTANCE_ID="${1}"
    _NICKNAME="${2}"
    _REGION="${3}"
    _COMMAND_ID="${4}"
    # OUTPUT VALUES
    python3 -c '
import json, sys
print(json.dumps({
    "nickname": sys.argv[2],
    "region": sys.argv[3],
    "instance_id": sys.argv[1],
    "command_id": sys.argv[4],
    "status": "Pending",
}))
' "${_INSTANCE_ID}" "${_NICKNAME}" "${_REGION}" "${_COMMAND_ID}"
}

# Render JSON from stdin. Colour is applied only when a terminal is reading, so
# a piped consumer always receives parseable output even in pretty mode.
function format_json() {
    # VARIABLES
    local _MODE _COLOR
    # INPUTS
    _MODE="${1}"
    # PROCESS
    _COLOR="false"
    if [[ -t 1 && "${_MODE}" == "pretty" ]]; then
        _COLOR="true"
    fi
    # OUTPUT VALUES
    python3 -c '
import json, sys

mode, color = sys.argv[1], sys.argv[2] == "true"
data = json.load(sys.stdin)
if mode == "compact":
    print(json.dumps(data, separators=(",", ":")))
    raise SystemExit(0)

P = {"key": "\033[36m", "str": "\033[32m", "num": "\033[33m",
     "lit": "\033[35m", "pun": "\033[2m", "off": "\033[0m"}
if not color:
    P = dict.fromkeys(P, "")

def render(value, depth=0):
    # Concatenation rather than f-strings: this runs under the system python,
    # which may predate 3.12 and cannot nest the same quote inside an f-string.
    pad, inner = "  " * depth, "  " * (depth + 1)
    key, off, pun = P["key"], P["off"], P["pun"]
    if isinstance(value, dict):
        if not value:
            return pun + "{}" + off
        body = (pun + "," + off + "\n").join(
            inner + key + json.dumps(k) + off + pun + ": " + off + render(v, depth + 1)
            for k, v in value.items())
        return pun + "{" + off + "\n" + body + "\n" + pad + pun + "}" + off
    if isinstance(value, list):
        if not value:
            return P["pun"] + "[]" + P["off"]
        body = (P["pun"] + "," + P["off"] + "\n").join(
            inner + render(v, depth + 1) for v in value)
        return P["pun"] + "[" + P["off"] + "\n" + body + "\n" + pad + P["pun"] + "]" + P["off"]
    if isinstance(value, str):
        return P["str"] + json.dumps(value) + P["off"]
    if value is None or isinstance(value, bool):
        return P["lit"] + json.dumps(value) + P["off"]
    return P["num"] + json.dumps(value) + P["off"]

print(render(data))
' "${_MODE}" "${_COLOR}"
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

# Every running controlplane node for a cluster, one "<id>\t<name>" per line.
# The singular form above is enough when any one node will do; this is for
# callers that must reach all of them (e.g. verifying every controlplane).
function get_controlplane_instances() {
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
        --query "Reservations[].Instances[].[InstanceId,Tags[?Key=='Name']|[0].Value]" \
        --output text)
    # VERIFY
    if [[ -z "${_OUTPUT}" || "${_OUTPUT}" == "None" ]]; then
        echo "Error: no running controlplane instance found for nickname '${_NICKNAME}' in ${_REGION}." >&2
        return 1
    fi
    # OUTPUT VALUES
    printf '%s\n' "${_OUTPUT}"
}

# ─── Instance lookup (delegates to ssm_pick_instance.py) ─────────────────────────

COMMON_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PICK_INSTANCE="${COMMON_SCRIPT_DIR}/ssm_pick_instance.py"

# Guard before shelling out, so a missing toolchain says so plainly.
function require_pick_instance() {
    if [[ ! -f "${PICK_INSTANCE}" ]]; then
        echo "Error: ${PICK_INSTANCE} is missing." >&2
        return 1
    fi
    if ! command -v uv > /dev/null 2>&1; then
        echo "Error: uv is required to run ${PICK_INSTANCE}." >&2
        echo "       Install it with ./toolchain/tc_standard_macos_install.sh" >&2
        return 1
    fi
}

# With no extra arguments this runs the interactive picker and prints the chosen
# instance id; --list prints every instance as TSV instead.
function pick_instance() {
    # VARIABLES
    local _REGION _PROFILE _NICKNAME
    # INPUTS
    _REGION="${1}"
    _PROFILE="${2}"
    _NICKNAME="${3}"
    shift 3
    # OUTPUT VALUES
    uv run --script "${PICK_INSTANCE}" \
        --region "${_REGION}" \
        --profile "${_PROFILE}" \
        --nickname "${_NICKNAME}" \
        "$@"
}

# Confirm an instance belongs to this cluster, so a typo fails here rather than
# as an opaque SSM error. _REQUIRE_RUNNING additionally rejects a node SSM
# cannot dispatch to; retrieval of an earlier result does not need it.
function verify_instance_id() {
    # VARIABLES
    local _INSTANCE_ID _REGION _PROFILE _NICKNAME _REQUIRE_RUNNING
    local _INSTANCES _ID _NAME _STATE _FOUND_STATE
    # INPUTS
    _INSTANCE_ID="${1}"
    _REGION="${2}"
    _PROFILE="${3}"
    _NICKNAME="${4}"
    _REQUIRE_RUNNING="${5:-true}"
    # PROCESS
    # Fetched once so the error listing cannot disagree with the lookup
    _INSTANCES="$(pick_instance "${_REGION}" "${_PROFILE}" "${_NICKNAME}" --list)"
    _FOUND_STATE=""
    while IFS=$'\t' read -r _ID _NAME _STATE _; do
        if [[ "${_ID}" == "${_INSTANCE_ID}" ]]; then
            _FOUND_STATE="${_STATE}"
            break
        fi
    done <<< "${_INSTANCES}"
    # VERIFY
    if [[ -z "${_FOUND_STATE}" ]]; then
        echo "Error: ${_INSTANCE_ID} is not an instance of cluster '${_NICKNAME}' in ${_REGION}." >&2
        if [[ -n "${_INSTANCES}" ]]; then
            echo "       Available:" >&2
            while IFS=$'\t' read -r _ID _NAME _STATE _; do
                [[ -z "${_ID}" ]] && continue
                echo "         ${_ID}  ${_NAME}  (${_STATE})" >&2
            done <<< "${_INSTANCES}"
        fi
        return 1
    fi
    if [[ "${_REQUIRE_RUNNING}" == "true" && "${_FOUND_STATE}" != "running" ]]; then
        echo "Error: instance ${_INSTANCE_ID} is ${_FOUND_STATE}, not running." >&2
        return 1
    fi
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

# Emit {"commands": ["<command>"]} with correct JSON escaping.
# Interpolating into the `commands=[...]` shorthand breaks the moment a command
# contains a quote or backslash, which arbitrary commands routinely do:
#   kubectl get pods -o jsonpath="{.items[*].metadata.name}"
function build_command_parameters() {
    printf '%s' "${1}" | python3 -c \
        'import json, sys; print(json.dumps({"commands": [sys.stdin.read()]}))'
}

# Dispatch a remote command and return its CommandId.
function ssm_send_command() {
    # VARIABLES
    local _REGION _PROFILE _INSTANCE_ID _COMMAND
    local _PARAMETERS _OUTPUT
    # INPUTS
    _REGION="${1}"
    _PROFILE="${2}"
    _INSTANCE_ID="${3}"
    _COMMAND="${4}"
    # PROCESS
    _PARAMETERS="$(build_command_parameters "${_COMMAND}")"
    _OUTPUT=$(aws ssm send-command \
        --region "${_REGION}" \
        --profile "${_PROFILE}" \
        --instance-ids "${_INSTANCE_ID}" \
        --document-name "AWS-RunShellScript" \
        --parameters "${_PARAMETERS}" \
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
    # Warn on stderr: a truncated result still reports Success, so without this
    # a partial listing reads as the whole thing.
    if output_is_truncated "${_STDOUT}" "${SSM_STDOUT_LIMIT}"; then
        echo "WARNING: INCOMPLETE OUTPUT — stdout hit the SSM cap of ${SSM_STDOUT_LIMIT} characters" >&2
        echo "         and was cut at the '${SSM_TRUNCATION_MARKER}' marker. The rest is not" >&2
        echo "         retrievable. Re-run with the output narrowed on the node, e.g." >&2
        echo "         append '| tail -n 200' or '| grep <pattern>' to the command." >&2
    fi
    if output_is_truncated "${_STDERR}" "${SSM_STDERR_LIMIT}"; then
        echo "WARNING: INCOMPLETE OUTPUT — stderr hit the SSM cap of ${SSM_STDERR_LIMIT} characters." >&2
    fi
    echo ""
    echo "Result: ${_STATUS}"
    # OUTPUT VALUES
    [[ "${_STATUS}" == "Success" ]]
}

# ─── Node selection ──────────────────────────────────────────────────────────

# Every running instance for a cluster, one "<id>\t<name>\t<role>" per line,
# sorted by instance id. Scope is "controlplane" (default) or "all".
#
# SORTED, because selection has to be REPRODUCIBLE. The EC2 API returns
# instances in no guaranteed order, and taking "the first" from an unsorted list
# is how the same command came to act on different nodes on different days
# (#144). Instance ids are effectively random with respect to a node's position
# in the fleet, so ordering by id is impartial — it privileges no node, and in
# particular does not re-enshrine node 0 — while still giving the same answer on
# every run. Impartiality and determinism are not in tension here.
#
# Role comes from the Name tag, by the same rule ssm_pick_instance.py applies,
# so the two tools can never disagree about what a node is. Karpenter nodes also
# carry simplek3s.io/lifecycle=karpenter, which would be a sturdier signal, but
# the static planes have no equivalent tag — the name is the only rule that
# classifies every node type uniformly.
function get_cluster_instances() {
    # VARIABLES
    local _REGION _PROFILE _NICKNAME _SCOPE
    local _RAW _OUTPUT
    # INPUTS
    _REGION="${1}"
    _PROFILE="${2}"
    _NICKNAME="${3}"
    _SCOPE="${4:-controlplane}"
    # PROCESS
    _RAW="$(aws ec2 describe-instances \
        --region "${_REGION}" \
        --profile "${_PROFILE}" \
        --filters \
            "Name=tag:Nickname,Values=${_NICKNAME}" \
            "Name=instance-state-name,Values=running" \
        --query "Reservations[].Instances[].[InstanceId,Tags[?Key=='Name']|[0].Value]" \
        --output text)" || return 1

    _OUTPUT="$(printf '%s\n' "${_RAW}" | awk -v scope="${_SCOPE}" '
        NF < 2 { next }
        {
            lname = tolower($2)
            if (index(lname, "controlplane") || index(lname, "control-plane")) role = "control-plane"
            else if (index(lname, "agentplane") || index(lname, "agent-plane")) role = "agent"
            else if (index(lname, "karpenter")) role = "karpenter"
            else role = "node"
            if (scope == "controlplane" && role != "control-plane") next
            printf "%s\t%s\t%s\n", $1, $2, role
        }' | sort)"

    # VERIFY
    if [[ -z "${_OUTPUT}" ]]; then
        echo "Error: no running ${_SCOPE} instance found for nickname '${_NICKNAME}' in ${_REGION}." >&2
        return 1
    fi
    # OUTPUT VALUES
    printf '%s\n' "${_OUTPUT}"
}

# ─── Reachability preflight ──────────────────────────────────────────────────

# PingStatus for every instance SSM currently knows about, "<id>\t<status>".
function ssm_ping_status() {
    # VARIABLES
    local _REGION _PROFILE
    # INPUTS
    _REGION="${1}"
    _PROFILE="${2}"
    # OUTPUT VALUES
    aws ssm describe-instance-information \
        --region "${_REGION}" \
        --profile "${_PROFILE}" \
        --query "InstanceInformationList[].[InstanceId,PingStatus]" \
        --output text
}

# Which of the given instances SSM cannot dispatch to right now, one
# "<id>\t<status>" per line. Empty output means all are reachable.
#
# Checked BEFORE dispatch so an unreachable node is named up front, rather than
# discovered as a timeout after the run has already half-completed on the
# others. An instance SSM has never heard of reports "unknown" and counts as
# unreachable: absence of a ping record is not evidence of health.
function ssm_unreachable_instances() {
    # VARIABLES
    local _REGION _PROFILE
    local _STATUS _ID _ROW_ID _ROW_STATUS _FOUND
    # INPUTS
    _REGION="${1}"
    _PROFILE="${2}"
    shift 2
    # PROCESS
    _STATUS="$(ssm_ping_status "${_REGION}" "${_PROFILE}")" || return 1
    for _ID in "$@"; do
        _FOUND=""
        while IFS=$'\t' read -r _ROW_ID _ROW_STATUS; do
            if [[ "${_ROW_ID}" == "${_ID}" ]]; then
                _FOUND="${_ROW_STATUS}"
                break
            fi
        done <<< "${_STATUS}"
        if [[ "${_FOUND}" != "Online" ]]; then
            printf '%s\t%s\n' "${_ID}" "${_FOUND:-unknown}"
        fi
    done
}

# ─── Staging ownership ───────────────────────────────────────────────────────

# The node that owns manifest staging, as "<node-name>\t<instance-id>".
#
# Read from the CLUSTER (a ConfigMap in kube-system), never inferred from a
# node's index or position. That keeps the tooling free of any notion that one
# node is special: when ownership moves, this follows it with no code change.
# Any reachable control-plane node can answer, because the record lives in etcd
# rather than on a particular disk.
#
# Non-zero when the record is absent or unreadable. The caller must NOT read
# that as "nobody owns staging" — an unreachable node and a genuinely unclaimed
# cluster are different situations calling for different responses.
function get_staging_owner() {
    # VARIABLES
    local _REGION _PROFILE _VIA_INSTANCE
    local _CMD _CID _RESULT _STATUS _OUT
    # INPUTS
    _REGION="${1}"
    _PROFILE="${2}"
    _VIA_INSTANCE="${3}"
    # PROCESS
    _CMD="sudo kubectl -n kube-system get configmap simplek3s-staging-owner"
    _CMD+=" -o jsonpath='{.data.node}{\"\t\"}{.data.instance_id}' 2>/dev/null"
    _CID="$(ssm_send_command "${_REGION}" "${_PROFILE}" "${_VIA_INSTANCE}" "${_CMD}")" || return 1
    # stderr suppressed: await prints poll progress, which is noise for a lookup.
    _RESULT="$(ssm_await_completion "${_REGION}" "${_PROFILE}" "${_VIA_INSTANCE}" \
        "${_CID}" 30 2 2> /dev/null)" || return 1
    _STATUS="$(parse_command_invocation_result "${_RESULT}" "Status")"
    if [[ "${_STATUS}" != "Success" ]]; then
        return 1
    fi
    _OUT="$(parse_command_invocation_result "${_RESULT}" "StandardOutputContent")"
    if [[ -z "${_OUT}" ]]; then
        return 1
    fi
    # OUTPUT VALUES
    printf '%s' "${_OUT}"
}

# ─── Fan-out ─────────────────────────────────────────────────────────────────

# Dispatch one command to several instances at once; returns the CommandId.
function ssm_send_command_multi() {
    # VARIABLES
    local _REGION _PROFILE _COMMAND
    local _PARAMETERS
    # INPUTS
    _REGION="${1}"
    _PROFILE="${2}"
    _COMMAND="${3}"
    shift 3
    # PROCESS
    _PARAMETERS="$(build_command_parameters "${_COMMAND}")"
    # OUTPUT VALUES
    aws ssm send-command \
        --region "${_REGION}" \
        --profile "${_PROFILE}" \
        --instance-ids "$@" \
        --document-name "AWS-RunShellScript" \
        --parameters "${_PARAMETERS}" \
        --query "Command.CommandId" \
        --output text
}

# Poll every invocation until all are terminal or the attempts run out, writing
# each node's result to <outdir>/<id>.json and its terminal status to
# <outdir>/<id>.status.
#
#   ssm_await_all <region> <profile> <command-id> <max> <interval> <outdir> <id>...
#
# Results go to FILES rather than into arrays the caller declares. The original
# in ssm_verify_cluster.sh mutates three script-level globals by name, which is
# tolerable inside one script and a trap in a shared library — this file's
# contract is that a function reads nothing from the ambient environment. Bash
# namerefs would be the tidy fix, but macOS ships bash 3.2, which has neither
# namerefs nor associative arrays.
#
# A node still non-terminal when the attempts run out gets NO status file, so
# the caller can distinguish "never finished" from "finished badly". Neither is
# silently dropped, which would quietly shrink the denominator.
function ssm_await_all() {
    # VARIABLES
    local _REGION _PROFILE _COMMAND_ID _POLL_MAX _POLL_INTERVAL _OUTDIR
    local _I _ID _PENDING _RESULT _STATUS
    # INPUTS
    _REGION="${1}"
    _PROFILE="${2}"
    _COMMAND_ID="${3}"
    _POLL_MAX="${4}"
    _POLL_INTERVAL="${5}"
    _OUTDIR="${6}"
    shift 6
    # PROCESS
    mkdir -p "${_OUTDIR}" || return 1
    echo "Command ID: ${_COMMAND_ID}" >&2
    echo "Polling $# node(s) (up to $((_POLL_MAX * _POLL_INTERVAL / 60)) min)..." >&2
    for ((_I = 1; _I <= _POLL_MAX; _I++)); do
        _PENDING=0
        for _ID in "$@"; do
            # Already terminal — leave it alone.
            if [[ -f "${_OUTDIR}/${_ID}.status" ]]; then
                continue
            fi
            _RESULT="$(ssm_get_command_invocation "${_REGION}" "${_PROFILE}" \
                "${_ID}" "${_COMMAND_ID}")"
            _STATUS="$(parse_command_invocation_result "${_RESULT}" "Status")"
            if [[ -n "${_STATUS}" && "${_STATUS}" != "InProgress" && "${_STATUS}" != "Pending" ]]; then
                printf '%s' "${_RESULT}" > "${_OUTDIR}/${_ID}.json"
                printf '%s' "${_STATUS}" > "${_OUTDIR}/${_ID}.status"
            else
                _PENDING=$((_PENDING + 1))
            fi
        done
        if (( _PENDING == 0 )); then
            return 0
        fi
        echo "  (${_I}/${_POLL_MAX}) waiting on ${_PENDING} node(s)..." >&2
        sleep "${_POLL_INTERVAL}"
    done
    return 0
}
