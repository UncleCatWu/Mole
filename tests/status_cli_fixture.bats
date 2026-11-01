#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd -P)"
    export PROJECT_ROOT
    if [[ ! -x "${MOLE_TEST_STATUS_BIN:-}" ]]; then
        local helper_dir
        helper_dir="$(mktemp -d "${TMPDIR%/}/status-cli-fixture.XXXXXX")"
        # shellcheck source=tests/support/build_go_cli_helpers.sh
        source "$PROJECT_ROOT/tests/support/build_go_cli_helpers.sh"
        mole_build_go_cli_helpers "$helper_dir" || return $?
    fi
}

setup() {
    HOME="$(mktemp -d "${TMPDIR%/}/status-cli-home.XXXXXX")"
    export HOME
}

@test "status fixture executes production JSON and watch paths with native inputs" {
    run python3 - "$MOLE_TEST_STATUS_BIN" <<'PY'
from datetime import datetime
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time

binary = sys.argv[1]
def check(snapshot, enrichment=True):
    assert snapshot['host'] == 'mole-private-cli-fixture'
    assert snapshot['cpu']['logical_cpu'] == 2
    assert snapshot['memory']['total'] == 1 << 30
    assert snapshot['memory']['used'] == 1 << 29
    assert snapshot['memory']['used_percent'] == 50
    assert snapshot['disks'][0]['total'] == 8 << 30
    if enrichment:
        assert snapshot['hardware']['model'] == 'Fixture Mac'
        assert snapshot['top_processes'][0]['command'] == 'FixtureWorker'

single = subprocess.run([binary, '--json'], capture_output=True, text=True, timeout=5)
assert single.returncode == 0 and single.stderr == '', (single.returncode, single.stderr)
check(json.loads(single.stdout))
assert 24 < json.loads(single.stdout)['cpu']['usage'] < 26
proc = subprocess.Popen([binary, '--watch', '--interval', '200ms'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
selector = selectors.DefaultSelector()
selector.register(proc.stdout, selectors.EVENT_READ)
pending, snapshots = b'', []
try:
    until = time.monotonic() + 5
    while len(snapshots) < 3:
        assert time.monotonic() < until, 'watch deadline'
        for _, _ in selector.select(.1):
            chunk = os.read(proc.stdout.fileno(), 65536)
            assert chunk, 'watch exited before three snapshots'
            pending += chunk
            assert len(pending) <= 1024 * 1024
            while b'\n' in pending and len(snapshots) < 3:
                line, pending = pending.split(b'\n', 1)
                snapshot = json.loads(line)
                check(snapshot, enrichment=bool(snapshots))
                snapshots.append(snapshot)
    times = [datetime.fromisoformat(s['collected_at'].replace('Z', '+00:00')) for s in snapshots]
    assert all(a < b for a, b in zip(times, times[1:])), times
finally:
    selector.close()
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=3)
assert proc.returncode == -signal.SIGTERM, proc.returncode
assert proc.stderr.read() == b''
assert not (Path(os.environ['HOME']) / 'status-provider-unsupported').exists()
print('REAL_CLI_JSON=fixture-fields; WATCH=advancing-timestamps; SIGTERM=reaped')
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"REAL_CLI_JSON=fixture-fields; WATCH=advancing-timestamps; SIGTERM=reaped"* ]] || return 1
}

@test "status fixture provider failure reaches real CLI error handling" {
    printf failure > "$HOME/status-provider-failure"
    run "$MOLE_TEST_STATUS_BIN" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *"error collecting metrics: intentional status fixture ps failure"* ]] || return 1
    [[ "$output" != *'"host"'* ]] || return 1
    [[ ! -e "$HOME/status-provider-unsupported" ]] || return 1
}

@test "status fixture refuses missing boundary before native collection" {
    run env -u MOLE_TEST_BOUNDARY_TOKEN "$MOLE_TEST_STATUS_BIN" --json
    [ "$status" -eq 16 ]
    [[ "$output" == *"status native fixture refused: private sandbox boundary required"* ]] || return 1
    [[ ! -e "$HOME/status-provider-unsupported" ]] || return 1
}
