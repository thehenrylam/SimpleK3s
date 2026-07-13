#!/bin/bash

# Set bash flags
set -euo pipefail
# -u            : Error if an unset variable is referenced
# -e            : Exits on ANY command failure
# -o pipefail   : Make pipeline fail if any command in them fails

# Node-local storage pool preparation.
# For every pool (longhorn_pools_config.json) that targets this node type:
# attach the pool's per-AZ EBS volume, format it (first boot only), and mount
# it at the pool's disk path. Purely OS/cloud-level — no Kubernetes access.
# Registering the disks with Longhorn happens later, cluster-side:
# bts_05_stage_manifests.sh sets the node annotations (node 0) and
# converge_actions.sh reconciles them into nodes.longhorn.io.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Retrieve the common functions from common.sh (Calls upon simplek3s.env file)
# shellcheck source=k3s_cluster/cluster_app/bootstrap/data/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# Retrieve the AWS specific functions from aws.sh (IMDS, SSM and EBS helpers)
# shellcheck source=k3s_cluster/cluster_app/bootstrap/data/lib/providers/aws.sh
source "$SCRIPT_DIR/lib/providers/aws.sh"

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

# Device names requested at attach time, one letter per pool index
# (/dev/sdh, /dev/sdi, ...). NVMe instance types rename these anyway; the real
# device is discovered afterwards via the volume serial.
DEVICE_LETTERS="hijklmnop"

# Emits one pool per line as tab-separated fields:
# index, name, ebs_volumes_pstore_name, disk_path, node_target
function list_pools() {
    python3 - "$POOLS_CONFIG_FILE" <<'PYEOF'
import json
import sys

with open(sys.argv[1]) as f:
    pools = json.load(f)

for i, pool in enumerate(pools):
    print("\t".join([
        str(i),
        pool["name"],
        pool["ebs_volumes_pstore_name"],
        pool["disk_path"],
        pool["node_target"],
    ]))
PYEOF
}

# Prints the pool's EBS volume ID for this node's AZ.
# (Value-returning: no logging here — the caller logs around it.)
function resolve_pool_volume() {
    local ssm_param="$1"
    local az="$2"

    # The pool's SSM parameter holds a JSON list of volume IDs (one per AZ)
    local volume_ids_json
    volume_ids_json="$(get_ssm_raw "$ssm_param")" || return 1

    local volume_ids
    volume_ids="$(echo "$volume_ids_json" | python3 -c "import json,sys; print(' '.join(json.load(sys.stdin)))")" || return 1

    local volume_id
    # shellcheck disable=SC2086 # volume_ids is a space-separated list by design
    volume_id="$(ec2_find_volume_in_az "$az" $volume_ids)" || return 1
    [[ -n "$volume_id" && "$volume_id" != "None" ]] || return 1

    echo "$volume_id"
}

# Attach the volume to this instance (idempotent — handles already-attached)
function ensure_pool_volume_attached() {
    local pool_name="$1"
    local volume_id="$2"
    local instance_id="$3"
    local device_name="$4"

    local attach_state
    attach_state="$(ec2_volume_state "$volume_id")" || return 1

    if [[ "$attach_state" == "in-use" ]]; then
        local attached_to
        attached_to="$(ec2_volume_attached_instance "$volume_id")" || return 1
        if [[ "$attached_to" == "$instance_id" ]]; then
            log_info "Pool '$pool_name': volume $volume_id already attached to this instance."
            return 0
        fi
        log_fail "Pool '$pool_name': volume $volume_id is attached to a different instance ($attached_to)."
        return 1
    fi

    log_info "Pool '$pool_name': attaching volume $volume_id to instance $instance_id at $device_name..."
    ec2_attach_volume "$volume_id" "$instance_id" "$device_name" || return 1

    log_info "Pool '$pool_name': waiting for volume $volume_id to be in-use..."
    wait_for_cmd 12 5 ec2_volume_in_use "$volume_id" || {
        log_fail "Pool '$pool_name': volume $volume_id did not reach in-use state in time."
        return 1
    }
    log_okay "Pool '$pool_name': volume $volume_id is now in-use."
}

# Full disk setup for one pool: resolve volume -> attach -> format -> mount
function setup_pool_disk() {
    local pool_name="$1"
    local ssm_param="$2"
    local disk_path="$3"
    local device_name="$4"

    log_info "Pool '$pool_name': setting up EBS disk at '$disk_path'"

    local volume_id
    volume_id="$(resolve_pool_volume "$ssm_param" "$AZ")" || {
        log_fail "Pool '$pool_name': no EBS volume for AZ '$AZ' resolvable from SSM parameter '$ssm_param'."
        return 1
    }
    log_info "Pool '$pool_name': matched volume $volume_id in AZ $AZ"

    ensure_pool_volume_attached "$pool_name" "$volume_id" "$INSTANCE_ID" "$device_name" || return 1

    log_info "Pool '$pool_name': waiting for the block device of $volume_id to appear..."
    wait_for_cmd_1min find_block_device_for_volume "$volume_id" || {
        log_fail "Pool '$pool_name': block device for volume $volume_id never appeared."
        return 1
    }
    local device
    device="$(find_block_device_for_volume "$volume_id")" || return 1
    log_info "Pool '$pool_name': block device is $device"

    # ext4 label max is 16 chars; use "lh-{name}" prefix to stay within limit
    local fs_label="lh-${pool_name}"
    ensure_fs_ext4 "$device" "$fs_label" || return 1
    ensure_labeled_mount "$fs_label" "$disk_path" || return 1

    log_okay "Pool '$pool_name': disk setup complete."
}


log_info "$0: LAUNCHED — setting up storage pool disks for node type '$CLUSTER_TYPE'"

# Instance identity is per-node, not per-pool: fetch it once
INSTANCE_ID="$(get_ec2_instance_id)" || {
    log_fail "Could not determine the EC2 instance ID via IMDS"
    exit 1
}
AZ="$(get_ec2_az)" || {
    log_fail "Could not determine the EC2 availability zone via IMDS"
    exit 1
}
log_info "Instance=$INSTANCE_ID, AZ=$AZ"

while IFS=$'\t' read -r POOL_INDEX POOL_NAME SSM_PARAM DISK_PATH NODE_TARGET; do
    [[ -z "$POOL_INDEX" ]] && continue

    # Only process pools that target this node type (or "all")
    if [[ "$NODE_TARGET" != "all" && "$NODE_TARGET" != "$CLUSTER_TYPE" ]]; then
        log_info "Pool '$POOL_NAME': node_target='$NODE_TARGET' does not match cluster_type='$CLUSTER_TYPE'; skipping."
        continue
    fi

    if [[ "$POOL_INDEX" -ge "${#DEVICE_LETTERS}" ]]; then
        log_fail "Pool '$POOL_NAME': pool index $POOL_INDEX exceeds the available device names."
        exit 1
    fi
    DEVICE_NAME="/dev/sd${DEVICE_LETTERS:$POOL_INDEX:1}"

    setup_pool_disk "$POOL_NAME" "$SSM_PARAM" "$DISK_PATH" "$DEVICE_NAME" || {
        log_fail "Pool '$POOL_NAME': disk setup failed."
        exit 1
    }
done < <(list_pools)

log_okay "$0: COMPLETED"
