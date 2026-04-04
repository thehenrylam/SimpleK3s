#!/bin/bash

# COMMON AWS UTILITIES
# - Used to abstract away the complexities of how we interact with AWS
# NOTE: Separated from common utilities so that switching to different providers is slightly easier

PROVIDER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$PROVIDER_DIR/../../"
# Retrieve all of the needed environment variables from this file
source "$SCRIPT_DIR/simplek3s.env"

# Base URL for the EC2 Instance Metadata Service (IMDSv2).
# 169.254.169.254 is a dynamically configured link-local address reserved for cloud metadata services.
# See: https://serverfault.com/a/427022
# Used to retrieve instance identity information (instance ID, AZ, region, etc.)
# from within a running EC2 instance.
# Docs: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html
AWS_IMDS_URL="http://169.254.169.254"

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
    # Checks if variable is NOT empty and NOT PLACEHOLDER_TOKEN
    # If checks fail, then consider our output as "not ready" (i.e. return code 1)
    [[ -n "$output_value" ]] || return 1 
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

# Returns the Kubernetes provider ID for this EC2 instance using IMDSv2.
# Format: aws:///<availability-zone>/<instance-id>
# Required so Karpenter can match this K3s node to its nodeclaim via spec.providerID.
function get_ec2_provider_id() {
    local imds_token
    imds_token=$(curl -s -X PUT "$AWS_IMDS_URL/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") || return 1

    local az
    az=$(curl -s -H "X-aws-ec2-metadata-token: $imds_token" \
        "$AWS_IMDS_URL/latest/meta-data/placement/availability-zone") || return 1

    local instance_id
    instance_id=$(curl -s -H "X-aws-ec2-metadata-token: $imds_token" \
        "$AWS_IMDS_URL/latest/meta-data/instance-id") || return 1

    echo "aws:///$az/$instance_id"
}

