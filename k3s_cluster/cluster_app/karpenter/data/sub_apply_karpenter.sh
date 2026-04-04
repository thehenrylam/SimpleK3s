#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

function copy_manifest() {
    local src="$1"
    local dst="$2"

    log_info "Ensure '$K3S_MANIFEST_DIR/' exists"
    sudo mkdir -p "$K3S_MANIFEST_DIR/" || return 1

    log_info "Copy manifest: $src -> $dst"
    sudo cp "$src" "$dst" || return 1
}

function wait_karpenter_crds() {
    log_info "Waiting for Karpenter CRDs to exist..."
    wait_for_cmd_3min sudo kubectl get crd ec2nodeclasses.karpenter.k8s.aws || {
        log_fail "CRD ec2nodeclasses.karpenter.k8s.aws never appeared"
        return 1
    }
    wait_for_cmd_3min sudo kubectl get crd nodepools.karpenter.sh || {
        log_fail "CRD nodepools.karpenter.sh never appeared"
        return 1
    }
    wait_for_cmd_3min sudo kubectl get crd nodeclaims.karpenter.sh || {
        log_fail "CRD nodeclaims.karpenter.sh never appeared"
        return 1
    }
    log_okay "Karpenter CRDs are present"
}

function wait_karpenter_api() {
    log_info "Waiting for Karpenter API endpoints to be ready..."
    wait_for_cmd_3min sudo kubectl get ec2nodeclasses.karpenter.k8s.aws || {
        log_fail "API endpoint ec2nodeclasses.karpenter.k8s.aws never became ready"
        return 1
    }
    wait_for_cmd_3min sudo kubectl get nodepools.karpenter.sh || {
        log_fail "API endpoint nodepools.karpenter.sh never became ready"
        return 1
    }
    wait_for_cmd_3min sudo kubectl get nodeclaims.karpenter.sh || {
        log_fail "API endpoint nodeclaims.karpenter.sh never became ready"
        return 1
    }
    log_okay "Karpenter API endpoints are ready"
}

function wait_karpenter_controller() {
    local NS="kube-system"
    local DEPLOY_NAME="karpenter"

    log_info "Waiting for deployment '$DEPLOY_NAME' to exist..."
    wait_for_cmd_3min sudo kubectl -n "$NS" get deploy "$DEPLOY_NAME" || {
        log_fail "deployment '$DEPLOY_NAME' never appeared in namespace '$NS'"
        sudo kubectl -n "$NS" get all || true
        return 1
    }

    log_info "Waiting for deployment '$DEPLOY_NAME' to be ready..."
    wait_for_cmd_3min sudo kubectl -n "$NS" rollout status "deploy/$DEPLOY_NAME" --timeout=10s || {
        log_fail "deployment '$DEPLOY_NAME' did not become ready"
        sudo kubectl -n "$NS" describe deploy "$DEPLOY_NAME" || true
        sudo kubectl -n "$NS" get pods -o wide || true
        return 1
    }

    log_okay "Karpenter controller is ready"
}

function apply_karpenter() {
    copy_manifest \
        "$SCRIPT_DIR/manifests/karpenter-crd-helmchart.yaml" \
        "$K3S_MANIFEST_DIR/karpenter-crd-helmchart.yaml" || return 1

    wait_karpenter_crds || return 1
    wait_karpenter_api || return 1

    copy_manifest \
        "$SCRIPT_DIR/manifests/karpenter-helmchart.yaml" \
        "$K3S_MANIFEST_DIR/karpenter-helmchart.yaml" || return 1

    wait_karpenter_controller || return 1

    copy_manifest \
        "$SCRIPT_DIR/manifests/karpenter-nodeclass.yaml" \
        "$K3S_MANIFEST_DIR/karpenter-nodeclass.yaml" || return 1

    copy_manifest \
        "$SCRIPT_DIR/manifests/karpenter-nodepool.yaml" \
        "$K3S_MANIFEST_DIR/karpenter-nodepool.yaml" || return 1

    log_okay "Karpenter manifests copied"
}

log_info "$0: LAUNCHED"

wait_for_k3s_api || {
    log_fail "Unable to confirm that K3s API is ready"
    exit 1
}

wait_for_kubesystem || {
    log_fail "Unable to confirm that kube-system is ready"
    exit 1
}

apply_karpenter || {
    log_fail "Failed to apply Karpenter"
    exit 1
}

log_okay "$0: COMPLETED"
