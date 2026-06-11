#!/bin/bash

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly CURR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly VENV_NAME="venv"

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

# Set up the python3 venv
function python3_venv() {
    local PREV_DIR="$(pwd)"

    cd "${REPO_ROOT}"

    echo "[$(bld_cyn "STARTED")] Initialize the Python3 Virtual Env (${VENV_NAME})" 
    python3 -m venv "${VENV_NAME}" || {
        echo "[$(bld_red "FAILURE")] Initialize the Python3 Virtual Env (${VENV_NAME})" 
        exit 1
    }
    echo "[$(bld_grn "SUCCESS")] Initialize the Python3 Virtual Env (${VENV_NAME})" 
    echo "---------------------------------------------------"
    echo "$(bld_cyn "What it does"): Create a separate workspace to install Python3 modules without cluttering up your main machine"
    echo "$(bld_cyn "How to use it"):"
    echo "$(bld_cyn "1.") Go to the root directory of the repo"
    echo "$(bld_cyn "2.") source ./${VENV_NAME}/bin/activate $(comment "Go into the virtual env")" 
    echo "$(bld_cyn "3.") pip3 install cowsay $(comment "Example of installing an package within the virtual env")"
    echo "$(bld_cyn "4.") python3"
    printf ">>> import cowsay 
>>> cowsay.cow(\"Hello World\") 
  ___________ 
| Hello World | 
  =========== 
          \ 
            \ 
              ^__^ 
              (oo)\_______ 
              (__)\       )\/\ 
                  ||----w | 
                  ||     || 
>>> exit() \n"
    echo "$(bld_cyn "5.") deactivate $(comment "Exit out of the virtual env")"

    cd "${PREV_DIR}"
}

python3_venv
