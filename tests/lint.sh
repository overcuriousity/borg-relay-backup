#!/bin/bash
# Lint every shell file in the repo.
set -euo pipefail
cd "$(dirname "$0")/.."
mapfile -t files < <(ls install.sh bin/* lib/*.sh wizard/*.sh hooks/* tests/fake-rsh tests/stubs/* tests/lint.sh 2>/dev/null)
shellcheck -x -P SCRIPTDIR "${files[@]}"
echo "shellcheck: ${#files[@]} files ok"
