# shellcheck shell=bash
REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
export REPO_ROOT LC_ALL=C

# refute CMD... - fail the test if CMD succeeds (a bare `! cmd` never fails a bats test)
refute() { if "$@"; then return 1; fi; }
