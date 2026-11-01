#!/bin/bash
# Exact PID/PPID native-probe fixture; the production cleanup still sends signals.
set -euo pipefail
PROJECT_ROOT="$1"
fixture="$2"
source "$PROJECT_ROOT/lib/core/test_boundary.sh"
[[ -n "${MOLE_TEST_SANDBOX_ACTIVE:-}" && "$MOLE_TEST_SANDBOX_ACTIVE" == "${MOLE_TEST_BOUNDARY_TOKEN:-}" ]] || exit 16
_mole_test_guard_mutation_path "$fixture/bin/sleep" || exit $?
mkdir -p "$fixture/bin"
export MOLE_WATCHDOG_TRACE="$fixture/sleep.pid"
cat > "$fixture/bin/sleep" << 'SH'
#!/bin/bash
[[ "$#" -eq 1 && "$1" == 287 ]] || exit 2
printf '%s %s\n' "$$" "$PPID" > "$MOLE_WATCHDOG_TRACE"
exec /bin/sleep "$@"
SH
cat > "$fixture/bin/pgrep" << 'SH'
#!/bin/bash
[[ "$#" -eq 2 && "$1" == -P ]] || exit 2
read -r child_pid parent_pid < "$MOLE_WATCHDOG_TRACE" || exit 2
[[ "$2" == "$parent_pid" ]] || exit 2
kill -0 "$child_pid" 2> /dev/null || exit 2
printf '%s\n' "$child_pid"
SH
chmod +x "$fixture/bin/sleep" "$fixture/bin/pgrep"
export PATH="$fixture/bin:$PATH"
source "$PROJECT_ROOT/lib/core/timeout.sh"
MO_TIMEOUT_BIN=""
MO_TIMEOUT_PERL_BIN=""
# Require a live watchdog before the otherwise-successful command completes.
# shellcheck disable=SC2016  # Inner shell reads its inherited exact trace path.
run_with_timeout 287 /bin/bash -c '
    for _ in {1..100}; do
        [[ -s "$MOLE_WATCHDOG_TRACE" ]] && exit 0
        /bin/sleep .02
    done
    exit 3
'
read -r child_pid parent_pid < "$MOLE_WATCHDOG_TRACE"
until=$((SECONDS + 3))
while kill -0 "$child_pid" 2> /dev/null; do
    if [[ $SECONDS -ge $until ]]; then
        kill -TERM "$child_pid" 2> /dev/null || true
        printf 'WATCHDOG_CLEANUP=failed ACTUAL_PID=%s ACTUAL_PPID=%s\n' "$child_pid" "$parent_pid" >&2
        exit 1
    fi
    /bin/sleep .05
done
probe_rc=0
pgrep -x sleep || probe_rc=$?
[[ $probe_rc -eq 2 ]] || exit 1
printf 'WATCHDOG_CLEANUP=production-kill ACTUAL_PID=%s ACTUAL_PPID=%s CHILD=gone UNKNOWN_ARGS=2\n' "$child_pid" "$parent_pid"
