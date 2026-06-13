#!/bin/bash

set -euo pipefail

INSTANCE_ID="$1"
COMMAND_ID="$2"
REGION="$3"
PROFILE="$4"

function get_output() {
	local RESULT
	local STATUS
	local STDOUT
	local STDERR
	
	count=30
	for i in $(seq $count); do
		RESULT=$(aws ssm get-command-invocation \
			--command-id "${COMMAND_ID}" \
			--instance-id "${INSTANCE_ID}" \
			--region "${REGION}" \
			--profile "${PROFILE}")

		STATUS=$(echo "${RESULT}" | python3 -c "import sys,json; print(json.load(sys.stdin)['Status'])")
		STDOUT=$(echo "${RESULT}" | python3 -c "import sys,json; print(json.load(sys.stdin)['StandardOutputContent'])")
		STDERR=$(echo "${RESULT}" | python3 -c "import sys,json; print(json.load(sys.stdin)['StandardErrorContent'])")

		if [ "${STATUS}" != "InProgress" ]; then
			break
		fi

		sleep 1
	done	


	echo "Status: ${STATUS}"

	if [[ -n "${STDOUT}" ]]; then
		echo "--- stdout ---"
		echo "${STDOUT}"
	fi

	if [[ -n "${STDERR}" ]]; then
		echo "--- stderr ---"
		echo "${STDERR}"
	fi
}

get_output
