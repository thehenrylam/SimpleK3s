#!/bin/bash
# End-to-end health check of an already-deployed SimpleK3s cluster.
#
# Discovers every running EC2 node tagged Nickname=<nickname>, runs the on-node
# fetch_*.py probes over SSM (parallel + rate-limited), reconciles results
# across nodes, and grades the stitched snapshot against an answer sheet —
# printing a 🟢/🟡/🟥 report card. The heavy lifting lives in e2e/simplek3s_e2e.py
# (stdlib-only, run via uv); this wrapper handles args + the repo logging pattern.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: test-out_simplek3s.sh <region> <profile> <nickname> [options]

Required:
  <region>    AWS region (e.g. us-east-1)
  <profile>   AWS profile (e.g. opentofu_deployer_proofofconcept)
  <nickname>  cluster Nickname tag used to discover the nodes

Options (forwarded to the Python orchestrator):
  --failures-only        show only warnings + failures in the report
  --capture              generate an answer sheet from the current cluster
  -a, --answersheet PATH compare against PATH instead of answersheet.default.json
  -o, --out PATH         where --capture writes the sheet (default: stdout)
  --rate-interval N      min seconds between AWS calls (default: 1.0)
  --probe-timeout N      per-probe timeout in seconds (default: 300)

Wrapper-only options:
  --log-name NAME        log filename stem (default: test-out_simplek3s)
  --log-timestamp TS     log timestamp (default: now, %Y%m%d-%H%M%S)
EOF
}

if [[ $# -lt 3 ]]; then
    usage >&2
    exit 2
fi

REGION="$1"
PROFILE="$2"
NICKNAME="$3"
shift 3

LOG_FILENAME="test-out_simplek3s"
LOG_TIMESTAMP="$(date +'%Y%m%d-%H%M%S')"

# Split wrapper-only flags from flags forwarded to the Python orchestrator.
PASS_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --log-name)      LOG_FILENAME="$2"; shift 2 ;;
        --log-timestamp) LOG_TIMESTAMP="$2"; shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        *)               PASS_ARGS+=("$1"); shift ;;
    esac
done

CURR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Logging setup ---
LOG_FILE="${CURR_ROOT}/${LOG_FILENAME}-${LOG_TIMESTAMP}.log"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 0644 "$LOG_FILE"

# Prefer uv on PATH; fall back to the standard-toolchain install location.
UV_BIN="$(command -v uv || true)"
if [[ -z "$UV_BIN" ]]; then
    UV_BIN="/opt/homebrew/bin/uv"
fi
if [[ ! -x "$UV_BIN" ]]; then
    echo "[FAIL] uv not found. Install the standard toolchain: ./toolchain/tc_standard_macos_install.sh" >&2
    exit 1
fi

# Stream the orchestrator's combined output through a timestamping pipeline to
# the terminal, the log file, and syslog. This is a *foreground* pipeline rather
# than `exec > >(...)`: the shell waits for every stage to finish, so the full
# report card flushes before the prompt returns — instead of trailing in after
# control is handed back. PIPESTATUS[0] preserves the orchestrator's exit code.
set +e
{
    echo "=== $(basename "${0}") (Starting) ==="
    rc=0
    "$UV_BIN" run "${CURR_ROOT}/e2e/simplek3s_e2e.py" \
        --region "$REGION" \
        --profile "$PROFILE" \
        --nickname "$NICKNAME" \
        ${PASS_ARGS[@]+"${PASS_ARGS[@]}"} || rc=$?
    echo "=== $(basename "${0}") (Completed: exit ${rc}) ==="
    exit "$rc"
} 2>&1 \
    | while IFS= read -r line; do printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$line"; done \
    | tee -a "$LOG_FILE" >(logger -t "${LOG_FILENAME}")

exit "${PIPESTATUS[0]}"
