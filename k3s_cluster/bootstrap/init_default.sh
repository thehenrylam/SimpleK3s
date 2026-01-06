#!/bin/bash

# Set bash flags 
set -euo pipefail 
# -u            : Error if an unset variable is referenced 
# -e            : Exits on ANY command failure 
# -o pipefail   : Make pipeline fail if any command in them fails 

# Expected Script Directory: <root_dir>/bootstrap/
# Expected Surrounding Directory:
#   - <root_dir>/bootstrap/default/
#   - <root_dir>/bootstrap/custom/
SCRIPT_DIR=$(dirname $0)
cd $SCRIPT_DIR

LOG_FILE="./init_default.log"

# Retrieve all of the needed environment variables from this file
source ./simplek3s.env "$LOG_FILE"

# Execute the initialization scripts for the default scripts
log_info "[$0] EXECUTE $SCRIPT_DIR/default/init_swapfile.sh!"
$SCRIPT_DIR/default/init_swapfile.sh

log_info "[$0] EXECUTE $SCRIPT_DIR/default/init_k3s.sh"
$SCRIPT_DIR/default/init_k3s.sh

