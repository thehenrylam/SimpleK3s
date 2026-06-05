#!/bin/bash
# Performs a general check on the shell scripts that is inside this project

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

find "${REPO_ROOT}" -name "*.sh" -not -path "${REPO_ROOT}/_tmp/*" -print0 | xargs -0 shellcheck -x -S warning
