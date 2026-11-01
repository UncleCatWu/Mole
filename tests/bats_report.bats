#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
    export PROJECT_ROOT
    fixture=$(mktemp -d "$MOLE_TEST_RUN_ROOT/tmp/report-test.XXXXXX")
    export fixture
    MOLE_TEST_REPORT_DIR="$fixture/reports"
    export MOLE_TEST_REPORT_DIR
    source "$PROJECT_ROOT/lib/core/test_boundary.sh"
    source "$PROJECT_ROOT/tests/support/bats_report.sh"
    cat > "$fixture/pass-skip.bats" <<'BATS'
@test "fixture pass" { sleep .05; [ 1 -eq 1 ]; }
@test "fixture skip" { skip "intentional fixture"; }
BATS
    cat > "$fixture/fail.bats" <<'BATS'
@test "fixture fail" { [ 1 -eq 2 ]; }
BATS
}

@test "report boots nested Bats without inheriting bootstrap functions" {
    # shellcheck disable=SC2016 # The inner shell expands its inherited Bats paths.
    run /bin/bash -c '
        set -euo pipefail
        unset -f bats_readlinkf
        if declare -F bats_readlinkf > /dev/null; then exit 1; fi
        [[ -x "$BATS_ROOT/bin/bats" ]] || exit 1
        export PATH="$BATS_LIBEXEC:$PATH"
        source "$PROJECT_ROOT/lib/core/test_boundary.sh"
        source "$PROJECT_ROOT/tests/support/bats_report.sh"
        printf "NO_INHERITED_BOOTSTRAP\n"
        BATS_FORMATTER=tap mole_run_reported_bats "$fixture/pass-skip.bats"
        mole_finish_bats_report
    '
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"NO_INHERITED_BOOTSTRAP"* && "$output" == *"fixture pass"* && "$output" == *"fixture skip"* ]] || return 1
    python3 - "$MOLE_TEST_REPORT_DIR/summary.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as source:
    result = json.load(source)
assert result == dict(expected=2, completed=2, passed=1, failed=0, skipped=1,
                      complete=True, parts=1), result
PY
}

@test "report streams TAP and merges complete pass fail skip timing across invocations" {
    BATS_FORMATTER=tap mole_run_reported_bats "$fixture/pass-skip.bats"
    # shellcheck disable=SC2016  # The inner shell expands its inherited fixture paths.
    run env BATS_FORMATTER=pretty /bin/bash -c '
        source "$PROJECT_ROOT/lib/core/test_boundary.sh"
        source "$PROJECT_ROOT/tests/support/bats_report.sh"
        mole_run_reported_bats "$fixture/fail.bats"
    '
    [ "$status" -eq 1 ]
    [[ "$output" == *"fixture fail"* ]] || return 1
    mole_finish_bats_report
    python3 - "$MOLE_TEST_REPORT_DIR" <<'PY'
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as E
p=Path(sys.argv[1]); s=json.loads((p/'summary.json').read_text())
assert s == dict(expected=3,completed=3,passed=1,failed=1,skipped=1,complete=True,parts=2), s
root=E.parse(p/'report.xml').getroot()
assert len(root)==2
assert {Path(t.get('name')).name for t in root}=={'pass-skip.bats','fail.bats'}
assert float(root.get('time')) >= .04
assert any(c.find('skipped') is not None for t in root for c in t)
assert any(c.find('failure') is not None for t in root for c in t)
PY
}

@test "report validator refuses empty zero partial duplicate and untimed streams" {
    for content in '' '1..0' $'1..2\nsuite fixture\nokay' $'1..1\nsuite fixture\nok 1 test in 1ms\n1..0' $'1..1\nsuite fixture\nok 1 test'; do
        printf '%s\n' "$content" > "$fixture/input.tap"
        run python3 -B "$PROJECT_ROOT/tests/support/bats_report.py" validate "$fixture/input.tap" "$fixture/counts.json"
        [ "$status" -eq 1 ] || return 1
        [[ "$output" == *"incomplete-stream"* ]] || return 1
    done
}

@test "report preserves custom formatter failure and rejects unsupported selection" {
    cat > "$fixture/formatter" <<'SH'
#!/bin/bash
cat > /dev/null
exit 7
SH
    chmod +x "$fixture/formatter"
    # shellcheck disable=SC2016  # The inner shell expands its inherited fixture paths.
    run env BATS_FORMATTER="$fixture/formatter" /bin/bash -c '
        source "$PROJECT_ROOT/lib/core/test_boundary.sh"
        source "$PROJECT_ROOT/tests/support/bats_report.sh"
        mole_run_reported_bats "$fixture/pass-skip.bats"
    '
    [ "$status" -eq 7 ]
    run mole_finish_bats_report
    [ "$status" -eq 1 ]
    # shellcheck disable=SC2016  # The inner shell expands its inherited fixture paths.
    run env BATS_FORMATTER=unsupported /bin/bash -c '
        source "$PROJECT_ROOT/lib/core/test_boundary.sh"
        source "$PROJECT_ROOT/tests/support/bats_report.sh"
        mole_run_reported_bats "$fixture/pass-skip.bats"
    '
    [ "$status" -eq 16 ]
    [[ "$output" == *"unsupported-console"* && "$output" == *"set BATS_FORMATTER="* ]] || return 1
}

@test "report cancellation reaps owned producer group and refuses incomplete report" {
    cat > "$fixture/cancel.bats" <<'BATS'
@test "fixture cancel" { printf ready > "$BATS_TEST_FILENAME.ready"; sleep 30; }
BATS
    run python3 - "$PROJECT_ROOT" "$fixture" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
project, fixture = sys.argv[1:]
sys.path.insert(0, project + '/tests/support')
from owned_pty import stop_child
command='source "$PROJECT_ROOT/lib/core/test_boundary.sh"; source "$PROJECT_ROOT/tests/support/bats_report.sh"; mole_run_reported_bats "$fixture/cancel.bats"'
proc=subprocess.Popen(['/bin/bash','-c',command], stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
try:
    until=time.monotonic()+5
    while not Path(fixture+'/cancel.bats.ready').exists():
        assert proc.poll() is None
        assert time.monotonic()<until
        time.sleep(.02)
    os.killpg(proc.pid, signal.SIGTERM)
    proc.communicate(timeout=5)
    assert proc.returncode == -signal.SIGTERM, proc.returncode
finally:
    stop_child(proc)
print('PRODUCER=executed; TERM=observed; OWNED_GROUP=reaped')
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"OWNED_GROUP=reaped"* ]] || return 1
    run mole_finish_bats_report
    [ "$status" -eq 1 ]
}

@test "report records a broken pipe after an early console consumer closes" {
    cat > "$fixture/close-early" <<'SH'
#!/bin/bash
while IFS= read -r line; do
    case "$line" in 'ok '*) exit 0 ;; esac
done
SH
    chmod +x "$fixture/close-early"
    cat > "$fixture/large.bats" <<'BATS'
@test "producer ready" {
    printf ready > "$BATS_TEST_FILENAME.ready"
}
@test "large output" {
    awk 'BEGIN {for(i=0;i<2048;i++) printf "%0512d\n",i}' >&3
}
BATS
    # shellcheck disable=SC2016  # The inner shell expands its inherited fixture paths.
    run env BATS_FORMATTER="$fixture/close-early" /bin/bash -c '
        source "$PROJECT_ROOT/lib/core/test_boundary.sh"
        source "$PROJECT_ROOT/tests/support/bats_report.sh"
        mole_run_reported_bats "$fixture/large.bats"
    '
    [ "$status" -ne 0 ]
    local part tee_rc console_rc validator_rc junit_rc
    read -r part < "$MOLE_TEST_REPORT_DIR/parts"
    read -r tee_rc console_rc validator_rc junit_rc < "$part/formatter-status"
    # BSD tee returns 1 for EPIPE; other tee implementations die with SIGPIPE.
    [[ "$tee_rc" == 1 || "$tee_rc" == 141 ]] || return 1
    [[ "$console_rc" == 0 ]] || return 1
    [ -f "$fixture/large.bats.ready" ] || return 1
    run mole_finish_bats_report
    [ "$status" -eq 1 ]
}

@test "report records JUnit output failure without losing successful producer evidence" {
    cat > "$fixture/block-junit" <<'SH'
#!/bin/bash
cat > /dev/null
mkdir "$MOLE_TEST_BATS_PART_DIR/report.xml"
SH
    chmod +x "$fixture/block-junit"
    # shellcheck disable=SC2016  # The inner shell expands its inherited fixture paths.
    run env BATS_FORMATTER="$fixture/block-junit" /bin/bash -c '
        source "$PROJECT_ROOT/lib/core/test_boundary.sh"
        source "$PROJECT_ROOT/tests/support/bats_report.sh"
        mole_run_reported_bats "$fixture/pass-skip.bats"
    '
    [ "$status" -eq 1 ]
    local part tee_rc console_rc validation_rc junit_rc
    read -r part < "$MOLE_TEST_REPORT_DIR/parts"
    read -r tee_rc console_rc validation_rc junit_rc < "$part/formatter-status"
    [[ "$tee_rc" == 0 && "$console_rc" == 0 && "$validation_rc" == 0 && "$junit_rc" == 1 ]] || return 1
    run mole_finish_bats_report
    [ "$status" -eq 1 ]
}
