#!/bin/bash

# Get TFVAR filepaths
function get_tfvar_filepath() {
    # VARIABLES
    local _SCRIPT_DIR _IAC_MODULE
    local _REPO_ROOT 
    local _OUTPUT 
    # INPUTS
    _SCRIPT_DIR="$1"
    _IAC_MODULE="$2"
    # PROCESS
    _REPO_ROOT="$(cd "${_SCRIPT_DIR}/.." && pwd)"
    _OUTPUT="$(cd "${_REPO_ROOT}/terraform/${_IAC_MODULE}" && pwd)/terraform.tfvars"
    # OUTPUT VALUES
    echo "${_OUTPUT}"
}

function get_node_script_dir() {
    # HARDCODED: This is a convention for SimpleK3s (Points to SimpleK3s bootstrap dir)
    echo "/opt/simplek3s/bootstrap/default/"
}

# Infer TFVAR values (takes in the variable as the input)
function infer_tfvar() {
    # VARIABLES
    local _VARIABLE _TFVARS
    # INPUTS
    _TFVARS="$1"
    _VARIABLE="$2"
    # OUTPUT VALUES
    grep "^${_VARIABLE}[[:space:]]*=" "${_TFVARS}" 2>/dev/null \
        | awk -F'"' '{print $2}' | head -1
}
