#!/bin/bash

# Set bash flags 
set -euo pipefail 
# -u            : Error if an unset variable is referenced 
# -e            : Exits on ANY command failure 
# -o pipefail   : Make pipeline fail if any command in them fails 

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Retrieve the common functions from common.sh (Calls upon simplek3s.env file)
source "$SCRIPT_DIR/lib/common.sh"

function wait_kyverno() {
    local NS="kyverno"

    log_info "Waiting for namespace '$NS' to be present..."
    wait_for_cmd_3min sudo kubectl get ns "$NS" || {
        log_fail "namespace '$NS' never appeared"
        return 1
    }

    # Wait for the key deployments (names match current Kyverno chart defaults)
    local deploys=(
        "kyverno-admission-controller"
        "kyverno-background-controller"
        "kyverno-cleanup-controller"
    )

    for d in "${deploys[@]}"; do
        log_info "Waiting for deployment '$d' to be present..."
        wait_for_cmd_3min sudo kubectl -n "$NS" get deploy "$d" || {
            log_fail "deployment '$d' never appeared in namespace '$NS'"
            sudo kubectl -n "$NS" get all || true
            return 1
        }

        log_info "Waiting for deployment '$d' to be ready..."
        wait_for_cmd_1min sudo kubectl -n "$NS" rollout status "deploy/$d" --timeout=10s || {
            log_fail "deployment '$d' not ready"
            sudo kubectl -n "$NS" describe deploy "$d" || true
            sudo kubectl -n "$NS" get pods -o wide || true
            return 1
        }
    done

    # Wait for Kyverno CRDs (so policies can be created)
    log_info "Waiting for Kyverno CRDs..."
    wait_for_cmd_3min bash -c \
      "sudo kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1 && sudo kubectl get crd policies.kyverno.io >/dev/null 2>&1" || {
        log_fail "Kyverno CRDs not ready"
        sudo kubectl get crd | grep kyverno || true
        return 1
    }

    log_okay "Kyverno is ready (controllers + CRDs + baseline policies present)."
}

function apply_kyverno() {
    log_info "Writing Kyverno manifest"

    # Make sure the manifests directory exists
    log_info "Make sure that '$K3S_MANIFEST_DIR/' is initialized"
    sudo mkdir -p "$K3S_MANIFEST_DIR/" || return 1
    log_okay "Confirmed that '$K3S_MANIFEST_DIR/' has been initialized"

    # Transfer the Kyverno file to the /var/lib/rancher/k3s/server/manifests/ folder
    KYVERNO_PENDING_FILEPATH="$SCRIPT_DIR/manifests/kyverno.yaml"
    KYVERNO_MANIFEST_FILEPATH="$K3S_MANIFEST_DIR/kyverno.yaml"
    log_info "Apply Kyverno to $KYVERNO_MANIFEST_FILEPATH"
    sudo cp "$KYVERNO_PENDING_FILEPATH" "$KYVERNO_MANIFEST_FILEPATH" || return 1
    log_okay "Kyverno written to $KYVERNO_MANIFEST_FILEPATH"

    log_okay "Wrote Kyverno manifest"
}

function apply_kyverno_policies() {
    log_info "Writing Kyverno (baseline-policies) manifest"

    # Make sure the manifests directory exists
    log_info "Make sure that '$K3S_MANIFEST_DIR/' is initialized"
    sudo mkdir -p "$K3S_MANIFEST_DIR/" || return 1
    log_okay "Confirmed that '$K3S_MANIFEST_DIR/' has been initialized"

    # Transfer the Kyverno (baseline-policies) file to the /var/lib/rancher/k3s/server/manifests/ folder
    KYVERNO_PENDING_FILEPATH="$SCRIPT_DIR/manifests/kyverno-baseline-policies.yaml"
    KYVERNO_MANIFEST_FILEPATH="$K3S_MANIFEST_DIR/kyverno-baseline-policies.yaml"
    log_info "Apply Kyverno (baseline-policies) to $KYVERNO_MANIFEST_FILEPATH"
    sudo cp "$KYVERNO_PENDING_FILEPATH" "$KYVERNO_MANIFEST_FILEPATH" || return 1
    log_okay "Kyverno (baseline-policies) written to $KYVERNO_MANIFEST_FILEPATH"

    log_okay "Wrote Kyverno (baseline-policies) manifest"
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

apply_kyverno || {
    log_fail "Failed to apply Kyverno"
    exit 1
}

apply_kyverno_policies || {
    log_fail "Failed to apply Kyverno"
    exit 1
}

wait_kyverno || {
    log_fail "Unable to confirm that Kyverno is ready"
    exit 1
}

log_okay "$0: COMPLETED"
