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

# The host owns this file's lifecycle: truncated before the run, read after. A
# report therefore always describes exactly one invocation, and a step that never
# ran leaves no record — which is what lets the summary say "not attempted"
# rather than silently showing nothing.
SIMPLEK3S_PULL_REPORT="/opt/simplek3s/.simplek3s-pull-report.jsonl"

POLL_INTERVAL=5
POLL_MAX=180  # 15 minutes

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
    echo "Usage: $(basename "$0") <profile> [<nickname> <region>]"
    echo ""
    echo "  profile   AWS CLI profile (required)"
    echo "  nickname  Cluster nickname (default: inferred from terraform.tfvars)"
    echo "  region    AWS region      (default: inferred from terraform.tfvars)"
    echo "  --verbose Print the node's full log after the summary"
    echo "  --dry-run Report what would change and exit; writes nothing"
    echo ""
    echo "Targets ONE running controlplane node, chosen automatically. Node"
    echo "selection and fan-out to every node are not yet supported — see"
    echo "issue #118 phase 4. 'sk3s status' reports which nodes are behind."
}

# Render the node's JSON-lines report as the operator summary. Given on stdin;
# node id and name on argv. Prints nothing and exits 1 if there is no report,
# so the caller can fall back to the raw log.
function render_pull_report() {
    python3 -c '
import json, sys

node_id, node_name = sys.argv[1], sys.argv[2]
verbose, dry = sys.argv[3] == "true", sys.argv[4] == "true"

# Labels change wording in a preview so the two modes can never be mistaken for
# each other in a scrollback.
L_SYNC   = "Would sync"  if dry else "Synced"
L_STAGE  = "Would stage" if dry else "Staged"
L_ACTION = "Would run"   if dry else "Actions"

records = []
for line in sys.stdin.read().splitlines():
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        records.append(json.loads(line))
    except ValueError:
        continue
if not records:
    raise SystemExit(1)

by_step = {}
actions = []
for r in records:
    if r.get("step") == "action":
        actions.append(r)
    else:
        by_step[r.get("step")] = r

def line(label, value):
    print("%-11s: %s" % (label, value))

gen = by_step.get("generation")
if gen:
    before, after = gen.get("before", "unknown"), gen.get("after", "unknown")
    suffix = " (would advance)" if dry and before != after else ("" if before != after else " (unchanged)")
    line("Generation", (after if before == after else "%s -> %s" % (before, after)) + suffix)
else:
    line("Generation", "not reported")

sync = by_step.get("sync")
if sync is None:
    line(L_SYNC, "not attempted")
elif sync.get("result") != "ok":
    line(L_SYNC, "FAILED — " + sync.get("detail", "no detail"))
elif sync.get("changed", 0) == 0:
    line(L_SYNC, "no changes")
else:
    line(L_SYNC, "%d file(s)" % sync["changed"] if dry else "%d file(s) changed" % sync["changed"])
    for f in sync.get("files", []):
        print("               " + f)

stage = by_step.get("stage")
if stage is None:
    line(L_STAGE, "not attempted")
elif stage.get("result") != "ok":
    line(L_STAGE, "FAILED after %d of %d" % (stage.get("changed", 0), stage.get("total", 0)))
else:
    line(L_STAGE, "%d of %d manifests%s" % (stage.get("changed", 0), stage.get("total", 0), "" if dry else " changed"))
    for f in stage.get("files", []):
        print("               " + f)

if not actions:
    line(L_ACTION, "not attempted")
else:
    performed = [a for a in actions if a.get("performed")]
    shown = actions if (verbose or dry) else performed
    if not shown:
        line(L_ACTION, "none needed")
    else:
        first = True
        for a in shown:
            name = a.get("name", "?").replace("_", " ")
            if dry:
                # performed/skipped is meaningless in a preview — nothing ran.
                text = "%s — %s" % (name, a.get("detail", ""))
            else:
                what = "performed" if a.get("performed") else "skipped"
                text = "%-22s %-9s (%s)" % (a.get("name", "?"), what, a.get("detail", ""))
            line(L_ACTION, text) if first else print("             " + text)
            first = False

if dry:
    # Only suggest re-running when a re-run would do something. Telling an
    # operator to drop --dry-run when the answer is "no changes" invites a
    # pointless mutating command.
    changed = 0
    for step in (sync, stage):
        if step and step.get("result") == "ok":
            changed += step.get("changed", 0)
    failed = any(st and st.get("result") not in (None, "ok") for st in (sync, stage))
    print("")
    if failed:
        print("Nothing was changed. Resolve the failure above before applying.")
    elif changed:
        print("Nothing was changed. Re-run without --dry-run to apply.")
    else:
        print("Nothing to do — this node is already at the current generation.")
' "$1" "$2" "$3" "$4"
}

function update_services() {
    # VARIABLES
    local _REMOTE_COMMAND
    local _INSTANCE_ID _INSTANCE_NAME _COMMAND_ID _RESULT
    local _STDOUT _STDERR _STATUS _RC

    _INSTANCE_ID=$(get_controlplane_instance_id "${REGION}" "${PROFILE}" "${NICKNAME}")

    local _DRY="false"
    (( DRY_RUN == 1 )) && _DRY="true"

    if (( DRY_RUN == 1 )); then
        echo "Pull (dry run): nothing will be changed"
    else
        echo "Pull: sync bootstrap files from S3, then re-stage manifests"
    fi
    echo ""
    echo "Cluster    : ${NICKNAME}  ${REGION}"
    echo "Instance   : ${_INSTANCE_ID}"
    echo ""

    # One `bash -c` rather than two chained commands, because the report has to
    # outlive a failure: `&&` would skip the read entirely if the sync failed,
    # losing the record that says WHY. Prose goes to stderr so stdout carries
    # only the report — the same split node_verify-all.sh --json uses, and for
    # the same reason (SSM truncates stdout mid-stream at 24000 chars).
    _REMOTE_COMMAND="sudo bash -c 'export PULL_REPORT=${SIMPLEK3S_PULL_REPORT} PULL_DRY_RUN=${_DRY}"
    _REMOTE_COMMAND+="; : > \$PULL_REPORT"
    _REMOTE_COMMAND+="; { bash ${SIMPLEK3S_REFRESH} && bash ${SIMPLEK3S_UPDATE}; } 1>&2"
    _REMOTE_COMMAND+="; _RC=\$?"
    _REMOTE_COMMAND+="; cat \$PULL_REPORT 2>/dev/null"
    _REMOTE_COMMAND+="; exit \$_RC'"

    _COMMAND_ID=$(ssm_send_command "${REGION}" "${PROFILE}" "${_INSTANCE_ID}" "${_REMOTE_COMMAND}")
    _RESULT=$(ssm_await_completion "${REGION}" "${PROFILE}" "${_INSTANCE_ID}" "${_COMMAND_ID}" \
        "${POLL_MAX}" "${POLL_INTERVAL}")

    _STATUS=$(parse_command_invocation_result "${_RESULT}" "Status")
    _STDOUT=$(parse_command_invocation_result "${_RESULT}" "StandardOutputContent")
    _STDERR=$(parse_command_invocation_result "${_RESULT}" "StandardErrorContent")

    if ! printf '%s' "${_STDOUT}" | render_pull_report "${_INSTANCE_ID}" "${NICKNAME}" "${VERBOSE}" "${_DRY}"; then
        # No report at all: a node predating this change, or a failure before the
        # first step could record anything. The raw log is all there is.
        echo "Pull report not available — showing the raw node output." >&2
        printf '%s\n' "${_STDERR}"
        [[ "${_STATUS}" == "Success" ]] && return 0
        return 1
    fi

    echo ""
    if (( VERBOSE == 1 )); then
        echo "--- node log ---"
        printf '%s\n' "${_STDERR}"
        echo ""
    fi

    if [[ "${_STATUS}" != "Success" ]]; then
        echo "Result: FAIL  (${_STATUS})"
        echo "Re-run with --verbose, or read the node log, for the failing step." >&2
        return 1
    fi

    # The dry-run footer is printed by the renderer, which is the only place
    # that knows whether anything would actually change.
    (( DRY_RUN == 1 )) && return 0

    echo "Next: the K3s deploy controller applies staged manifests asynchronously."
    echo "      ./sk3s status"
    return 0
}

# PARSE OPTIONS
# Flags are pulled out of the argument list before the positionals are counted,
# so `<profile> --verbose` is not mistaken for the rejected two-positional form.
# Every argument is scanned, not just $1: `sk3s` supplies the AWS profile as the
# first positional when one is omitted, so a flag the caller typed first ends up
# at $2.
VERBOSE=0
DRY_RUN=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "${1}" in
        --verbose)
            VERBOSE=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h | --help)
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
set -- ${POSITIONAL[@]+"${POSITIONAL[@]}"}

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
