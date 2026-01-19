#!/bin/bash

# COMMON AWS UTILITIES
# - Used to abstract away the complexities of how we interact with AWS
# NOTE: Separated from common utilities so that switching to different providers is slightly easier

PROVIDER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$PROVIDER_DIR/../../"
# Retrieve all of the needed environment variables from this file
source "$SCRIPT_DIR/simplek3s.env"

# Inserts the value into SSM
function ssm_put() {
    # Required Inputs
    local name="$1"
    local type="$2"
    local value="$3"
    local overwrite="${4:-false}"
    local region="${5:-$AWS_REGION}"
    ssm_put_raw "$PARAMSTORE_KEYROOT/$name" "$type" "$value" "$overwrite" "$region"
    "${args[@]}"
}

function ssm_put_raw() {
    # Required Inputs
    local name="$1"
    local type="$2"
    local value="$3"
    local overwrite="${4:-false}"
    local region="${5:-$AWS_REGION}"
    local args=(aws ssm put-parameter --name "$name" --type "$type" --value "$value" --region "$region")
    [[ "$overwrite" == "true" ]] && args+=(--overwrite)
    "${args[@]}"
}

# Returns the parameter value on stdout.
# Success: exit 0 (value is non-empty)
# Failure: exit 1 (missing / access denied / empty / other error)
function get_ssm_raw() {
    # Define an uninitialized value to set up a fallback output 
    local PLACEHOLDER_TOKEN="__UNINITIALIZED__"

    local ssm_param="$1"          # full name, e.g. "/path/to/key"
    local w_decryption="${2:-}"   # non-empty => use --with-decryption
    local aws_region="${3:-$AWS_REGION}"

    local args=(aws ssm get-parameter
        --name "$ssm_param"
        --query "Parameter.Value"
        --output text
        --region "$aws_region"
    )
    [[ -n "$w_decryption" ]] && args+=(--with-decryption)

    local output_value
    # Fail (return 1) if the command itself fails
    output_value="$("${args[@]}" 2>/dev/null)" || return 1 
    # Checks if the variable is not EMPTY, return 1 if it fails the test
    [[ -n "$output_value" ]] || return 1 
    # Checks if the variable is not PLACEHOLDER_TOKEN, return 1 if it fails the test
    [[ "$output_value" != "$PLACEHOLDER_TOKEN" ]] || return 1

    echo "$output_value"
}

# Convenience wrapper: key relative to PARAMSTORE_KEYROOT
function get_ssm() {
    local key="$1"
    local w_decryption="${2:-}"
    local aws_region="${3:-$AWS_REGION}"

    get_ssm_raw "$PARAMSTORE_KEYROOT/$key" "$w_decryption" "$aws_region" || return 1
}

# Wait until the parameter exists (and is non-empty), then print it.
# Defaults: 180 attempts * 2s = 6 minutes
function wait_ssm_raw() {
    local ssm_param="$1"
    local w_decryption="${2:-}"
    local aws_region="${3:-$AWS_REGION}"
    local max_attempts="${4:-150}"
    local sleep_s="${5:-2}"

    local output_value
    for ((i=1; i<=max_attempts; i++)); do
        if output_value="$(get_ssm_raw "$ssm_param" "$w_decryption" "$aws_region")"; then
            echo "$output_value"
            return 0
        fi
        sleep "$sleep_s"
    done
    return 1
}

# Convenience wrapper: key relative to PARAMSTORE_KEYROOT
function wait_ssm() {
    local key="$1"
    local w_decryption="${2:-}"
    local aws_region="${3:-$AWS_REGION}"
    local max_attempts="${4:-150}"
    local sleep_s="${5:-2}"

    wait_ssm_raw "$PARAMSTORE_KEYROOT/$key" "$w_decryption" "$aws_region" \
        "$max_attempts" "$sleep_s" || return 1
}

