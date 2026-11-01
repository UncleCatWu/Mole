#!/bin/bash

set -uo pipefail

PROJECT_ROOT="$1"
CHILD_PID_FILE="$2"
PERL_PID_FILE="$3"
source "$PROJECT_ROOT/lib/core/test_boundary.sh"
[[ -n "${MOLE_TEST_SANDBOX_ACTIVE:-}" && "$MOLE_TEST_SANDBOX_ACTIVE" == "${MOLE_TEST_BOUNDARY_TOKEN:-}" ]] || exit 16
_mole_test_guard_mutation_path "$PERL_PID_FILE" || exit $?
_mole_test_guard_mutation_path "$CHILD_PID_FILE" || exit $?

# shellcheck source=lib/core/timeout.sh
source "$PROJECT_ROOT/lib/core/timeout.sh"

MO_TIMEOUT_BIN=""
MO_TIMEOUT_PERL_BIN="${PERL_PID_FILE}.launcher"
cat > "$MO_TIMEOUT_PERL_BIN" << 'SH'
#!/bin/bash
printf '%s %s\n' "$$" "$PPID" > "$MOLE_PERL_PID_FILE"
exec /usr/bin/perl "$@"
SH
chmod +x "$MO_TIMEOUT_PERL_BIN"
export MOLE_PERL_PID_FILE="$PERL_PID_FILE"

# shellcheck disable=SC2016  # The inner bash expands $$ and $1.
run_with_timeout 30 /bin/bash --noprofile --norc -c '
    printf "%s %s\n" "$$" "$PPID" > "$1"
    while :; do
        /bin/sleep 1
    done
' timeout-child "$CHILD_PID_FILE"
