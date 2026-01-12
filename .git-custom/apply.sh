#!/bin/bash

SCRIPT_DIR=$(realpath $(dirname $0))
cd $SCRIPT_DIR

# Copy over the hooks/ folder to .git/hooks/ 
cp -R $SCRIPT_DIR/hooks/ $SCRIPT_DIR/../.git/
