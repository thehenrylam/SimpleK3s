#!/bin/bash

# Set bash flags 
set -euo pipefail 
# -u            : Error if an unset variable is referenced 
# -e            : Exits on ANY command failure 
# -o pipefail   : Make pipeline fail if any command in them fails 

# Expected directory    : <root_dir>/bootstrap/default/
# Expected utils script : <root_dir>/bootstrap/init_utils.sh
SCRIPT_DIR=$(dirname $0)
source $SCRIPT_DIR/../init_utils.sh

MANIFESTS_FOLDER="/var/lib/rancher/k3s/server/manifests"

$SCRIPT_DIR/init_k3s_m_traefik.sh "$MANIFESTS_FOLDER"
