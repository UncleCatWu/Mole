#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
}

@test "test boundary allows fixture removal and rejects non-sudo and absolute-rm escapes" {
    run /bin/bash "$PROJECT_ROOT/tests/support/test_boundary_checks.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"FIXTURE_REAL_REMOVE=ok"* ]] || return 1
    [[ "$output" == *"OWN_TIMEOUT_CHILD_RC=124"* ]] || return 1
    [[ "$output" == *"NON_SUDO_ESCAPE_RC=16 SENTINEL=kept"* ]] || return 1
    [[ "$output" == *"MISSING_BOUNDARY_RC=16 SENTINEL=kept"* ]] || return 1
    [[ "$output" == *"EARLY_common_RC=16 NO_HOME_OR_TMP_WRITES=yes"* ]] || return 1
    [[ "$output" == *"EARLY_base_RC=16 NO_HOME_OR_TMP_WRITES=yes"* ]] || return 1
    [[ "$output" == *"EARLY_log_RC=16 NO_HOME_OR_TMP_WRITES=yes"* ]] || return 1
    [[ "$output" == *"EARLY_file_ops_RC=16 NO_HOME_OR_TMP_WRITES=yes"* ]] || return 1
    [[ "$output" == *"OR_CALLER_file_ops_RC=16 LOADED=unset"* ]] || return 1
    [[ "$output" == *"OR_CALLER_common_RC=16 LOADED=unset"* ]] || return 1
    [[ "$output" == *"SYMLINK_ANCESTOR_RC=16"* ]] || return 1
    [[ "$output" == *"ABSOLUTE_RM_DENIED_RC="*"SENTINEL=kept"* ]] || return 1
    [[ "$output" == *"BOUNDARY_CHECKS=passed"* ]]
}

@test "test runner never sweeps previous test homes" {
    run /bin/bash -c '
        if grep -Eq -- "-mmin|tmp-.*-exec.*rm" "$1/scripts/test.sh"; then
            exit 1
        fi
        grep -Fq "exact mktemp-created root owned by this test invocation" "$1/scripts/test_sandbox.sh"
    ' _ "$PROJECT_ROOT"
    [ "$status" -eq 0 ]
}

@test "CI Bats entrypoints use the test sandbox" {
    run /bin/bash -c '
        count=$(grep -c "scripts/test_sandbox.sh bats" "$1/.github/workflows/test.yml")
        [[ $count -eq 2 ]] || exit 1
        if grep -Eq "^[[:space:]]*(run: )?bats tests/" "$1/.github/workflows/test.yml"; then
            exit 1
        fi
    ' _ "$PROJECT_ROOT"
    [ "$status" -eq 0 ]
}

@test "test runner records a failure without errexit aborting its receipt" {
    run /bin/bash -euo pipefail -c '
        source "$1/lib/core/common.sh"
        eval "$(sed -n '\''/^report_unit_result() {/,/^}/p'\'' "$1/scripts/test.sh")"
        FAILED=0
        report_unit_result 1
        printf "FAILURE_RECEIPT=%s\n" "$FAILED"
        [[ $FAILED -eq 1 ]] || exit 1
    ' _ "$PROJECT_ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Unit tests failed"* ]] || return 1
    [[ "$output" == *"FAILURE_RECEIPT=1"* ]]
}

@test "test runner installation stage is read-only" {
    run /bin/bash -c '
        grep -Fq "Installation entry syntax passed (no installation performed)" "$1/scripts/test.sh" || exit 1
        if grep -Fq "./install.sh --prefix" "$1/scripts/test.sh"; then
            exit 1
        fi
    ' _ "$PROJECT_ROOT"
    [ "$status" -eq 0 ]
}

@test "Bats subprocess context requires the sandbox even without explicit test flags" {
    local forbidden_home="$BATS_TEST_TMPDIR/forgot-test-flags-home"
    # shellcheck disable=SC2016 # The child shell reads inherited Bats fields.
    run env -u MOLE_TEST_RUN_ROOT -u MOLE_TEST_BOUNDARY_TOKEN \
        -u MOLE_RESOLVED_TMPDIR -u MOLE_TEMP_REGISTRY_FILE \
        MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 HOME="$forbidden_home" \
        /bin/bash -c '
            printf "BATS_FILENAME=%s BATS_RUN_TMPDIR=%s\n" "${BATS_TEST_FILENAME:+present}" "${BATS_RUN_TMPDIR:+present}"
            rc=0
            source "$1/lib/core/common.sh" || rc=$?
            printf "SOURCE_RC=%s\n" "$rc"
            [[ $rc -eq 16 ]] || exit 1
        ' _ "$PROJECT_ROOT"
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"BATS_FILENAME=present BATS_RUN_TMPDIR=present"* ]] || return 1
    [[ "$output" == *"SOURCE_RC=16"* ]] || return 1
    [ ! -e "$forbidden_home" ]
}

@test "Go cache preflight delegates the probe to the kernel launcher before HOME changes" {
    local fixture
    fixture=$(mktemp -d "$BATS_TEST_TMPDIR/go-preflight.XXXXXX")
    run python3 - "$PROJECT_ROOT" "$fixture" <<'PYTEST'
from pathlib import Path
import os
import re
import subprocess
import sys

repo, fixture = map(Path, sys.argv[1:])
source = (repo / 'scripts/test_sandbox.sh').read_text()
assignment = re.search(r'    original_module_cache=\$\(.*?go env GOMODCACHE\)', source, re.S)
assert assignment, 'preflight extraction matched no production site'
user_home = fixture / 'original-home'
run_root = fixture / 'private-run'
provider_dir = fixture / 'provider'
for path in (user_home, run_root / 'tmp', run_root / 'go-cache', provider_dir):
    path.mkdir(parents=True)
provider = provider_dir / 'go'
provider.write_text('''#!/bin/bash
[[ "$*" == 'env GOMODCACHE' && "${PREFLIGHT_LAUNCHER_VERIFIED:-}" == yes ]] || exit 9
[[ "$GOTELEMETRY" == off && "$GOPROXY" == off && "$GOTOOLCHAIN" == local ]] || exit 7
printf private-scratch > "$TMPDIR/allowed" || exit 5
printf private-cache > "$GOCACHE/allowed" || exit 6
printf '%s/go/pkg/mod\\n' "$HOME"
''')
provider.chmod(0o755)
# A sandboxed test cannot sandbox_apply again on macOS. This narrowly mocked
# launcher tests the exact production assignment and argument routing. Actual
# kernel write denial is verified by the suite's separate boundary sentinel.
probe = run_root / 'preflight.sh'
probe.write_text('''set -euo pipefail
run_root="$1"
/usr/bin/sandbox-exec() {
    [[ "$1" == -f && "$2" == "$run_root/policy.sb" && "$3" == /usr/bin/env ]] || return 10
    [[ "$4" == GOTELEMETRY=off && "$5" == GOPROXY=off && "$6" == GOTOOLCHAIN=local ]] || return 11
    [[ "$7" == "TMPDIR=$run_root/tmp/" && "$8" == "GOCACHE=$run_root/go-cache" ]] || return 12
    [[ "$9" == go && "${10}" == env && "${11}" == GOMODCACHE && $# -eq 11 ]] || return 13
    printf 'verified\n' > "$run_root/launcher.trace"
    shift 2
    PREFLIGHT_LAUNCHER_VERIFIED=yes "$@"
}
''' + assignment.group() +
                 '\n[[ "$original_module_cache" == "$HOME/go/pkg/mod" ]] || exit 8\n')
env = dict(os.environ, HOME=str(user_home), PATH=str(provider_dir) + ':/usr/bin:/bin')
result = subprocess.run(['/bin/bash', str(probe), str(run_root)], env=env,
                        capture_output=True, text=True, timeout=10)
assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
assert (run_root / 'launcher.trace').read_text() == 'verified\n'
assert (run_root / 'tmp/allowed').read_text() == 'private-scratch'
assert (run_root / 'go-cache/allowed').read_text() == 'private-cache'
control = subprocess.run([str(provider), 'env', 'GOMODCACHE'], env=env,
                         capture_output=True, text=True, timeout=5)
assert control.returncode == 9, 'unwrapped positive control was admitted'
print('PREFLIGHT_KERNEL_LAUNCH_CONTRACT=ok; PRIVATE_CACHE_AND_TMP=ok; ORIGINAL_CACHE=ok; UNWRAPPED_CONTROL_DENIED=ok')
PYTEST
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [[ "$output" == *"PREFLIGHT_KERNEL_LAUNCH_CONTRACT=ok; PRIVATE_CACHE_AND_TMP=ok; ORIGINAL_CACHE=ok; UNWRAPPED_CONTROL_DENIED=ok"* ]]
}
