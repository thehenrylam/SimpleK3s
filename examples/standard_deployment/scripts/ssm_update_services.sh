#!/bin/bash

set -euo pipefail

# Sync bootstrap files from S3 and/or stage manifests, over SSM.
#
# Three modes, because the two halves have OPPOSITE natural scopes:
#
#   sync   files only   -> every node in scope (per-node disk state)
#   apply  staging only -> the staging owner alone (cluster-wide effect)
#   pull   both         -> sync everywhere, then stage on the owner
#
# Bundling them as one always-both operation is what made "sync files on one
# instance" and "update without re-syncing" inexpressible (#118), and what let a
# routine update stage manifests onto whichever node the EC2 API happened to
# list first (#144).
#
# The staging target is READ FROM THE CLUSTER, never inferred from a node's
# index or position, so no node is special by identity and ownership can move
# without a code change.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/common.sh"

# GLOBAL VARIABLES
IAC_NAME_CLUSTER="standard_cluster"
IAC_TFVARS="$(get_tfvar_filepath "${SCRIPT_DIR}" "${IAC_NAME_CLUSTER}")"

SIMPLEK3S_SCRIPT_DIR="$(get_node_script_dir)"
SIMPLEK3S_REFRESH="${SIMPLEK3S_SCRIPT_DIR}/node_refresh-bootstrap-files.sh"
SIMPLEK3S_UPDATE="${SIMPLEK3S_SCRIPT_DIR}/node_init-services.sh"
SIMPLEK3S_PENDING="${SIMPLEK3S_SCRIPT_DIR}/manifests"
K3S_MANIFEST_DIR="/var/lib/rancher/k3s/server/manifests"

# The host owns this file's lifecycle: truncated before the run, read after. A
# report therefore always describes exactly one invocation, and a step that never
# ran leaves no record — which is what lets the summary say "not attempted"
# rather than silently showing nothing.
SIMPLEK3S_PULL_REPORT="/opt/simplek3s/.simplek3s-pull-report.jsonl"

POLL_INTERVAL=5
POLL_MAX=180  # 15 minutes

EXIT_USAGE=2

WORKDIR=""
function cleanup() {
    [[ -n "${WORKDIR}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    return 0
}
trap cleanup EXIT

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
    echo "Usage: $(basename "$0") <profile> [<nickname> <region>] [options]"
    echo ""
    echo "  profile   AWS CLI profile (required)"
    echo "  nickname  Cluster nickname (default: inferred from terraform.tfvars)"
    echo "  region    AWS region      (default: inferred from terraform.tfvars)"
    echo ""
    echo "Modes:"
    echo "  --mode sync    Sync bootstrap files from S3. Every control-plane node."
    echo "  --mode apply   Stage manifests. The staging owner only. No S3 sync."
    echo "  --mode pull    Both, in that order (default)."
    echo ""
    echo "Options:"
    echo "  --instance-id ID   Act ONLY on this node, for both halves. An escape"
    echo "                     hatch for repair; warns when it is not the owner."
    echo "  --all-nodes        Include agent and Karpenter nodes in the sync."
    echo "                     Staging is unaffected — only servers stage."
    echo "  --strict-sync      Fail the run if ANY node's sync fails. By default"
    echo "                     only the staging owner's failure blocks staging."
    echo "  --claim-ownership  Make the target the sole staging owner, clearing"
    echo "                     manifests staged on other nodes."
    echo "  --dry-run          Report what would change and exit; writes nothing."
    echo "  --verbose          Print each node's full log after the summary."
    echo ""
    echo "The staging owner is read from the simplek3s-staging-owner ConfigMap in"
    echo "kube-system, claimed by whichever node stages at boot. It is never"
    echo "inferred from a node's index."
}

# Resolve which nodes each half acts on, and say so. Sets:
#   SYNC_IDS   space-separated instance ids for the file sync
#   STAGE_ID   instance id that will stage, or empty
#   NODE_NAMES_FILE  tsv of "<id>\t<name>\t<role>"
function resolve_scope() {
    # VARIABLES
    local _SCOPE _INSTANCES _OWNER _OWNER_NODE _OWNER_ID _UNREACHABLE
    local _ID _NAME _ROLE _VIA

    _SCOPE="controlplane"
    if (( ALL_NODES == 1 )); then
        _SCOPE="all"
    fi

    _INSTANCES="$(get_cluster_instances "${REGION}" "${PROFILE}" "${NICKNAME}" "${_SCOPE}")" || return 1
    printf '%s\n' "${_INSTANCES}" > "${NODE_NAMES_FILE}"

    if [[ -n "${INSTANCE_ID}" ]]; then
        # An explicit target restricts BOTH halves. "--instance-id" reads as a
        # restriction, not a redirection: syncing every node while staging on
        # one specific node would be a surprising reading of "only this node".
        verify_instance_id "${INSTANCE_ID}" "${REGION}" "${PROFILE}" "${NICKNAME}" "true" || return 1
        SYNC_IDS="${INSTANCE_ID}"
        STAGE_ID="${INSTANCE_ID}"
    else
        SYNC_IDS="$(printf '%s\n' "${_INSTANCES}" | cut -f1 | tr '\n' ' ')"
        SYNC_IDS="${SYNC_IDS% }"
        STAGE_ID=""
    fi

    # Reachability before dispatch, so an unreachable node is named up front
    # instead of surfacing as a timeout after the run half-completed elsewhere.
    # shellcheck disable=SC2086
    _UNREACHABLE="$(ssm_unreachable_instances "${REGION}" "${PROFILE}" ${SYNC_IDS})" || true
    if [[ -n "${_UNREACHABLE}" ]]; then
        echo "Unreachable nodes (SSM cannot dispatch):" >&2
        printf '%s\n' "${_UNREACHABLE}" | while IFS=$'\t' read -r _ID _ROLE; do
            echo "  ${_ID}  ${_ROLE}" >&2
        done
        UNREACHABLE_COUNT="$(printf '%s\n' "${_UNREACHABLE}" | grep -c . || true)"
    fi

    # Who owns staging is looked up whenever staging is in play — INCLUDING
    # under --instance-id, where the answer is not used to pick the target but
    # is exactly what makes the override warning possible. Only TARGET SELECTION
    # is conditional; the lookup is not.
    if [[ "${MODE}" != "sync" ]]; then
        _VIA="$(printf '%s\n' "${_INSTANCES}" | awk -F'\t' '$3=="control-plane"{print $1; exit}')"
        if [[ -z "${_VIA}" ]]; then
            echo "Error: no running control-plane node to ask about staging ownership." >&2
            return 1
        fi
        if _OWNER="$(get_staging_owner "${REGION}" "${PROFILE}" "${_VIA}")"; then
            OWNER_NODE_NAME="$(printf '%s' "${_OWNER}" | cut -s -f1)"
            OWNER_INSTANCE_ID="$(printf '%s' "${_OWNER}" | cut -s -f2)"
        fi

        if [[ -z "${INSTANCE_ID}" ]]; then
            if [[ -n "${OWNER_INSTANCE_ID}" ]]; then
                STAGE_ID="${OWNER_INSTANCE_ID}"
            elif (( CLAIM_OWNERSHIP == 1 )); then
                # No owner on record and the operator asked to establish one:
                # take the first by instance-id sort. Arbitrary with respect to
                # a node's role, so it privileges nobody — but stable, so
                # --dry-run can name the node before anything is changed.
                STAGE_ID="$(printf '%s\n' "${_INSTANCES}" | awk -F'\t' '$3=="control-plane"{print $1; exit}')"
            else
                echo "Error: no staging owner is recorded for this cluster." >&2
                echo "       An unrecorded owner is not the same as 'any node will do' —" >&2
                echo "       staging on an arbitrary node is what #144 is about." >&2
                echo "       Re-run with --instance-id <id> to choose explicitly, or" >&2
                echo "       --claim-ownership to establish one." >&2
                return 1
            fi
        fi
    fi

    # Report the scope. Every verb states what it acted on and why.
    echo "Cluster    : ${NICKNAME}  ${REGION}"
    case "${MODE}" in
        sync)  echo "Mode       : sync — bootstrap files only, nothing staged" ;;
        apply) echo "Mode       : apply — stage manifests only, no S3 sync" ;;
        pull)  echo "Mode       : pull — sync bootstrap files, then stage" ;;
    esac
    if (( DRY_RUN == 1 )); then
        echo "             (dry run: nothing will be changed)"
    fi

    if [[ "${MODE}" != "apply" ]]; then
        echo -n "Sync       : "
        if [[ -n "${INSTANCE_ID}" ]]; then
            echo "${INSTANCE_ID}  (--instance-id)"
        else
            echo "$(printf '%s\n' "${SYNC_IDS}" | wc -w | tr -d ' ') node(s), scope=${_SCOPE}"
            printf '%s\n' "${_INSTANCES}" | while IFS=$'\t' read -r _ID _NAME _ROLE; do
                echo "               ${_ID}  ${_NAME}  (${_ROLE})"
            done
        fi
    fi

    if [[ "${MODE}" != "sync" ]]; then
        echo -n "Stage      : "
        if [[ -n "${INSTANCE_ID}" ]]; then
            echo "${INSTANCE_ID}  (--instance-id override)"
            if [[ -n "${OWNER_INSTANCE_ID}" && "${INSTANCE_ID}" != "${OWNER_INSTANCE_ID}" ]]; then
                echo "             WARNING: the recorded owner is ${OWNER_NODE_NAME}" >&2
                echo "             (${OWNER_INSTANCE_ID}). This is NOT that node." >&2
                echo "             Staging here leaves a second copy of the manifests" >&2
                echo "             behind, which is the divergence #144 describes." >&2
            fi
        elif [[ -n "${OWNER_NODE_NAME}" ]]; then
            echo "${STAGE_ID}  (${OWNER_NODE_NAME}, recorded staging owner)"
        else
            echo "${STAGE_ID}  (no owner recorded; first by instance-id sort)"
        fi
    fi
    echo ""
}

# One `bash -c` rather than chained commands, because the report has to outlive
# a failure: `&&` would skip the read entirely if the step failed, losing the
# record that says WHY. Prose goes to stderr so stdout carries only the report —
# the same split node_verify-all.sh --json uses, and for the same reason (SSM
# truncates stdout mid-stream at 24000 chars).
function remote_step_command() {
    local _SCRIPTS="${1}" _DRY="${2}"
    local _CMD
    _CMD="sudo bash -c 'export PULL_REPORT=${SIMPLEK3S_PULL_REPORT} PULL_DRY_RUN=${_DRY}"
    _CMD+="; : > \$PULL_REPORT"
    _CMD+="; { ${_SCRIPTS}; } 1>&2"
    _CMD+="; _RC=\$?"
    _CMD+="; cat \$PULL_REPORT 2>/dev/null"
    _CMD+="; exit \$_RC'"
    printf '%s' "${_CMD}"
}

# Split each node's invocation into <id>.report (the JSONL on stdout) and
# <id>.log (the prose on stderr), so the renderer never has to re-parse.
function split_invocations() {
    local _DIR="${1}"
    shift
    local _ID _RESULT
    for _ID in "$@"; do
        if [[ ! -f "${_DIR}/${_ID}.json" ]]; then
            continue
        fi
        _RESULT="$(cat "${_DIR}/${_ID}.json")"
        parse_command_invocation_result "${_RESULT}" "StandardOutputContent" \
            > "${_DIR}/${_ID}.report"
        parse_command_invocation_result "${_RESULT}" "StandardErrorContent" \
            > "${_DIR}/${_ID}.log"
    done
}

# Fan the file sync out to every node in scope.
function run_sync() {
    local _CMD _CID
    _CMD="$(remote_step_command "bash ${SIMPLEK3S_REFRESH}" "${DRY}")"
    # shellcheck disable=SC2086
    _CID="$(ssm_send_command_multi "${REGION}" "${PROFILE}" "${_CMD}" ${SYNC_IDS})" || return 1
    # shellcheck disable=SC2086
    ssm_await_all "${REGION}" "${PROFILE}" "${_CID}" "${POLL_MAX}" "${POLL_INTERVAL}" \
        "${WORKDIR}/sync" ${SYNC_IDS} || return 1
    # shellcheck disable=SC2086
    split_invocations "${WORKDIR}/sync" ${SYNC_IDS}
}

# Stage on the single target node.
function run_stage() {
    local _CMD _CID
    _CMD="$(remote_step_command "bash ${SIMPLEK3S_UPDATE}" "${DRY}")"
    _CID="$(ssm_send_command_multi "${REGION}" "${PROFILE}" "${_CMD}" "${STAGE_ID}")" || return 1
    ssm_await_all "${REGION}" "${PROFILE}" "${_CID}" "${POLL_MAX}" "${POLL_INTERVAL}" \
        "${WORKDIR}/stage" "${STAGE_ID}" || return 1
    split_invocations "${WORKDIR}/stage" "${STAGE_ID}"
}

# Whether a node's step succeeded. A MISSING status file is not success — it
# means the invocation never reached a terminal state.
function step_succeeded() {
    local _DIR="${1}" _ID="${2}"
    if [[ ! -f "${_DIR}/${_ID}.status" ]]; then
        return 1
    fi
    [[ "$(cat "${_DIR}/${_ID}.status")" == "Success" ]]
}

# Make the target the sole staging owner: clear the manifests other nodes are
# holding, then record the claim.
#
# Ordered AFTER staging on purpose. Recording ownership first would leave the
# ConfigMap naming a node that then failed to stage. Clearing is safe: removing
# a manifest file provably does not delete the resources it created (#151), so
# this drops stale copies without touching anything the cluster is running.
function run_claim_ownership() {
    local _CLEAR_CMD _CLAIM_CMD _CID _ID _OTHERS=""

    while IFS=$'\t' read -r _ID _ _; do
        if [[ -n "${_ID}" && "${_ID}" != "${STAGE_ID}" ]]; then
            _OTHERS+="${_ID} "
        fi
    done < <(awk -F'\t' '$3=="control-plane"' "${NODE_NAMES_FILE}")
    _OTHERS="${_OTHERS% }"

    if [[ -n "${_OTHERS}" ]]; then
        echo "Clearing manifests staged on other nodes:"
        _CLEAR_CMD="sudo bash -c 'N=0; for f in ${SIMPLEK3S_PENDING}/*.yaml; do"
        _CLEAR_CMD+=" [ -e \"\$f\" ] || continue;"
        _CLEAR_CMD+=" T=${K3S_MANIFEST_DIR}/\$(basename \"\$f\");"
        _CLEAR_CMD+=" if [ -e \"\$T\" ]; then rm -f \"\$T\"; N=\$((N+1)); fi; done;"
        _CLEAR_CMD+=" echo \"removed \$N stale manifest(s)\"'"
        # shellcheck disable=SC2086
        _CID="$(ssm_send_command_multi "${REGION}" "${PROFILE}" "${_CLEAR_CMD}" ${_OTHERS})" || return 1
        # shellcheck disable=SC2086
        ssm_await_all "${REGION}" "${PROFILE}" "${_CID}" 60 "${POLL_INTERVAL}" \
            "${WORKDIR}/clear" ${_OTHERS} > /dev/null 2>&1 || true
        # shellcheck disable=SC2086
        split_invocations "${WORKDIR}/clear" ${_OTHERS}
        for _ID in ${_OTHERS}; do
            if step_succeeded "${WORKDIR}/clear" "${_ID}"; then
                echo "  ${_ID}  $(tr -d '\n' < "${WORKDIR}/clear/${_ID}.report")"
            else
                echo "  ${_ID}  FAILED to clear — stale copies may remain" >&2
            fi
        done
    fi

    echo "Recording staging ownership on ${STAGE_ID}"
    _CLAIM_CMD="sudo bash -c 'kubectl -n kube-system delete configmap simplek3s-staging-owner"
    _CLAIM_CMD+=" --ignore-not-found >/dev/null 2>&1;"
    _CLAIM_CMD+=" kubectl -n kube-system create configmap simplek3s-staging-owner"
    _CLAIM_CMD+=" --from-literal=node=\$(hostname)"
    _CLAIM_CMD+=" --from-literal=instance_id=${STAGE_ID}"
    _CLAIM_CMD+=" --from-literal=claimed_at=\$(date -u +%Y-%m-%dT%H:%M:%SZ) >/dev/null"
    _CLAIM_CMD+=" && echo claimed'"
    _CID="$(ssm_send_command_multi "${REGION}" "${PROFILE}" "${_CLAIM_CMD}" "${STAGE_ID}")" || return 1
    ssm_await_all "${REGION}" "${PROFILE}" "${_CID}" 60 "${POLL_INTERVAL}" \
        "${WORKDIR}/claim" "${STAGE_ID}" > /dev/null 2>&1 || true
    if step_succeeded "${WORKDIR}/claim" "${STAGE_ID}"; then
        echo "  ownership recorded"
        return 0
    fi
    echo "  FAILED to record ownership — the cluster has no owner on record" >&2
    return 1
}

# Render the merged report. Per-node sync results, one cluster-state block, one
# staging result.
#
# A node with no report is shown as "no response" rather than omitted. Dropping
# it would shrink the denominator, so a fan-out where half the nodes never
# answered would read exactly like one where they all had nothing to do.
function render_report() {
    python3 - "${WORKDIR}" "${NODE_NAMES_FILE}" "${MODE}" "${DRY}" "${VERBOSE}" "${STAGE_ID}" <<'PYEOF'
import json, os, sys

workdir, nodes_file, mode, dry, verbose, stage_id = sys.argv[1:7]
dry = dry == "true"
verbose = verbose == "1"

L_SYNC = "Would sync" if dry else "Synced"
L_STAGE = "Would stage" if dry else "Staged"
L_ACTION = "Would run" if dry else "Actions"

nodes = {}
order = []
with open(nodes_file) as fh:
    for line in fh:
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 3:
            nodes[parts[0]] = (parts[1], parts[2])
            order.append(parts[0])

def load(step, node_id):
    """(status, records) for one node's step. status None = never responded."""
    sdir = os.path.join(workdir, step)
    spath = os.path.join(sdir, node_id + ".status")
    rpath = os.path.join(sdir, node_id + ".report")
    status = None
    if os.path.exists(spath):
        with open(spath) as fh:
            status = fh.read().strip()
    records = []
    if os.path.exists(rpath):
        with open(rpath) as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("{"):
                    try:
                        records.append(json.loads(line))
                    except ValueError:
                        pass
    return status, records

def by_step(records):
    out, actions = {}, []
    for r in records:
        if r.get("step") == "action":
            actions.append(r)
        else:
            out[r.get("step")] = r
    return out, actions

# ---- sync, per node -------------------------------------------------------
if mode in ("sync", "pull"):
    printed = False
    for node_id in order:
        status, records = load("sync", node_id)
        if status is None and not records and not os.path.exists(
                os.path.join(workdir, "sync", node_id + ".status")):
            # Not part of this run's sync scope at all.
            if not os.path.exists(os.path.join(workdir, "sync")):
                continue
            if not any(f.startswith(node_id) for f in os.listdir(os.path.join(workdir, "sync"))):
                continue
        name = nodes.get(node_id, ("?", "?"))[0]
        label = "%-21s %s" % (node_id, name)
        steps, _ = by_step(records)
        s = steps.get("sync")
        if status is None:
            detail = "no response (never reached a terminal state)"
        elif s is None:
            detail = "FAILED — no report (status %s)" % status
        elif s.get("result") != "ok":
            detail = "FAILED — " + s.get("detail", "no detail")
        elif s.get("changed", 0) == 0:
            detail = "no changes"
        else:
            detail = "%d file(s)" % s["changed"] if dry else "%d file(s) changed" % s["changed"]
        if not printed:
            print("%s:" % L_SYNC)
            printed = True
        print("  %s  %s" % (label, detail))
        if verbose and s and s.get("files"):
            for f in s["files"]:
                print("      %s" % f)
    if printed:
        print("")

# ---- staging --------------------------------------------------------------
if mode in ("apply", "pull") and stage_id:
    status, records = load("stage", stage_id)
    steps, actions = by_step(records)

    cl = steps.get("cluster")
    if cl is None:
        print("%-11s: not reported" % "Cluster")
    elif cl.get("result") != "ok":
        print("%-11s: unknown — %s" % ("Cluster", cl.get("detail", "no detail")))
    else:
        print("%-11s: %d current, %d differ, %d not applied"
              % ("Cluster", cl.get("current", 0), cl.get("differs", 0), cl.get("missing", 0)))
        for f in cl.get("files", []):
            print("             %s" % f)

    gen = steps.get("generation")
    if gen:
        before, after = gen.get("before", "unknown"), gen.get("after", "unknown")
        if before == after:
            print("%-11s: %s (unchanged)" % ("Generation", after))
        else:
            print("%-11s: %s -> %s%s" % ("Generation", before, after,
                                         " (would advance)" if dry else ""))

    st = steps.get("stage")
    if status is None:
        print("%-11s: no response (never reached a terminal state)" % L_STAGE)
    elif st is None:
        print("%-11s: not attempted" % L_STAGE)
    elif st.get("result") != "ok":
        print("%-11s: FAILED after %d of %d" % (L_STAGE, st.get("changed", 0), st.get("total", 0)))
    else:
        print("%-11s: %d of %d manifests%s on this node's disk"
              % (L_STAGE, st.get("changed", 0), st.get("total", 0), "" if dry else " written"))

    if not actions:
        print("%-11s: not attempted" % L_ACTION)
    else:
        performed = [a for a in actions if a.get("performed")]
        shown = actions if (verbose or dry) else performed
        if not shown:
            print("%-11s: none needed" % L_ACTION)
        else:
            first = True
            for a in shown:
                if dry:
                    text = "%s — %s" % (a.get("name", "?").replace("_", " "), a.get("detail", ""))
                else:
                    what = "performed" if a.get("performed") else "skipped"
                    text = "%-22s %-9s (%s)" % (a.get("name", "?"), what, a.get("detail", ""))
                print(("%-11s: %s" % (L_ACTION, text)) if first else ("             " + text))
                first = False
PYEOF
}

# PARSE OPTIONS
# Flags are pulled out before the positionals are counted, so `<profile>
# --verbose` is not mistaken for the rejected two-positional form. Every
# argument is scanned, not just $1: `sk3s` supplies the AWS profile as the first
# positional when one is omitted, so a flag the caller typed first ends up at $2.
VERBOSE=0
DRY_RUN=0
ALL_NODES=0
STRICT_SYNC=0
CLAIM_OWNERSHIP=0
MODE="pull"
INSTANCE_ID=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "${1}" in
        --mode)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --mode requires a value (sync, apply or pull)." >&2
                usage
            fi
            MODE="${2}"
            shift 2
            ;;
        --instance-id)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --instance-id requires a value." >&2
                usage
            fi
            INSTANCE_ID="${2}"
            shift 2
            ;;
        --all-nodes)    ALL_NODES=1; shift ;;
        --strict-sync)  STRICT_SYNC=1; shift ;;
        --claim-ownership) CLAIM_OWNERSHIP=1; shift ;;
        --verbose)      VERBOSE=1; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        -h | --help)    usage 0 ;;
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
case "${MODE}" in
    sync | apply | pull) ;;
    *)
        echo "Error: --mode must be one of sync, apply, pull (got '${MODE}')." >&2
        usage
        ;;
esac
if [[ "${MODE}" == "sync" ]] && (( CLAIM_OWNERSHIP == 1 )); then
    echo "Error: --claim-ownership needs staging, which --mode sync does not do." >&2
    usage
fi
if [[ "${MODE}" == "apply" ]] && (( ALL_NODES == 1 )); then
    echo "Error: --all-nodes affects the file sync, which --mode apply does not do." >&2
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
DRY="false"
(( DRY_RUN == 1 )) && DRY="true"

WORKDIR="$(mktemp -d)"
NODE_NAMES_FILE="${WORKDIR}/nodes.tsv"
SYNC_IDS=""
STAGE_ID=""
OWNER_NODE_NAME=""
OWNER_INSTANCE_ID=""
UNREACHABLE_COUNT=0

resolve_scope || exit 1

SYNC_FAILURES=0
if [[ "${MODE}" != "apply" ]]; then
    run_sync || {
        echo "Error: the file sync could not be dispatched." >&2
        exit 1
    }
    for _ID in ${SYNC_IDS}; do
        if ! step_succeeded "${WORKDIR}/sync" "${_ID}"; then
            SYNC_FAILURES=$((SYNC_FAILURES + 1))
        fi
    done
fi

# Whether a sync failure stops staging. By default only the STAGING node's own
# failure does: a stale file on some other node does not make the cluster update
# wrong, and refusing to deploy because an unrelated node is unreachable is
# exactly the outage-time paralysis worth avoiding. --strict-sync opts into the
# conservative reading.
STAGE_BLOCKED=""
if [[ "${MODE}" == "pull" ]]; then
    if (( STRICT_SYNC == 1 )) && (( SYNC_FAILURES > 0 )); then
        STAGE_BLOCKED="--strict-sync: ${SYNC_FAILURES} node(s) failed to sync"
    elif [[ -n "${STAGE_ID}" ]] && ! step_succeeded "${WORKDIR}/sync" "${STAGE_ID}"; then
        STAGE_BLOCKED="the staging node's own sync failed"
    fi
fi

if [[ "${MODE}" != "sync" && -z "${STAGE_BLOCKED}" ]]; then
    run_stage || {
        echo "Error: staging could not be dispatched." >&2
        exit 1
    }
fi

render_report

STAGE_OK=1
if [[ "${MODE}" != "sync" ]]; then
    if [[ -n "${STAGE_BLOCKED}" ]]; then
        echo ""
        echo "Staging skipped: ${STAGE_BLOCKED}" >&2
        STAGE_OK=0
    elif ! step_succeeded "${WORKDIR}/stage" "${STAGE_ID}"; then
        STAGE_OK=0
    fi
fi

if (( CLAIM_OWNERSHIP == 1 )) && (( DRY_RUN == 0 )) && (( STAGE_OK == 1 )); then
    echo ""
    run_claim_ownership || exit 1
elif (( CLAIM_OWNERSHIP == 1 )) && (( DRY_RUN == 1 )); then
    echo ""
    echo "Would claim staging ownership for ${STAGE_ID} and clear other nodes."
fi

echo ""
if (( DRY_RUN == 1 )); then
    echo "Nothing was changed. Re-run without --dry-run to apply."
    exit 0
fi

if (( SYNC_FAILURES > 0 )) || (( UNREACHABLE_COUNT > 0 )) || (( STAGE_OK == 0 )); then
    echo "Result: FAIL — see the failures above." >&2
    echo "        Re-run with --verbose for each node's log." >&2
    exit 1
fi

if [[ "${MODE}" != "sync" ]]; then
    echo "Next: the K3s deploy controller applies staged manifests asynchronously."
    echo "      ./sk3s status"
fi
exit 0
