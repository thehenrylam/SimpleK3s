#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_ROOT}"

INSTANCE_ID="$1"
COMMAND="$2"
REGION="$3"
PROFILE="$4"

# 1. Send a command — prints a CommandId
COMMAND_ID=$(bash ./ssm_run_command.sh "${INSTANCE_ID}" "${COMMAND}" "${REGION}" "${PROFILE}")

# 2. Fetch the output (run after the command completes)
bash ./ssm_get_output.sh "${INSTANCE_ID}" "${COMMAND_ID}" "${REGION}" "${PROFILE}"

