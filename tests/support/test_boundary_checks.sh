#!/bin/bash
# Private-fixture checks, also runnable before the existing Shell suite.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$PROJECT_ROOT/lib/core/common.sh"
[[ -n "${MOLE_TEST_RUN_ROOT:-}" ]] || exit 16
fixture=$(mktemp -d "${TMPDIR%/}/boundary-check.XXXXXX")
mkdir -p "$fixture/allowed" "$fixture/denied/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/old"
allowed="$fixture/allowed"
denied="$fixture/denied/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/old/sentinel"
printf kept > "$denied"
printf removable > "$allowed/removable"

# Positive control: exercise the real non-sudo safe_remove sink on a fixture.
safe_remove "$allowed/removable" true 0 || exit $?
[[ ! -e "$allowed/removable" ]] || exit 1
printf 'FIXTURE_REAL_REMOVE=ok\n'

timeout_rc=0
run_with_timeout 2 /bin/sleep 30 || timeout_rc=$?
[[ $timeout_rc -eq 124 ]] || exit 1
printf 'OWN_TIMEOUT_CHILD_RC=%s\n' "$timeout_rc"

printf '%s\n' "$MOLE_TEST_BOUNDARY_TOKEN" > "$allowed/.test-boundary"
boundary_rc=0
MOLE_TEST_RUN_ROOT="$allowed" safe_remove "$denied" true 0 || boundary_rc=$?
[[ $boundary_rc -eq 16 && -f "$denied" ]] || exit 1
printf 'NON_SUDO_ESCAPE_RC=%s SENTINEL=kept\n' "$boundary_rc"

missing_rc=0
# shellcheck disable=SC2016 # Child shell expands its positional arguments.
env -u MOLE_TEST_RUN_ROOT -u MOLE_TEST_BOUNDARY_TOKEN /bin/bash -c '
    source "$1/lib/core/common.sh" || exit $?
    safe_remove "$2" true 0
' _ "$PROJECT_ROOT" "$denied" || missing_rc=$?
[[ $missing_rc -eq 16 && -f "$denied" ]] || exit 1
printf 'MISSING_BOUNDARY_RC=%s SENTINEL=kept\n' "$missing_rc"

# The missing-context rejection precedes temporary-root and logging setup.
# These homes are still private, and allowed by the outer kernel sandbox, so
# survival cannot pass merely because the kernel happened to block a write.
for module in common base log file_ops; do
    init_rc=0
    # shellcheck disable=SC2016 # Child shell expands its positional arguments.
    env -u MOLE_TEST_RUN_ROOT -u MOLE_TEST_BOUNDARY_TOKEN \
        -u MOLE_RESOLVED_TMPDIR -u MOLE_TEMP_REGISTRY_FILE \
        HOME="$fixture/forbidden-$module-home" TMPDIR="$fixture/forbidden-$module-tmp" \
        /bin/bash -c '
            rc=0
            source "$1/lib/core/$2.sh" || rc=$?
            case "$2" in
                common) loaded=${MOLE_COMMON_LOADED:-unset} ;;
                base) loaded=${MOLE_BASE_LOADED:-unset} ;;
                log) loaded=${MOLE_LOG_LOADED:-unset} ;;
                file_ops) loaded=${MOLE_FILE_OPS_LOADED:-unset} ;;
            esac
            printf "OR_CALLER_%s_RC=%s LOADED=%s\n" "$2" "$rc" "$loaded"
            [[ $rc -eq 16 && "$loaded" == unset ]] || exit 1
            exit "$rc"
        ' \
        _ "$PROJECT_ROOT" "$module" || init_rc=$?
    [[ $init_rc -eq 16 && ! -e "$fixture/forbidden-$module-home" &&
        ! -e "$fixture/forbidden-$module-tmp" ]] || exit 1
    printf 'EARLY_%s_RC=%s NO_HOME_OR_TMP_WRITES=yes\n' "$module" "$init_rc"
done

ln -s "$fixture/denied" "$allowed/escape"
symlink_rc=0
MOLE_TEST_RUN_ROOT="$allowed" _mole_test_guard_mutation_path \
    "$allowed/escape/Applications" || symlink_rc=$?
[[ $symlink_rc -eq 16 && -f "$denied" ]] || exit 1
printf 'SYMLINK_ANCESTOR_RC=%s\n' "$symlink_rc"

# Kernel negative control: the wrapper parent created this private sentinel
# before applying the sandbox. Absolute rm bypasses all PATH and helper mocks.
# Applying another sandbox inside an existing sandbox is not our proof.
[[ -f "${MOLE_TEST_KERNEL_SENTINEL:-}" ]] || exit 1
kernel_rc=0
/bin/rm -rf "$MOLE_TEST_KERNEL_SENTINEL" || kernel_rc=$? # SAFE: refusal probe targets only the wrapper's private sentinel
[[ $kernel_rc -ne 0 && -f "$MOLE_TEST_KERNEL_SENTINEL" ]] || exit 1
printf 'ABSOLUTE_RM_DENIED_RC=%s SENTINEL=kept\n' "$kernel_rc"

printf 'BOUNDARY_CHECKS=passed\n'
