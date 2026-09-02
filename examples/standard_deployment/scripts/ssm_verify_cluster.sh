#!/bin/bash

set -euo pipefail

# Executes node_verify-all.sh on EVERY running controlplane node via SSM.
# Nodes are located by their Nickname tag.
#
# Each node's log is merged into one consolidated report, so a check that every
# node agrees on is printed once instead of N times. Divergent lines are printed
# once per distinct result and attributed to the nodes that produced them.
#
# NO CONSENSUS VOTING, on purpose. Every check in node_verify-all.sh is a
# kubectl call, so the nodes are not independent observers — they are repeated
# samples of one cluster taken at different moments. Majority voting on that
# measures sampling jitter, and worse, it would report PASS while a genuinely
# wedged node sat in the minority. So: any node failing fails the run.
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

C_RED="" ; C_GRN="" ; C_YLW="" ; C_CYN="" ; C_RST=""

# Colour is on for terminals and off everywhere else, so a redirect or a pipe
# into another script stays free of escape codes without anyone asking.
# --no-color forces it off even on a terminal.
# tput is tolerated failing (unset TERM) rather than aborting under `set -e`.
function setup_colors() {
    if (( NO_COLOR == 1 )) || [[ ! -t 1 ]]; then
        return 0
    fi
    C_RED="$(tput setaf 1 2>/dev/null || true)"
    C_GRN="$(tput setaf 2 2>/dev/null || true)"
    C_YLW="$(tput setaf 3 2>/dev/null || true)"
    C_CYN="$(tput setaf 6 2>/dev/null || true)"
    C_RST="$(tput sgr0   2>/dev/null || true)"
}

# Tint a node's log so the failing check is findable at a glance instead of by
# reading every line, and so the section headers break up the wall of text.
#   [FAIL] -> red     [WARN] -> yellow
#   "[INFO] ... --- Section ---" -> cyan
# Keys off the tags lib/common.sh's log_* helpers emit. Matching on the [INFO]
# tag AND the --- delimiters keeps the header rule off the other [INFO] lines
# (LAUNCHED, stability window), which carry no dashes.
#
# Globs rather than the equivalent regex: the patterns are quoted, so bash reads
# "[FAIL]" as literal text — unquoted it is a character class matching any one
# of F, A, I, L. Order matters; the first matching branch wins, so a failing
# line stays red even if it contains dashes.
# A no-op when colour is off.
function highlight_log() {
    # VARIABLES
    local _LINE
    # PROCESS
    if [[ -z "${C_RED}" ]]; then
        cat
        return 0
    fi
    while IFS= read -r _LINE; do
        case "${_LINE}" in
            *"[FAIL]"*)          printf '%s%s%s\n' "${C_RED}" "${_LINE}" "${C_RST}" ;;
            *"[WARN]"*)          printf '%s%s%s\n' "${C_YLW}" "${_LINE}" "${C_RST}" ;;
            *"[INFO]"*"---"*)    printf '%s%s%s\n' "${C_CYN}" "${_LINE}" "${C_RST}" ;;
            *)                   printf '%s\n' "${_LINE}" ;;
        esac
    done
}

# Per-node state. macOS ships bash 3.2, which has no associative arrays, so
# these are parallel indexed arrays keyed by the same node index.
NODE_IDS=()
NODE_NAMES=()
NODE_STATUS=()   # raw SSM invocation status ("" until terminal)
NODE_RESULT=()   # raw invocation JSON

function usage() {
    echo "Usage: $(basename "$0") <profile> [<nickname> <region>] [--no-color] [--per-node]" >&2
    echo "" >&2
    echo "  profile     AWS CLI profile (required)" >&2
    echo "  nickname    Cluster nickname (default: inferred from terraform.tfvars)" >&2
    echo "  region      AWS region      (default: inferred from terraform.tfvars)" >&2
    echo "  --no-color  Never emit colour (already off when stdout is not a terminal)" >&2
    echo "  --per-node  Print each node's own results instead of one merged report" >&2
    echo "" >&2
    echo "Exit: 0 only when every controlplane node passes; 1 otherwise" >&2
    echo "      (a node that cannot be reached is not a pass)." >&2
    exit 2
}


# One send-command for all nodes: a single CommandId dispatched at one instant,
# rather than N sends that drift apart. Returns the CommandId.
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

# Poll every node's invocation until all are terminal or attempts run out.
# Nodes still non-terminal at the end keep an empty status and are reported
# UNKNOWN — never silently dropped, which would shrink the denominator.
function await_all_invocations() {
    # VARIABLES
    local _REGION _PROFILE _COMMAND_ID _POLL_MAX _POLL_INTERVAL
    local _I _IDX _PENDING _RESULT _STATUS
    # INPUTS
    _REGION="${1}"
    _PROFILE="${2}"
    _COMMAND_ID="${3}"
    _POLL_MAX="${4}"
    _POLL_INTERVAL="${5}"
    # PROCESS
    echo "Command ID: ${_COMMAND_ID}" >&2
    echo "Polling for output (up to $((_POLL_MAX * _POLL_INTERVAL / 60)) min)..." >&2
    echo "" >&2
    for ((_I=1; _I<=_POLL_MAX; _I++)); do
        _PENDING=0
        for ((_IDX=0; _IDX<${#NODE_IDS[@]}; _IDX++)); do
            # Already terminal — leave it alone.
            if [[ -n "${NODE_STATUS[$_IDX]}" ]]; then
                continue
            fi
            _RESULT=$(ssm_get_command_invocation "${_REGION}" "${_PROFILE}" \
                "${NODE_IDS[$_IDX]}" "${_COMMAND_ID}")
            _STATUS=$(parse_command_invocation_result "${_RESULT}" "Status")
            if [[ -n "${_STATUS}" && "${_STATUS}" != "InProgress" && "${_STATUS}" != "Pending" ]]; then
                NODE_STATUS[_IDX]="${_STATUS}"
                NODE_RESULT[_IDX]="${_RESULT}"
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

# Render a node's --json document as one line per check, so the merge below
# compares structured results rather than prose. Empty output means the node did
# not return a document this script understands — the caller then falls back to
# the prose path.
function render_check_lines() {
    printf '%s' "${1}" | python3 -c '
import json, sys

try:
    doc = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
# Refuse a shape we do not know rather than half-reading a future one.
if not isinstance(doc, dict) or doc.get("schema") != 1:
    sys.exit(0)

for check in doc.get("checks", []):
    print("[%s] %-18s %s" % (check["result"].upper()[:4], check["section"], check["message"]))
    for line in (check.get("detail") or "").splitlines():
        print("       | " + line)
' 2>/dev/null
}

# How many checks failed on a node. Preferred source is the JSON summary; the
# grep is retained for a node still running a pre---json script.
function count_failed_checks() {
    # VARIABLES
    local _STDOUT
    local _MATCH
    local _JSON_COUNT
    # INPUTS
    _STDOUT="${1}"
    # PROCESS
    # Declared before assignment: `local X="$(...)"` masks the substitution's
    # exit status behind local's own, which is always 0.
    _JSON_COUNT="$(printf '%s' "${_STDOUT}" | python3 -c '
import json, sys

doc = json.load(sys.stdin)
if not isinstance(doc, dict) or doc.get("schema") != 1:
    raise SystemExit(1)
print(doc["summary"]["failed"])
' 2>/dev/null)" || _JSON_COUNT=""
    if [[ -n "${_JSON_COUNT}" ]]; then
        printf '%s' "${_JSON_COUNT}"
        return 0
    fi
    _MATCH=$(printf '%s' "${_STDOUT}" | grep -oE 'FAILED \([0-9]+ check' | tail -1 || true)
    if [[ -n "${_MATCH}" ]]; then
        printf '%s' "${_MATCH}" | grep -oE '[0-9]+'
        return 0
    fi
    # Fallback: count the individual FAIL lines.
    printf '%s' "${_STDOUT}" | grep -cE 'FAIL:' || true
}

# Merge every node's log into one report, printing each check once.
#
# The nodes run the same checks against the same cluster, so their logs are
# near-identical and printing all N is mostly duplication. Lines are compared
# with the leading timestamp stripped — that is the only field that differs on
# an otherwise identical line.
#
# Consolidation is PRESENTATION ONLY. It does not vote: a check that disagreed
# across nodes is shown once per distinct result with the nodes attributed, and
# the run's verdict still comes from the per-node exit statuses. A disagreement
# is a finding to look at, not a tie to resolve.
function consolidated_report() {
    # VARIABLES
    local _TMPDIR _IDX _STDOUT _LINES
    local _LABELS
    # PROCESS
    _TMPDIR="$(mktemp -d)"
    _LABELS=()
    for ((_IDX=0; _IDX<${#NODE_IDS[@]}; _IDX++)); do
        # Unreachable nodes produce no log; they are excluded from the
        # comparison and already counted in the per-node verdict above.
        if [[ "${NODE_STATUS[$_IDX]}" != "Success" && "${NODE_STATUS[$_IDX]}" != "Failed" ]]; then
            continue
        fi
        _STDOUT=$(parse_command_invocation_result "${NODE_RESULT[$_IDX]}" "StandardOutputContent")
        # Structured lines when the node returned a document; its raw prose
        # otherwise, so a node predating --json still merges.
        _LINES="$(render_check_lines "${_STDOUT}")"
        if [[ -z "${_LINES}" ]]; then
            _LINES="${_STDOUT}"
        fi
        printf '%s\n' "${_LINES}" > "${_TMPDIR}/${#_LABELS[@]}.log"
        _LABELS[${#_LABELS[@]}]="${NODE_IDS[$_IDX]}"
    done

    if (( ${#_LABELS[@]} == 0 )); then
        echo "=== consolidated report ==="
        echo "  (no node returned a log)"
        echo ""
        rm -rf "${_TMPDIR}"
        return 0
    fi

    # Program on stdin, node labels on argv, colours through the environment so
    # --no-color propagates without string-building escape codes here.
    C_RED="${C_RED}" C_YLW="${C_YLW}" C_CYN="${C_CYN}" C_RST="${C_RST}" \
        python3 - "${_TMPDIR}" "${_LABELS[@]}" <<'PYEOF'
import os
import re
import sys

tmpdir = sys.argv[1]
labels = sys.argv[2:]

RED = os.environ.get("C_RED", "")
YLW = os.environ.get("C_YLW", "")
CYN = os.environ.get("C_CYN", "")
RST = os.environ.get("C_RST", "")

# The timestamp is the one field that differs between nodes on an otherwise
# identical line, so it is stripped before comparing.
TIMESTAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T[\d:.]+\s+")

nodes = []
for i, label in enumerate(labels):
    path = os.path.join(tmpdir, "%d.log" % i)
    try:
        with open(path) as fh:
            lines = [TIMESTAMP.sub("", ln.rstrip("\n")) for ln in fh if ln.strip()]
    except OSError:
        lines = []
    nodes.append((label, lines, set(lines)))

# Union of every line, in the order first encountered, so the report reads in
# the order the checks actually ran.
order = []
seen = set()
for _, lines, _ in nodes:
    for line in lines:
        if line not in seen:
            seen.add(line)
            order.append(line)


def tint(line):
    if "[FAIL]" in line:
        return RED + line + RST
    # Skipped is not a pass: it is called out, never left to read as green.
    if "[SKIP]" in line or "[WARN]" in line:
        return YLW + line + RST
    if "[INFO]" in line and "---" in line:
        return CYN + line + RST
    return line


total = len(nodes)
diverged = 0
out = []
for line in order:
    owners = [label for label, _, lineset in nodes if line in lineset]
    if len(owners) == total:
        out.append("  " + tint(line))
    else:
        diverged += 1
        out.append(
            "  %s  %s[%d/%d nodes: %s]%s"
            % (tint(line), YLW, len(owners), total, ", ".join(owners), RST)
        )

header = "=== consolidated report — %d node(s)" % total
if diverged:
    header += ", %s%d line(s) differ%s ===" % (YLW, diverged, RST)
else:
    header += ", all agree ==="
print(header)
print("\n".join(out))
if diverged:
    print("")
    print(
        "  %sNote: differing lines are attributed above. The nodes are sampled at"
        % YLW
    )
    print("  slightly different moments, so a difference is not automatically a")
    print("  fault — but it is worth looking at.%s" % RST)
PYEOF

    echo ""
    rm -rf "${_TMPDIR}"
}

function verify_cluster_fanout() {
    # VARIABLES
    local _ENV_VARS _REMOTE_COMMAND _COMMAND_ID
    local _LINE _ID _NAME _IDX
    local _STATUS _STDOUT _STDERR _VERDICT _DETAIL _FAILED _LINES
    local _J _MATCHED
    local _ERR_TEXTS _ERR_NODES
    local _PASSED _FAILEDN _UNKNOWN _TOTAL _EXIT _SUMMARY

    echo "Cluster  : nickname=${NICKNAME}  region=${REGION}  profile=${PROFILE}"

    # Build Environment Variables (STABILITY_WINDOW_SECONDS)
    # How far back node_verify-all.sh looks for pod restarts (Default: 300)
    _ENV_VARS=""
    if [[ -n "${STABILITY_WINDOW}" ]]; then
        _ENV_VARS="STABILITY_WINDOW_SECONDS=${STABILITY_WINDOW}"
    fi
    # --json: the node reports structured results on stdout and sends its prose
    # to stderr, so this script reads fields instead of grepping log lines. A
    # node that predates --json still returns prose, and every consumer below
    # falls back to the old parsing when the document is absent or unreadable.
    _REMOTE_COMMAND="$(build_remote_command "${SIMPLEK3S_VERIFY} --json" "${_ENV_VARS}")"

    # Find EVERY running controlplane instance for this cluster
    while IFS=$'\t' read -r _ID _NAME; do
        [[ -z "${_ID}" ]] && continue
        NODE_IDS[${#NODE_IDS[@]}]="${_ID}"
        NODE_NAMES[${#NODE_NAMES[@]}]="${_NAME:-"(unnamed)"}"
        NODE_STATUS[${#NODE_STATUS[@]}]=""
        NODE_RESULT[${#NODE_RESULT[@]}]=""
    done < <(get_controlplane_instances "${REGION}" "${PROFILE}" "${NICKNAME}")

    _TOTAL=${#NODE_IDS[@]}
    echo "Script   : ${SIMPLEK3S_VERIFY} --json"
    echo "Env Vars : ${_ENV_VARS:-"--N/A--"}"
    echo "Nodes    : ${_TOTAL} controlplane"
    for ((_IDX=0; _IDX<_TOTAL; _IDX++)); do
        echo "           ${NODE_IDS[$_IDX]}  ${NODE_NAMES[$_IDX]}"
    done
    echo ""

    # Nothing to verify: stop here rather than falling through. Two independent
    # reasons this has to be an explicit failure —
    #   1. "${NODE_IDS[@]}" on an empty array trips `set -u` on bash 3.2 (macOS),
    #      so the dispatch below dies with "NODE_IDS[@]: unbound variable".
    #   2. Worse, if it did not: the verdict logic counts 0 failures and 0 unknowns,
    #      falls into the all-clear branch, and reports PASS (0/0) with exit 0. A
    #      cluster that does not exist would come back green.
    # Consistent with the rest of the script's pessimism: absence is never a pass.
    if (( _TOTAL == 0 )); then
        echo "Result: ${C_RED}FAIL${C_RST}  ${C_RED}(no running controlplane instances found)${C_RST}"
        echo "No running controlplane instances matched nickname='${NICKNAME}' in region='${REGION}' (profile='${PROFILE}')." >&2
        echo "Check that the cluster is deployed and that the nickname/region/profile are correct." >&2
        return 1
    fi

    # One dispatch to all nodes, then poll each invocation
    _COMMAND_ID=$(ssm_send_command_multi "${REGION}" "${PROFILE}" "${_REMOTE_COMMAND}" "${NODE_IDS[@]}")
    await_all_invocations "${REGION}" "${PROFILE}" "${_COMMAND_ID}" "${POLL_MAX}" "${POLL_INTERVAL}"

    # Per-node verdicts
    _PASSED=0 ; _FAILEDN=0 ; _UNKNOWN=0
    echo "--- per-node verdict ---"
    for ((_IDX=0; _IDX<_TOTAL; _IDX++)); do
        _STATUS="${NODE_STATUS[$_IDX]}"
        _STDOUT=$(parse_command_invocation_result "${NODE_RESULT[$_IDX]}" "StandardOutputContent")
        _DETAIL=""
        if [[ "${_STATUS}" == "Success" ]]; then
            _VERDICT="${C_GRN}PASS${C_RST}"
            _PASSED=$((_PASSED + 1))
        elif [[ "${_STATUS}" == "Failed" ]]; then
            _FAILED=$(count_failed_checks "${_STDOUT}")
            _VERDICT="${C_RED}FAIL${C_RST}"
            _DETAIL="  (${_FAILED:-?} check(s) failed)"
            _FAILEDN=$((_FAILEDN + 1))
        else
            # TimedOut / Cancelled / Undeliverable / still InProgress / no reply
            _VERDICT="${C_YLW}UNKNOWN${C_RST}"
            _DETAIL="  (${_STATUS:-no response})"
            _UNKNOWN=$((_UNKNOWN + 1))
        fi
        printf '  %-20s %-40s %s%s\n' "${NODE_IDS[$_IDX]}" "${NODE_NAMES[$_IDX]}" "${_VERDICT}" "${_DETAIL}"
    done
    echo ""

    if (( PER_NODE == 1 )); then
        # Each node's own results, unmerged — for when a specific node's view is
        # what you need rather than the consensus.
        for ((_IDX=0; _IDX<_TOTAL; _IDX++)); do
            echo "=== ${NODE_IDS[$_IDX]} (${NODE_NAMES[$_IDX]}) — ${NODE_STATUS[$_IDX]:-no response} ==="
            _STDOUT=$(parse_command_invocation_result "${NODE_RESULT[$_IDX]}" "StandardOutputContent")
            _STDERR=$(parse_command_invocation_result "${NODE_RESULT[$_IDX]}" "StandardErrorContent")
            _LINES="$(render_check_lines "${_STDOUT}")"
            if [[ -n "${_LINES}" ]]; then
                echo "--- checks ---"
                printf '%s\n' "${_LINES}" | highlight_log
            elif [[ -n "${_STDOUT}" ]]; then
                echo "--- stdout ---"
                printf '%s\n' "${_STDOUT}" | highlight_log
            fi
            # Only when no document parsed. A node running --json sends its full
            # prose log to stderr, which restates the checks above line for line;
            # printing both would duplicate every result, and SSM caps stderr at
            # 8000 characters, so the duplicate is the copy that gets truncated.
            if [[ -z "${_LINES}" && -n "${_STDERR}" ]]; then
                echo "--- stderr ---"
                printf '%s\n' "${_STDERR}" | highlight_log
            fi
            echo ""
        done
    else
        # One merged report: each check once, divergences attributed.
        consolidated_report
    fi

    # stderr gets the same treatment: SSM appends its own "failed to run
    # commands: exit status 1" to every node that exited non-zero, so printing
    # it per node reproduces exactly the duplication this report removes.
    # Identical text is collapsed into one entry listing the nodes it came from.
    if (( PER_NODE == 0 )); then
        _ERR_TEXTS=() ; _ERR_NODES=()
        for ((_IDX=0; _IDX<_TOTAL; _IDX++)); do
            # In --json mode a node's stderr IS its full prose log, so dumping it
            # per node would reproduce exactly the duplication this report exists
            # to remove. Only nodes that returned no readable document fall
            # through here, where their stderr is the diagnostic.
            _STDOUT=$(parse_command_invocation_result "${NODE_RESULT[$_IDX]}" "StandardOutputContent")
            if [[ -n "$(render_check_lines "${_STDOUT}")" ]]; then
                continue
            fi
            _STDERR=$(parse_command_invocation_result "${NODE_RESULT[$_IDX]}" "StandardErrorContent")
            [[ -z "${_STDERR}" ]] && continue
            _MATCHED=0
            for ((_J=0; _J<${#_ERR_TEXTS[@]}; _J++)); do
                if [[ "${_ERR_TEXTS[$_J]}" == "${_STDERR}" ]]; then
                    _ERR_NODES[_J]="${_ERR_NODES[$_J]}, ${NODE_IDS[$_IDX]}"
                    _MATCHED=1
                    break
                fi
            done
            if (( _MATCHED == 0 )); then
                _ERR_TEXTS[${#_ERR_TEXTS[@]}]="${_STDERR}"
                _ERR_NODES[${#_ERR_NODES[@]}]="${NODE_IDS[$_IDX]}"
            fi
        done
        for ((_J=0; _J<${#_ERR_TEXTS[@]}; _J++)); do
            echo "--- stderr [${_ERR_NODES[$_J]}] ---"
            printf '%s\n' "${_ERR_TEXTS[$_J]}" | highlight_log
            echo ""
        done
    fi

    for ((_IDX=0; _IDX<_TOTAL; _IDX++)); do
        _STDOUT=$(parse_command_invocation_result "${NODE_RESULT[$_IDX]}" "StandardOutputContent")
        if output_is_truncated "${_STDOUT}" "${SSM_STDOUT_LIMIT}"; then
            echo "WARNING: ${NODE_IDS[$_IDX]} — INCOMPLETE OUTPUT: stdout hit the SSM cap of ${SSM_STDOUT_LIMIT} characters." >&2
        fi
    done

    # Verdict. Pessimistic by design: only an all-clear is a pass.
    if (( _FAILEDN > 0 )); then
        # Report unreachable nodes alongside the failures. Naming only the
        # failures would imply the remainder passed, when some never answered.
        _SUMMARY="${_FAILEDN}/${_TOTAL} nodes failed"
        if (( _UNKNOWN > 0 )); then
            _SUMMARY="${_SUMMARY}, ${_UNKNOWN} unreachable"
        fi
        echo "Result: ${C_RED}FAIL${C_RST}  ${C_RED}(${_SUMMARY})${C_RST}"
        _EXIT=1
    elif (( _UNKNOWN > 0 )); then
        echo "Result: ${C_YLW}INCONCLUSIVE${C_RST}  ${C_YLW}(${_UNKNOWN}/${_TOTAL} nodes unreachable)${C_RST}"
        _EXIT=1
    else
        echo "Result: ${C_GRN}PASS${C_RST}  (${_PASSED}/${_TOTAL} nodes passed)"
        _EXIT=0
    fi
    return "${_EXIT}"
}

# PARSE OPTIONS
# Flags are pulled out first so the positional count below sees only positionals
# — otherwise `<profile> --no-color` would read as the rejected 2-positional form.
NO_COLOR=0
PER_NODE=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "${1}" in
        --no-color)
            NO_COLOR=1
            shift
            ;;
        --per-node)
            PER_NODE=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        --)
            shift
            while [[ $# -gt 0 ]]; do
                POSITIONAL[${#POSITIONAL[@]}]="${1}"
                shift
            done
            ;;
        -*)
            echo "Error: unknown option '${1}'." >&2
            usage
            ;;
        *)
            POSITIONAL[${#POSITIONAL[@]}]="${1}"
            shift
            ;;
    esac
done
# bash 3.2 errors on "${arr[@]}" for an empty array under `set -u`, hence the guard.
set -- ${POSITIONAL[@]+"${POSITIONAL[@]}"}

setup_colors

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
# If the STABILITY_WINDOW exists, then ensure that its a positive integer
if [[ -n "${STABILITY_WINDOW}" && ! "${STABILITY_WINDOW}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: STABILITY_WINDOW_SECONDS must be a positive integer (got '${STABILITY_WINDOW}')." >&2
    exit 2
fi

# EXECUTE SCRIPT
verify_cluster_fanout
