#!/usr/bin/env bats
run_native_case() {
    run env HOME="$MOLE_TEST_RUN_ROOT/native-$1" /bin/bash tests/support/native_producer_case.sh "$1"
    printf '%s\n' "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *'OWNED_NATIVE_CLOSURE='* ]]
}
@test "native completed recursive AppSupport size admits exact previews" {
    run_native_case app_complete
    [[ "$output" == *'LATER_SECTION'* ]]
}
@test "native AppSupport find prefix timeout discards plan and preserves partial later sections" {
    run_native_case app_scan
    [[ "$output" == *'LATER_SECTION'* && "$output" == *'Potential space:'*'+'* ]]
}
@test "native AppSupport du timeout keeps item and counts only completed sibling" {
    run_native_case app_du
    [[ "$output" == *'LATER_SECTION'* && "$output" == *'Potential space:'*'+'* ]]
}
@test "native project recursive completed producer preserves depth prune and sorted consumer domain" {
    run_native_case project_complete
}
@test "native project recursive prefix timeout never reaches consumer sink" {
    run_native_case project_scan
}
@test "native backend SIGINT remains sticky before any candidate sizing or later section" {
    run_native_case app_signal
    [[ "$output" != *'LATER_SECTION'* && "$output" != *'SIZE:'* && "$output" != *'PREVIEW:'* && "$output" != *'SINK:'* ]]
}

@test "native completed producer does not depend on a live child group lookup" {
    run python3 -B - "$BATS_TEST_DIRNAME/support/native_stall_observer.py" "$BATS_TEST_TMPDIR" <<'PYTEST'
from pathlib import Path
import json
import os
import runpy
import sys
from unittest.mock import patch

observer, fixture = map(Path, sys.argv[1:])
target = fixture / 'native-fast'
target.mkdir()
(target / 'leaf.txt').write_text('genuine native output')
events = fixture / 'native-fast.jsonl'
os.environ.update(NATIVE_CASE='fast_completed', NATIVE_EVENTS=str(events), NATIVE_STALL_TARGET='')
sys.argv = [str(observer), 'find', str(target), '-type', 'f', '-print']
# Model an already-completed short command. The real native exec, output and
# owning-parent wait still run; only the racy post-exec query is unavailable.
with patch.object(os, 'getpgid', side_effect=ProcessLookupError('completed native child')):
    try:
        runpy.run_path(str(observer), run_name='__main__')
    except SystemExit as result:
        assert result.code == 0, result.code
rows = [json.loads(line) for line in events.read_text().splitlines()]
started = [row for row in rows if row['stage'] == 'native-exec']
ended = [row for row in rows if row['stage'] == 'native-reaped']
assert len(started) == len(ended) == 1, rows
assert started[0]['native_pgid'] == started[0]['pgid'], started
assert ended[0]['native_exit'] == ended[0]['observer_exit'] == 0, ended
assert ended[0]['pipes_closed'] and ended[0]['forwarded'] > 0, ended
print('FAST_NATIVE_EXEC_OUTPUT_WAIT=ok')
PYTEST
    printf '%s\n' "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *'leaf.txt'* && "$output" == *'FAST_NATIVE_EXEC_OUTPUT_WAIT=ok'* ]]
}
