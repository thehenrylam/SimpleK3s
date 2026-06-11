#!/bin/bash

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly CURR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly REQS_FILEPATH="${CURR_ROOT}/requirements.txt"

# --- COLOR FUNCTIONS ---
reset()     { printf '\033[0m';  }
# ---
reg_red()   { printf '\033[0;31m%b\033[0m' "$1"; }
reg_grn()   { printf '\033[0;32m%b\033[0m' "$1"; }
reg_cyn()   { printf '\033[0;36m%b\033[0m' "$1"; }
# ---
bld_red()   { printf '\033[1;31m%b\033[0m' "$1"; }
bld_grn()   { printf '\033[1;32m%b\033[0m' "$1"; }
bld_cyn()   { printf '\033[1;36m%b\033[0m' "$1"; }
# ---
comment()   { reg_grn "# $1"; }

function check_if_venv() {
    if [[ ! -z "${VIRTUAL_ENV// }" ]]; then 
        # If we're running on a virtual env, then return 0
        return 0
    fi 
    # BASECASE: if we don't return 0 by this point assume that something went wrong and return 1
    return 1
}

# Set up the python3 deps (i.e. Modules)
function python3_deps() {
    # Perform a check 
    check_if_venv || {
        echo "[$(bld_red "FAILURE")] The python3 virtual env has not been activated!\n"
        echo " - Please execute $(bld_cyn "${CURR_ROOT}/tc_python-venv_unix_install.sh") and follow its instructions to activate the virtual env before executing this script!" 
        exit 2
    }

    echo "[$(bld_cyn "STARTED")] Install Python3 requirements ($(reg_cyn "${REQS_FILEPATH}"))"

    pip3 install -r "${REQS_FILEPATH}" || {
        echo "[$(bld_cyn "FAILURE")] Install Python3 requirements ($(reg_cyn "${REQS_FILEPATH}"))"
        exit 1
    }

    echo "[$(bld_grn "SUCCESS")] Install Python3 requirements ($(reg_cyn "${REQS_FILEPATH}"))"
}

python3_deps
