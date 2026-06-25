#!/bin/bash

# Set bash flags
set -euo pipefail
# -u            : Error if an unset variable is referenced
# -e            : Exits on ANY command failure
# -o pipefail   : Make pipeline fail if any command in them fails

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/simplek3s.env"

CLUSTER_TYPE="${1:-}"
if [[ -z "$CLUSTER_TYPE" ]]; then
    echo "Usage: $(basename "$0") <CLUSTER_TYPE>" >&2
    exit 2
fi

POOLS_CONFIG_FILE="$SCRIPT_DIR/longhorn_pools_config.json"

# If the Longhorn pools config was not uploaded (Longhorn subsystem not enabled), skip.
if [[ ! -f "$POOLS_CONFIG_FILE" ]]; then
    log_info "No Longhorn pools config found at '$POOLS_CONFIG_FILE'; skipping disk setup."
    exit 0
fi

log_info "$0: LAUNCHED — setting up Longhorn EBS disks for node type '$CLUSTER_TYPE'"

########################################
#   IMDSv2 helpers                     #
########################################
function get_imds_token() {
    curl -s -X PUT \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
        "http://169.254.169.254/latest/api/token"
}

function get_imds_value() {
    local TOKEN="$1"
    local PATH_SUFFIX="$2"
    curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
        "http://169.254.169.254/latest/meta-data/$PATH_SUFFIX"
}

########################################
#   Per-pool disk setup                #
########################################
function setup_pool_disk() {
    local POOL_NAME="$1"
    local SSM_PARAM_NAME="$2"
    local DISK_PATH="$3"
    local NODE_TARGET="$4"

    # Only process pools that target this node type (or "all")
    if [[ "$NODE_TARGET" != "all" && "$NODE_TARGET" != "$CLUSTER_TYPE" ]]; then
        log_info "Pool '$POOL_NAME': node_target='$NODE_TARGET' does not match cluster_type='$CLUSTER_TYPE'; skipping."
        return 0
    fi

    log_info "Pool '$POOL_NAME': setting up EBS disk at '$DISK_PATH'"

    # Step 1: Get IMDSv2 token and fetch instance metadata
    local TOKEN
    TOKEN="$(get_imds_token)"
    local AZ
    AZ="$(get_imds_value "$TOKEN" "placement/availability-zone")"
    local INSTANCE_ID
    INSTANCE_ID="$(get_imds_value "$TOKEN" "instance-id")"

    log_info "Pool '$POOL_NAME': instance=$INSTANCE_ID, AZ=$AZ"

    # Step 2: Read EBS volume IDs from SSM Parameter Store
    local VOLUME_IDS_JSON
    VOLUME_IDS_JSON="$(aws ssm get-parameter \
        --name "$SSM_PARAM_NAME" \
        --query "Parameter.Value" \
        --output text \
        --region "$AWS_REGION")"

    if [[ -z "$VOLUME_IDS_JSON" || "$VOLUME_IDS_JSON" == "None" ]]; then
        log_fail "Pool '$POOL_NAME': SSM parameter '$SSM_PARAM_NAME' is empty or missing."
        return 1
    fi

    # Step 3: Find the volume in the same AZ as this instance
    local VOLUME_ID
    # shellcheck disable=SC2046
    VOLUME_ID="$(aws ec2 describe-volumes \
        --volume-ids $(echo "$VOLUME_IDS_JSON" | python3 -c "import json,sys; print(' '.join(json.load(sys.stdin)))") \
        --query "Volumes[?AvailabilityZone=='$AZ'].VolumeId | [0]" \
        --output text \
        --region "$AWS_REGION")"

    if [[ -z "$VOLUME_ID" || "$VOLUME_ID" == "None" ]]; then
        log_fail "Pool '$POOL_NAME': no EBS volume found in AZ '$AZ' from list: $VOLUME_IDS_JSON"
        return 1
    fi

    log_info "Pool '$POOL_NAME': matched volume $VOLUME_ID in AZ $AZ"

    # Step 4: Attach the volume (idempotent — handle already-attached case)
    local ATTACH_STATE
    ATTACH_STATE="$(aws ec2 describe-volumes \
        --volume-ids "$VOLUME_ID" \
        --query "Volumes[0].State" \
        --output text \
        --region "$AWS_REGION")"

    if [[ "$ATTACH_STATE" == "in-use" ]]; then
        local ATTACHED_TO
        ATTACHED_TO="$(aws ec2 describe-volumes \
            --volume-ids "$VOLUME_ID" \
            --query "Volumes[0].Attachments[0].InstanceId" \
            --output text \
            --region "$AWS_REGION")"
        if [[ "$ATTACHED_TO" == "$INSTANCE_ID" ]]; then
            log_info "Pool '$POOL_NAME': volume $VOLUME_ID already attached to this instance."
        else
            log_fail "Pool '$POOL_NAME': volume $VOLUME_ID is attached to a different instance ($ATTACHED_TO)."
            return 1
        fi
    else
        log_info "Pool '$POOL_NAME': attaching volume $VOLUME_ID to instance $INSTANCE_ID..."
        aws ec2 attach-volume \
            --volume-id "$VOLUME_ID" \
            --instance-id "$INSTANCE_ID" \
            --device "/dev/sdh" \
            --region "$AWS_REGION" >/dev/null

        # Step 5: Wait for volume to be in-use
        log_info "Pool '$POOL_NAME': waiting for volume $VOLUME_ID to be in-use..."
        local MAX_WAIT=60
        local ELAPSED=0
        while [[ "$ELAPSED" -lt "$MAX_WAIT" ]]; do
            ATTACH_STATE="$(aws ec2 describe-volumes \
                --volume-ids "$VOLUME_ID" \
                --query "Volumes[0].State" \
                --output text \
                --region "$AWS_REGION")"
            if [[ "$ATTACH_STATE" == "in-use" ]]; then
                break
            fi
            sleep 5
            ELAPSED=$((ELAPSED + 5))
        done

        if [[ "$ATTACH_STATE" != "in-use" ]]; then
            log_fail "Pool '$POOL_NAME': volume $VOLUME_ID did not reach in-use state after ${MAX_WAIT}s."
            return 1
        fi
        log_okay "Pool '$POOL_NAME': volume $VOLUME_ID is now in-use."
    fi

    # Step 6: Discover the actual block device name (NVMe devices differ from requested name)
    # Wait briefly for the device to appear in the OS
    sleep 3
    local DEVICE
    # Prefer device with the volume serial number embedded (NVMe pattern)
    local NVME_SERIAL
    NVME_SERIAL="$(echo "$VOLUME_ID" | tr -d '-')"
    DEVICE="$(lsblk -dnpo NAME,SERIAL 2>/dev/null | grep "$NVME_SERIAL" | awk '{print $1}' | head -1 || true)"

    if [[ -z "$DEVICE" ]]; then
        # Fall back: find the newest block device added (not the root disk)
        DEVICE="$(lsblk -dnpo NAME,TYPE | awk '$2=="disk"{print $1}' | \
            while read -r dev; do
                [[ "$(lsblk -no MOUNTPOINT "/dev/$dev" 2>/dev/null | head -1)" == "/" ]] && continue
                echo "/dev/$dev"
            done | head -1 || true)"
    fi

    if [[ -z "$DEVICE" ]]; then
        log_fail "Pool '$POOL_NAME': could not identify the attached block device for volume $VOLUME_ID."
        return 1
    fi

    log_info "Pool '$POOL_NAME': block device is $DEVICE"

    # Step 7: Format only if no filesystem exists (idempotent — preserves data on reattach)
    local FS_TYPE
    FS_TYPE="$(sudo blkid -o value -s TYPE "$DEVICE" 2>/dev/null || true)"

    # ext4 label max is 16 chars; use "lh-{name}" prefix to stay within limit
    local FS_LABEL="lh-${POOL_NAME}"

    if [[ -z "$FS_TYPE" ]]; then
        log_info "Pool '$POOL_NAME': no filesystem found on $DEVICE; formatting as ext4..."
        sudo mkfs.ext4 -L "$FS_LABEL" "$DEVICE" || return 1
        log_okay "Pool '$POOL_NAME': formatted $DEVICE as ext4 with label '$FS_LABEL'."
    else
        log_info "Pool '$POOL_NAME': filesystem '$FS_TYPE' already exists on $DEVICE; skipping format."
    fi

    # Step 8: Mount to disk_path (idempotent via fstab label)
    sudo mkdir -p "$DISK_PATH"

    local FSTAB_LABEL="LABEL=${FS_LABEL}"
    if ! grep -q "$FSTAB_LABEL" /etc/fstab; then
        echo "$FSTAB_LABEL $DISK_PATH ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null
        log_info "Pool '$POOL_NAME': added '$FSTAB_LABEL' to /etc/fstab."
    fi

    if ! mountpoint -q "$DISK_PATH"; then
        sudo mount -a || return 1
        log_okay "Pool '$POOL_NAME': mounted $DISK_PATH."
    else
        log_info "Pool '$POOL_NAME': $DISK_PATH already mounted."
    fi

    # Step 9: Register disk with Longhorn via node annotation (requires K3s API to be running)
    #
    # longhorn.io/default-disks-annotation is a node ANNOTATION (arbitrary JSON), not a label.
    # kubectl annotate is required — kubectl label rejects JSON values as invalid label syntax.
    #
    # We only attempt this if kubectl is accessible — it may not be on agent nodes.
    if sudo kubectl get nodes "$(hostname)" >/dev/null 2>&1; then
        local DISK_ANNOTATION
        DISK_ANNOTATION="{\"${DISK_PATH}\":{\"allowScheduling\":true,\"storageReserved\":0,\"tags\":[\"${POOL_NAME}\"]}}"
        sudo kubectl annotate node "$(hostname)" \
            "longhorn.io/default-disks-annotation=${DISK_ANNOTATION}" \
            --overwrite || {
            log_fail "Pool '$POOL_NAME': failed to set longhorn.io/default-disks-annotation on node '$(hostname)'."
            return 1
        }
        log_okay "Pool '$POOL_NAME': set longhorn.io/default-disks-annotation on node '$(hostname)'."
    else
        log_info "Pool '$POOL_NAME': kubectl not available on this node; skipping annotation."
        log_info "  Disk is mounted at '$DISK_PATH'. Register it in Longhorn UI after cluster formation:"
        log_info "  Node → Disks → Add Disk: path='$DISK_PATH', tags=['${POOL_NAME}']"
    fi

    log_okay "Pool '$POOL_NAME': disk setup complete."
}

########################################
#   Main: iterate over pools           #
########################################
POOL_COUNT="$(python3 -c "import json; data=json.load(open('$POOLS_CONFIG_FILE')); print(len(data))")"

if [[ "$POOL_COUNT" -eq 0 ]]; then
    log_info "No pools defined in Longhorn config; skipping."
    exit 0
fi

for i in $(seq 0 $((POOL_COUNT - 1))); do
    POOL_NAME="$(python3 -c "import json; d=json.load(open('$POOLS_CONFIG_FILE')); print(d[$i]['name'])")"
    SSM_PARAM="$(python3 -c "import json; d=json.load(open('$POOLS_CONFIG_FILE')); print(d[$i]['ebs_volumes_pstore_name'])")"
    DISK_PATH="$(python3 -c "import json; d=json.load(open('$POOLS_CONFIG_FILE')); print(d[$i]['disk_path'])")"
    NODE_TARGET="$(python3 -c "import json; d=json.load(open('$POOLS_CONFIG_FILE')); print(d[$i]['node_target'])")"

    setup_pool_disk "$POOL_NAME" "$SSM_PARAM" "$DISK_PATH" "$NODE_TARGET" || {
        log_fail "Pool '$POOL_NAME': disk setup failed."
        exit 1
    }
done

log_okay "$0: COMPLETED"
