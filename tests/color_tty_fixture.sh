#!/bin/bash
# Fixture for tests/no_color.bats.
#
# Sources lib/core/base.sh and prints the green/reset pair between markers, so
# the bats caller can assert whether ANSI escapes were emitted. Run under a pty
# by tests/support/tty_fixture.py, stdout is the exact owned terminal endpoint.
#
# Args: PROJECT_ROOT

set -euo pipefail

PROJECT_ROOT="$1"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/core/base.sh"
printf 'COLOR[%s]\n' "${GREEN}x${NC}"
