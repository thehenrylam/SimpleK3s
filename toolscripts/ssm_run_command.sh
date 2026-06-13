#!/bin/bash

set -euo pipefail

INSTANCE_ID="$1"
COMMAND="$2"
REGION="$3"
PROFILE="$4"

aws ssm send-command \
	--instance-ids "${INSTANCE_ID}" \
	--document-name "AWS-RunShellScript" \
	--parameters "commands=[\"${COMMAND}\"]" \
	--region "${REGION}" \
	--profile "${PROFILE}" \
	--query "Command.CommandId" \
	--output text
