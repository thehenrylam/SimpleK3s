#!/bin/bash

set -euo pipefail

# Run verify_cluster.sh on a controlplane node via SSM without needing to look
# up an instance ID manually. The controlplane node is located by the Nickname
# tag; any running controlplane node can run the check.
#
# Usage:
#   ./toolscripts/ssm_verify_cluster.sh <profile> [<nickname> [<region>]]
#
# Arguments:
#   profile   AWS CLI profile to use (required)
#   nickname  Cluster nickname tag (default: inferred from examples/ex_basic/terraform.tfvars)
#   region    AWS region          (default: inferred from examples/ex_basic/terraform.tfvars)
#
# Environment variables:
#   STABILITY_WINDOW_SECONDS  Passed through to verify_cluster.sh (default: 300)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TFVARS="$REPO_ROOT/examples/ex_basic/terraform.tfvars"

VERIFY_SCRIPT="/opt/simplek3s/bootstrap/default/node_verify-all.sh"
POLL_INTERVAL=5
POLL_MAX=120  # 10 minutes

function usage() {
    echo "Usage: $(basename "$0") <profile> [<nickname> [<region>]]" >&2
    echo "" >&2
    echo "  profile   AWS CLI profile (required)" >&2
    echo "  nickname  Cluster nickname (default: inferred from terraform.tfvars)" >&2
    echo "  region    AWS region      (default: inferred from terraform.tfvars)" >&2
    exit 2
}

function infer_tfvar() {
    grep "^${1}[[:space:]]*=" "$TFVARS" 2>/dev/null \
        | awk -F'"' '{print $2}' | head -1
}

if [[ $# -lt 1 ]]; then
    usage
fi

PROFILE="$1"
NICKNAME="${2:-$(infer_tfvar "nickname")}"
REGION="${3:-$(infer_tfvar "aws_region")}"

if [[ -z "$NICKNAME" || -z "$REGION" ]]; then
    echo "Error: could not infer nickname/region from $TFVARS — supply them as arguments." >&2
    usage
fi

STABILITY_ENV=""
if [[ -n "${STABILITY_WINDOW_SECONDS:-}" ]]; then
    STABILITY_ENV="STABILITY_WINDOW_SECONDS=${STABILITY_WINDOW_SECONDS} "
fi

echo "Cluster  : nickname=${NICKNAME}  region=${REGION}  profile=${PROFILE}"

# Find any running controlplane instance for this cluster
INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --profile "$PROFILE" \
    --filters \
        "Name=tag:Nickname,Values=${NICKNAME}" \
        "Name=tag:Name,Values=*_controlplane-*" \
        "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
    echo "Error: no running controlplane instance found for nickname '${NICKNAME}' in ${REGION}." >&2
    exit 1
fi

echo "Instance : ${INSTANCE_ID}"
echo "Script   : ${VERIFY_SCRIPT}"
echo ""

# Send the SSM command
COMMAND_ID=$(aws ssm send-command \
    --region "$REGION" \
    --profile "$PROFILE" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"sudo ${STABILITY_ENV}bash ${VERIFY_SCRIPT}\"]" \
    --query "Command.CommandId" \
    --output text)

echo "Command ID: ${COMMAND_ID}"
echo "Polling for output (up to $((POLL_MAX * POLL_INTERVAL / 60)) min)..."
echo ""

# Poll until the command finishes
RESULT=""
STATUS=""
for ((i=1; i<=POLL_MAX; i++)); do
    RESULT=$(aws ssm get-command-invocation \
        --region "$REGION" \
        --profile "$PROFILE" \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" 2>/dev/null || true)

    STATUS=$(echo "$RESULT" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('Status',''))" 2>/dev/null || true)

    if [[ "$STATUS" != "InProgress" && "$STATUS" != "Pending" && -n "$STATUS" ]]; then
        break
    fi

    echo "  (${i}/${POLL_MAX}) ${STATUS:-Pending} — waiting ${POLL_INTERVAL}s..."
    sleep "$POLL_INTERVAL"
done

# Print output
STDOUT=$(echo "$RESULT" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('StandardOutputContent',''))" 2>/dev/null || true)
STDERR=$(echo "$RESULT" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('StandardErrorContent',''))" 2>/dev/null || true)

if [[ -n "$STDOUT" ]]; then
    echo "--- stdout ---"
    echo "$STDOUT"
fi

if [[ -n "$STDERR" ]]; then
    echo "--- stderr ---"
    echo "$STDERR"
fi

echo ""
echo "Result: ${STATUS}"

[[ "$STATUS" == "Success" ]]
