#!/bin/bash

# Set bash flags 
set -euo pipefail 
# -u            : Error if an unset variable is referenced 
# -e            : Exits on ANY command failure 
# -o pipefail   : Make pipeline fail if any command in them fails 

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Retrieve the common functions from common.sh (Calls upon simplek3s.env file)
source "$SCRIPT_DIR/lib/common.sh"

function wait_descheduler() {
    local NS="kube-system"
    local CJ_NAME="descheduler"

    log_info "Waiting for Descheduler CronJob '$CJ_NAME' to exist..."
    wait_for_cmd_3min sudo kubectl -n "$NS" get cronjob "$CJ_NAME" || {
        log_fail "CronJob '$CJ_NAME' never appeared in namespace '$NS'"
        sudo kubectl -n "$NS" get cronjob || true
        return 1
    }

    # Create a one-off Job from the CronJob to prove it can run
    local JOB_NAME="descheduler-smoketest"

    log_info "Creating Descheduler smoketest job '$JOB_NAME'..."
    # Delete if it already exists (idempotent)
    sudo kubectl -n "$NS" delete job "$JOB_NAME" --ignore-not-found >/dev/null 2>&1 || true

    sudo kubectl -n "$NS" create job --from=cronjob/"$CJ_NAME" "$JOB_NAME" >/dev/null || {
        log_fail "Failed to create smoketest job from cronjob/$CJ_NAME"
        return 1
    }

    log_info "Waiting for Descheduler job '$JOB_NAME' to complete..."
    wait_for_cmd_3min sudo kubectl -n "$NS" wait --for=condition=complete "job/$JOB_NAME" --timeout=10s || {
        log_fail "Descheduler smoketest job did not complete"
        sudo kubectl -n "$NS" get pods -l job-name="$JOB_NAME" -o wide || true
        # show pod logs if we can find the pod
        local POD
        POD="$(sudo kubectl -n "$NS" get pods -l job-name="$JOB_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
        if [[ -n "$POD" ]]; then
            sudo kubectl -n "$NS" describe pod "$POD" || true
            sudo kubectl -n "$NS" logs "$POD" --tail=200 || true
        fi
        return 1
    }

    log_okay "Descheduler is ready (CronJob exists and a smoketest run completed)."
}

function apply_descheduler() {
    log_info "Writing Descheduler manifest"

    # Make sure the manifests directory exists
    log_info "Make sure that '$K3S_MANIFEST_DIR/' is initialized"
    sudo mkdir -p "$K3S_MANIFEST_DIR/" || return 1
    log_okay "Confirmed that '$K3S_MANIFEST_DIR/' has been initialized"

    # Transfer the Descheduler file to the /var/lib/rancher/k3s/server/manifests/ folder
    local PENDING_FILEPATH="$SCRIPT_DIR/manifests/descheduler.yaml"
    local MANIFEST_FILEPATH="$K3S_MANIFEST_DIR/descheduler.yaml"
    log_info "Apply Descheduler to $MANIFEST_FILEPATH"
    sudo cp "$PENDING_FILEPATH" "$MANIFEST_FILEPATH" || return 1
    log_okay "Descheduler written to $MANIFEST_FILEPATH"

    log_okay "Wrote Descheduler manifest"
}

log_info "$0: LAUNCHED"

wait_for_k3s_api || {
    log_fail "Unable to confirm that K3s API is ready"
    exit 1
}

wait_for_kubesystem || {
    log_fail "Unable to confirm that Kubesystem is ready"
    exit 1
}

apply_descheduler || {
    log_fail "Failed to apply Descheduler"
    exit 1
}

wait_descheduler || {
    log_fail "Unable to confirm that Descheduler is ready"
    exit 1
}

log_okay "$0: COMPLETED"
