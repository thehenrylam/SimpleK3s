#!/bin/bash

set -euo pipefail

INSTANCE_ID="$1"
REGION="$2"
PROFILE="$3"

aws ssm start-session \
	--target "${INSTANCE_ID}" \
	--region "${REGION}" \
	--profile "${PROFILE}" \
	--document-name AWS-StartInteractiveCommand \
	--parameters command="bash"

