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

@test "Nix smoke refuses a missing test boundary before inspecting the package" {
    run env -u MOLE_TEST_RUN_ROOT -u MOLE_TEST_BOUNDARY_TOKEN \
        python3 -B "$PROJECT_ROOT/scripts/test_nix_package.py" "$BATS_TEST_TMPDIR/missing-package"
    [ "$status" -eq 16 ] || { printf '%s\n' "$output"; return 1; }
    [[ "$output" == *"test boundary refused (missing-run-root)"* ]]
}

@test "Nix smoke menu uses the owned terminal and reaches update and quit input" {
    run python3 -B - "$PROJECT_ROOT" "$BATS_TEST_TMPDIR" <<'PYTEST'
from pathlib import Path
import importlib.util
import os
import pty
import sys
from unittest.mock import patch

repo, fixture = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location('nix_smoke', repo / 'scripts/test_nix_package.py')
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)
menu = fixture / 'nix-menu'
trace = fixture / 'nix-menu.trace'
menu.write_text('''#!''' + sys.executable + '''
import os, termios
saved = termios.tcgetattr(0)
raw = termios.tcgetattr(0)
raw[3] &= ~(termios.ECHO | termios.ICANON)
raw[6][termios.VMIN] = 1
raw[6][termios.VTIME] = 0
termios.tcsetattr(0, termios.TCSANOW, raw)
try:
    print('Q Quit', flush=True)
    while True:
        key = os.read(0, 1)
        with open(os.environ['NIX_MENU_TRACE'], 'ab') as log:
            log.write(key)
        if key == b'q':
            break
        if key == b'u':
            print('Q Quit', flush=True)
finally:
    termios.tcsetattr(0, termios.TCSANOW, saved)
''')
menu.chmod(0o755)
with patch.object(pty, 'openpty', side_effect=AssertionError('UNOWNED_NIX_MENU_PTY')):
    smoke.check_menu(menu, dict(os.environ, NIX_MENU_TRACE=str(trace)))
assert trace.read_bytes() == b'uq', trace.read_bytes()
print('NIX_MENU_OWNED_PTY=ok; UPDATE_AND_QUIT_REACHED=ok')
PYTEST
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [[ "$output" == *"NIX_MENU_OWNED_PTY=ok; UPDATE_AND_QUIT_REACHED=ok"* ]]
}

@test "Nix CI wraps installed-package and profile probes in the test boundary" {
    run python3 -B - "$PROJECT_ROOT" "$BATS_TEST_TMPDIR" <<'PYTEST'
from pathlib import Path
import os
import subprocess
import sys
import textwrap

repo, fixture = map(Path, sys.argv[1:])
workflow = (repo / '.github/workflows/nix.yml').read_text()
def run_block(name):
    section = workflow.split('      - name: ' + name + '\n')
    assert len(section) == 2, ('expected one production step', name)
    lines = section[1].split('      - name: ', 1)[0].splitlines()
    index = next(i for i, line in enumerate(lines) if line.strip().startswith('run:'))
    value = lines[index].strip()[4:].strip()
    return textwrap.dedent('\n'.join(lines[index + 1:])) if value == '|' else value

provider = fixture / 'provider'
snapshot = fixture / 'snapshot'
package = fixture / 'package'
for path in (provider, snapshot / 'scripts', fixture / 'scripts', package, fixture / 'temp'):
    path.mkdir(parents=True, exist_ok=True)
(fixture / 'result').symlink_to(package)
trace = fixture / 'nix-ci.trace'
cli = provider / 'fixture-mo'
cli.write_text('''#!/bin/bash
[[ "${NIX_LAUNCH_VERIFIED:-}" == yes ]] || { echo UNWRAPPED_NIX_PROFILE; exit 97; }
printf 'PROFILE_VERSION\n' >> "$NIX_FIXTURE_TRACE"
echo 'Mole 1.67.0'
''')
cli.chmod(0o755)
smoke = '''import os,sys
from pathlib import Path
assert os.environ.get('NIX_LAUNCH_VERIFIED') == 'yes', 'UNWRAPPED_NIX_SMOKE'
target = Path(sys.argv[1])
assert target.is_absolute() and target == Path(os.environ['NIX_FAKE_PACKAGE'])
with open(os.environ['NIX_FIXTURE_TRACE'], 'a') as log: log.write('PACKAGE_SMOKE\\n')
'''
for location in (fixture, snapshot):
    (location / 'scripts/test_nix_package.py').write_text(smoke)
# A narrow launcher mock verifies the real workflow's argv after a snapshot
# changes cwd. Kernel enforcement and the real owned PTY have separate cases.
(fixture / 'scripts/test_sandbox.sh').write_text('''#!/bin/bash
set -euo pipefail
printf 'BOUNDARY\n' >> "$NIX_FIXTURE_TRACE"
export NIX_LAUNCH_VERIFIED=yes
cd "$NIX_FIXTURE_SNAPSHOT"
exec "$@"
''')
nix = provider / 'nix'
nix.write_text('#!' + sys.executable + '\n' + '''import json,os,sys
from pathlib import Path
args = sys.argv[1:]
assert args[0] == 'profile'
profile = Path(args[args.index('--profile') + 1])
assert profile.is_relative_to(Path(os.environ['NIX_FIXTURE_ROOT']))
action = args[1]
if action == 'install':
    (profile / 'bin').mkdir(parents=True)
    for name in ('mo', 'mole'):
        (profile / 'bin' / name).symlink_to(os.environ['NIX_FAKE_CLI'])
elif action == 'list': print(json.dumps({'elements': {'mole': {}}}))
elif action == 'upgrade': assert (profile / 'bin/mo').is_symlink()
elif action == 'remove':
    for name in ('mo', 'mole'): (profile / 'bin' / name).unlink()
else: raise AssertionError(args)
''')
nix.chmod(0o755)
env = dict(os.environ, PATH=str(provider) + ':' + os.environ['PATH'],
           RUNNER_TEMP=str(fixture / 'temp'), NIX_FIXTURE_ROOT=str(fixture),
           NIX_FIXTURE_SNAPSHOT=str(snapshot), NIX_FAKE_PACKAGE=str(package),
           NIX_FAKE_CLI=str(cli), NIX_FIXTURE_TRACE=str(trace))
results = []
for step in ('Check installed package', 'Check profile install, upgrade and removal'):
    result = subprocess.run(['/bin/bash', '-euo', 'pipefail', '-c', run_block(step)],
                            cwd=fixture, env=env, capture_output=True, text=True, timeout=15)
    results.append((step, result.returncode, result.stdout, result.stderr))
assert all(result[1] == 0 for result in results), results
records = trace.read_text().splitlines()
assert records.count('BOUNDARY') == 3, records
assert records.count('PACKAGE_SMOKE') == 1, records
assert records.count('PROFILE_VERSION') == 2, records
print('NIX_CI_PACKAGE_BOUNDARY=ok; NIX_CI_PROFILE_BOUNDARIES=2; SNAPSHOT_ARGV=ok')
PYTEST
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [[ "$output" == *"NIX_CI_PACKAGE_BOUNDARY=ok; NIX_CI_PROFILE_BOUNDARIES=2; SNAPSHOT_ARGV=ok"* ]]
}

@test "test sandbox pins a private GOPATH before a numeric account fallback" {
    run python3 -B - "$PROJECT_ROOT" <<'PYTEST'
from pathlib import Path
import os
import re
import subprocess
import sys

repo = Path(sys.argv[1])
source = (repo / 'scripts/test_sandbox.sh').read_text()
blocks = re.findall(r'^export MOLE_TEST_RUN_ROOT=.*?(?=^# Translate only explicit)', source, re.M | re.S)
assert len(blocks) == 1, 'expected one production environment setup block'
# Nested sandbox_apply is unavailable. Exercise the real exported environment
# and whole Bats helper inside this invocation's existing kernel boundary.
script = '''set -euo pipefail
run_root="$MOLE_TEST_RUN_ROOT"
token="$MOLE_TEST_BOUNDARY_TOKEN"
kernel_sentinel="$MOLE_TEST_KERNEL_SENTINEL"
unset GOPATH
id() { if [[ "$1" == -un ]]; then printf '501\\n'; else /usr/bin/id "$@"; fi; }
''' + blocks[0] + '''
source "$1/tests/helpers/common.bash"
go env GOPATH
[[ "$GOPATH" == "$run_root/go-work" ]] || exit 9
printf 'PRIVATE_GOPATH=ok; NUMERIC_ACCOUNT_FALLBACK=ok\\n'
'''
result = subprocess.run(['/bin/bash', '-c', script, 'private-gopath', str(repo)],
                        env=os.environ, text=True, capture_output=True, timeout=10)
assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
print(result.stdout)
PYTEST
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [[ "$output" == *"PRIVATE_GOPATH=ok; NUMERIC_ACCOUNT_FALLBACK=ok"* ]]
}

@test "skill audit CI fetches canonical Windows source when origin is a fork" {
    run python3 -B - "$PROJECT_ROOT" <<'PYTEST'
from pathlib import Path
import subprocess
import sys

source = (Path(sys.argv[1]) / '.github/workflows/check.yml').read_text()
steps = source.split('      - name: Fetch the Windows CLI for the skill audit\n')
assert len(steps) == 2, 'expected one Windows source fetch step'
step = steps[1].split('      - name: ', 1)[0]
commands = [line.strip()[5:] for line in step.splitlines() if line.strip().startswith('run: ')]
assert len(commands) == 1, 'expected one executable source fetch'
script = '''set -euo pipefail
git() {
    [[ "$1" == fetch ]] || return 71
    case " $* " in
        *" https://github.com/tw93/Mole.git "*) ;;
        *) echo UNVERIFIED_FORK_WINDOWS_SOURCE; return 72 ;;
    esac
    [[ "$*" == *"windows:refs/remotes/origin/windows"* ]] || return 73
    printf 'CANONICAL_WINDOWS_FETCH=ok\\n'
}
''' + commands[0]
result = subprocess.run(['/bin/bash', '-c', script], text=True, capture_output=True, timeout=5)
assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
assert result.stdout == 'CANONICAL_WINDOWS_FETCH=ok\n', result.stdout
print(result.stdout)
PYTEST
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [[ "$output" == *"CANONICAL_WINDOWS_FETCH=ok"* ]]
}
