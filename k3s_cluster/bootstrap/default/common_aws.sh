#!/bin/bash

# COMMON AWS UTILITIES
# - Used to abstract away the complexities of how we interact with AWS
# NOTE: Separated from common utilities so that switching to different providers is slightly easier

# Set bash flags 
set -euo pipefail 
# -u            : Error if an unset variable is referenced 
# -e            : Exits on ANY command failure 
# -o pipefail   : Make pipeline fail if any command in them fails 

SCRIPT_PATH=$(realpath $(dirname $0))
# Retrieve all of the needed environment variables from this file
source $SCRIPT_DIR/simplek3s.env

# Set SSM token (disallow override)
function set_ssm_param() {
    # Required Inputs
    local key="$1"
    local type="$2"
    local value="$3"
    # Inputs with default variables
    local aws_region="${4:-$AWS_REGION}"

    set_ssm_param_raw "$PARAMSTORE_KEYROOT/$key" "$type" "$value" "$aws_region" || return 1
    return 0
}
function set_ssm_param_raw() {
    # Required Inputs
    local ssm_param="$1"
    local type="$2"
    local value="$3"
    # Inputs with default variables
    local aws_region="${4:-$AWS_REGION}"

    # Store in Parameter Store
    aws ssm put-parameter \
        --name "$ssm_param" \
        --type "$type" \
        --value "$value" \
        --region "$aws_region" || return 1
    return 0
}

# Set SSM token (overwrite)
function set_ssm_param_overwrite() {
    # Required Inputs
    local key="$1"
    local type="$2"
    local value="$3"
    # Inputs with default variables
    local aws_region="${4:-$AWS_REGION}"

    set_ssm_param_overwrite_raw "$PARAMSTORE_KEYROOT/$key" "$type" "$value" "$aws_region" || return 1
    return 0
}
function set_ssm_param_overwrite_raw() {
    # Required Inputs
    local ssm_param="$1"
    local type="$2"
    local value="$3"
    # Inputs with default variables
    local aws_region="${4:-$AWS_REGION}"

    # Store in Parameter Store
    aws ssm put-parameter \
        --name "$ssm_param" \
        --type "$type" \
        --value "$value" \
        --overwrite \
        --region "$aws_region" || return 1
    return 0
}

# Get SSM token
function get_ssm_param() {
    local key="$1"
    local w_decryption="${2:-}"
    # Inputs with default variables
    local aws_region="${3:-$AWS_REGION}"

    local output_value=""
    output_value="$(get_ssm_param_raw \
        "$PARAMSTORE_KEYROOT/$key" \
        "$w_decryption" \
        "$aws_region")" || return 1

    # Output the SSM parameter if the output value successfully executed
    echo "$output_value"
    return 0
}
function get_ssm_param_raw() {
    # Define an uninitialized value to set up a fallback output 
    local PLACEHOLDER_TOKEN="__UNINITIALIZED__"

    # Required inputs
    local ssm_param="$1"
    local w_decryption="${2:-}"
    # Inputs with default variables
    local aws_region="${3:-$AWS_REGION}"

    local output_value="$PLACEHOLDER_TOKEN"
    local output_code=0
    if [[ -z "$w_decryption" ]]; then
        # Try to get the value of the ssm parameter (w/o decryption)
        output_value="$(aws ssm get-parameter \
            --name "$ssm_param" \
            --query "Parameter.Value" \
            --output text \
            --region "$aws_region" 2>/dev/null)" || {
            # On failure: set the output to the placeholder token
            output_value="$PLACEHOLDER_TOKEN"
        }
    else
        # Try to get the value of the ssm parameter (w/ decryption)
        output_value="$(aws ssm get-parameter \
            --name "$ssm_param" \
            --with-decryption \
            --query "Parameter.Value" \
            --output text \
            --region "$aws_region" 2>/dev/null)" || {
            # On failure: set the output to the placeholder token
            output_value="$PLACEHOLDER_TOKEN"
        }
    fi

    # If the output_value is empty or a placeholder, then set the output_code to be 2
    if [[ -z "$output_value" || "$output_value" == "$PLACEHOLDER_TOKEN" ]]; then
        output_code=1
    fi

    # Output value and code
    echo "$output_value"
    return $output_code
}

# Wait for the SSM token
function wait_ssm_param() {
    local key="$1"
    local w_decryption="${2:-}"
    # Inputs with default variables
    local aws_region="${3:-$AWS_REGION}"

    local max_attempts="${4:-180}"   # 180 * 2s = 6 minutes
    local sleep_s="${5:-2}"

    local output_value=""
    output_value="$(wait_ssm_param_raw \
        "$PARAMSTORE_KEYROOT/$key" \
        "$w_decryption" \
        "$aws_region" \
        "$max_attempts" \
        "$sleep_s")" || return 1

    # Output the value so long as the prev command succeeded
    echo "$output_value"
    return 0
}
function wait_ssm_param_raw() {
    local ssm_param="$1"
    local w_decryption="${2:-}"
    # Inputs with default variables
    local aws_region="${3:-$AWS_REGION}"

    local max_attempts="${4:-180}"   # 180 * 2s = 6 minutes
    local sleep_s="${5:-2}"

    for ((i=1; i<=max_attempts; i++)); do
        # Attempt to get the ssm token
        local output_value=""
        output_value="$(get_ssm_param_raw \
            "$ssm_param" \
            "$w_decryption" \
            "$aws_region" 2>/dev/null)"
        
        # If the return code is 0: Output the value
        if [[ "$?" == 0 ]]; then
            echo "$output_value"
            return 0
        fi

        sleep "$sleep_s"
    done

    return 1
}
