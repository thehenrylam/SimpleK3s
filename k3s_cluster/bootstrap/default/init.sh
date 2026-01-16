#!/bin/bash

# Set bash flags 
set -euo pipefail 
# -u            : Error if an unset variable is referenced 
# -e            : Exits on ANY command failure 
# -o pipefail   : Make pipeline fail if any command in them fails 

SCRIPT_PATH=$(realpath $(dirname $0))
cd $SCRIPT_PATH

LOG_FILE="${SCRIPT_PATH}/init_$(date +'%Y%m%d%H%M%S%3N').log"

# Retrieve all of the needed environment variables from this file
source $SCRIPT_PATH/simplek3s.env
# Retrieve the common functions from common.sh
source $SCRIPT_PATH/common.sh "$LOG_FILE"
# Retrieve the common functions from common_aws.sh
source $SCRIPT_PATH/common_aws.sh

# The index of the current node 
# If COUNT_INDEX == 0 then its a controller, 
# otherwise its a server node part of the HA control-plane)
COUNT_INDEX="$1"  

# Install the packages
$SCRIPT_PATH/01_install_packages.sh "$LOG_FILE" || exit 1

# Setup the swapfile
$SCRIPT_PATH/02_setup_swapfile.sh "$LOG_FILE" "$SWAPFILE_ALLOC_AMT" || exit 1

# Setup the k3s (if COUNT_INDEX == 0 then install as "controller", otherwise install as "server")
NODE_TYPE=$([ $COUNT_INDEX -eq 0 ] && echo "controller" || echo "server")
$SCRIPT_PATH/03_install_k3s.sh "$LOG_FILE" "$NODE_TYPE" || exit 1

# Execute additional scripts for the controller
if [[ "$COUNT_INDEX" -eq 0 ]]; then
    # Apply the configs of Traefik
    $SCRIPT_PATH/04_apply_traefik.sh "$LOG_FILE" || exit 1
fi


