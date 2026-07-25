#!/bin/bash

# Get TFVAR filepaths
function get_tfvar_filepath() {
    # VARIABLES
    local _SCRIPT_DIR _IAC_MODULE
    local _REPO_ROOT _MODULE_DIR
    local _OUTPUT
    # INPUTS
    _SCRIPT_DIR="$1"
    _IAC_MODULE="$2"
    # PROCESS
    _REPO_ROOT="$(cd "${_SCRIPT_DIR}/.." && pwd)"
    _MODULE_DIR="${_REPO_ROOT}/terraform/${_IAC_MODULE}"
    _OUTPUT="${_MODULE_DIR}/terraform.tfvars"
    # VERIFY
    if [[ ! -d "${_MODULE_DIR}" ]]; then
        echo "Error: no terraform module '${_IAC_MODULE}' at ${_MODULE_DIR}." >&2
        return 1
    fi
    # OUTPUT VALUES
    printf '%s\n' "${_OUTPUT}"
}

# Get the node script directory (that is found within the cluster)
function get_node_script_dir() {
    # HARDCODED: This is a convention for SimpleK3s (Points to SimpleK3s bootstrap dir)
    echo "/opt/simplek3s/bootstrap/default"
}

# Infer a TFVAR value (takes the tfvars filepath and the variable name)
function infer_tfvar() {
    # VARIABLES
    local _VARIABLE _TFVARS
    # INPUTS
    _TFVARS="$1"
    _VARIABLE="$2"
    # VERIFY
    if [[ ! -f "${_TFVARS}" ]]; then
        echo "Error: ${_TFVARS} does not exist." >&2
        echo "       Create it from $(dirname "${_TFVARS}")/terraform.TEMPLATE.tfvars" >&2
        echo "       (see README 'First Time Setup')," >&2
        echo "       or pass the nickname and region as arguments." >&2
        return 1
    fi
    # OUTPUT VALUES
    grep -m1 "^${_VARIABLE}[[:space:]]*=" "${_TFVARS}" \
        | awk -F'"' '{print $2}' || true
}
