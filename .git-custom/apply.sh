#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(realpath "$(dirname "$0")")"
cd "$SCRIPT_DIR" || exit

# Copy over the hooks/ folder to .git/hooks/
cp -R "$SCRIPT_DIR/hooks/" "$SCRIPT_DIR/../.git/"
