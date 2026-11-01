#!/usr/bin/env python3
"""Exercise the real purge selector in a PTY using fabricated metadata only."""
import fcntl
import os
import sys
import re
import select
import struct
import subprocess
import tempfile
import termios
import time
import unicodedata
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests/support'))
from owned_pty import OwnedPair
fixture = tempfile.TemporaryDirectory(prefix="mole-purge-menu-")
home = Path(fixture.name)
env = dict(
    os.environ,
    HOME=str(home),
    TEST_ROOT=str(root),
    TERM='xterm-256color',
    MOLE_TEST_NO_AUTH='1',
    MOLE_DRY_RUN='1',
    XDG_CACHE_HOME=str(home / '.cache'),
)
setup = r'''
source "$TEST_ROOT/lib/clean/project.sh"
categories=(); size_values=(); recent_values=(); age_values=()
long_path='/fixture/company/very-long-segment/another-long-segment/third-long-segment/fourth-long-segment/fifth-long-segment/sixth-long-segment'
for ((n=0; n<80; n++)); do
    categories+=("artifact-$n")
    size_values+=(1024); recent_values+=(false); age_values+=(30d)
    PURGE_CATEGORY_PROJECT_IDS_ARRAY+=("exact-project-$((n/20))")
    project_path="$long_path/项目-$((n/20))"
    [[ $n -lt 20 ]] && project_path="[cloud] $project_path"
    PURGE_CATEGORY_PROJECT_PATHS_ARRAY+=("$project_path")
    PURGE_CATEGORY_FULL_PATHS_ARRAY+=("$long_path/项目-$((n/20))/artifact-$n")
    PURGE_CATEGORY_SIZE_UNKNOWN_FLAGS_ARRAY+=(false)
done
PURGE_CATEGORY_SIZES=$(IFS=,; echo "${size_values[*]}")
PURGE_RECENT_CATEGORIES=$(IFS=,; echo "${recent_values[*]}")
PURGE_AGE_LABELS=$(IFS=,; echo "${age_values[*]}")
'''
script = setup + '\nif select_purge_categories "${categories[@]}"; then echo TEST_ACCEPTED; else echo TEST_CANCELLED; fi\n'
ansi = re.compile(rb'\x1b\[[0-?]*[ -/]*[@-~]')

def plain(frame: bytes) -> str:
    return ansi.sub(b'', frame).decode('utf-8').replace('\r', '')

def position(frame: bytes) -> int:
    matches = re.findall(r'\[(\d+)/80\]', plain(frame))
    assert matches, plain(frame)
    return int(matches[-1])

def width(line: str) -> int:
    return sum(
        0 if unicodedata.combining(c)
        else 2 if unicodedata.east_asian_width(c) in 'WF'
        else 1
        for c in line
    )

def fits(frame: bytes, rows: int, cols: int) -> None:
    lines = plain(frame).splitlines()
    overflow = [(width(line), line) for line in lines if width(line) > cols]
    assert not overflow, overflow
    assert len(lines) < rows, ('frame fills/overruns terminal', len(lines), rows)
owned_pair = OwnedPair()
master, slave = owned_pair.master, owned_pair.slave

def resize(rows: int, cols: int) -> None:
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
resize(40, 120)

p = owned_pair.spawn(['/bin/bash', '--noprofile', '--norc', '-c', script], env=env)
pending = b''

def receive(marker: bytes = b'\x1b[J') -> bytes:
    global pending
    deadline = time.monotonic() + 10
    while marker not in pending:
        assert time.monotonic() < deadline, ('timeout', pending[-1000:])
        if select.select([master], [], [], .05)[0]:
            try:
                chunk = os.read(master, 65536)
            except OSError as exc:
                raise AssertionError(('terminal ended', p.poll(), pending[-1000:])) from exc
            assert chunk, ('EOF', pending[-1000:])
            pending += chunk
            assert len(pending) <= 1024 * 1024, 'PTY frame exceeded 1 MiB'
    end = pending.index(marker) + len(marker)
    frame, pending = pending[:end], pending[end:]
    return frame
try:
    initial_frame = receive()
    fits(initial_frame, 40, 120)
    assert re.search(r'\[cloud\].*artifact-0', plain(initial_frame)), plain(initial_frame)
    os.write(master, b' ')
    assert '79 selected' in plain(receive())
    resize(10, 25)
    os.write(master, b'\n')
    resize_frame = receive()
    assert b'Resize' in resize_frame  # Enter cannot confirm an unreadable menu.
    fits(resize_frame, 10, 25)
    resize(40, 120)
    os.write(master, b'~')
    fits(receive(), 40, 120)
    for _ in range(29):
        os.write(master, b'j')
        frame = receive()
    assert position(frame) == 30
    resize(24, 80)
    os.write(master, b'~')  # Unbound key causes a redraw without changing selection.
    frame = receive()
    assert position(frame) == 30
    fits(frame, 24, 80)
    os.write(master, b'\x1b[6~')
    frame = receive()
    assert 40 <= position(frame) <= 60, ('Page Down did not move a page', position(frame))
    os.write(master, b'[')
    frame = receive()
    assert position(frame) == 21
    os.write(master, b']')
    frame = receive()
    assert position(frame) == 41
    fits(frame, 24, 80)
    os.write(master, '/项目-3错误'.encode() + b'\x7f\x7f\n')
    frame = receive()
    assert position(frame) == 61
    assert '79 selected' in plain(frame)
    os.write(master, b'n')
    frame = receive()
    assert position(frame) == 62
    assert '79 selected' in plain(frame)
    os.write(master, b'q')
    receive(b'TEST_CANCELLED')
    assert p.wait(timeout=2) == 0
finally:
    owned_pair.close()
# Pipe EOF is deterministic; closing a PTY master instead tests SIGHUP handling.
for input_bytes in (b'', b'/'):
    r = subprocess.run(['/bin/bash', '--noprofile', '--norc', '-c', script], env=env,
                       input=input_bytes, capture_output=True, timeout=10)
    assert r.returncode == 0 and b'TEST_CANCELLED' in r.stdout and b'TEST_ACCEPTED' not in r.stdout, r.stdout[-1000:]
print('PASS: focus survives resize; rows fit; paging/project jumps work; quit and EOF cancel')

def check_activity_poll_interrupt(root: Path) -> None:
    import sys
    with tempfile.TemporaryDirectory(prefix='mole-purge-activity-pty-') as directory:
        case_home = Path(directory)
        case_env = dict(os.environ, HOME=directory, TEST_ROOT=str(root),
                        TERM='xterm-256color', MOLE_TEST_NO_AUTH='1',
                        MOLE_DRY_RUN='1', XDG_CACHE_HOME=str(case_home / '.cache'))
        case_script = r'''
set -euo pipefail
source "$TEST_ROOT/lib/clean/project.sh"
for name in a-first b-peer c-later; do
    mkdir -p "$HOME/www/$name/node_modules"
    touch "$HOME/www/$name/package.json"
done
PURGE_SEARCH_PATHS=("$HOME/www")
scan_purge_targets() { printf '%s\n' "$HOME/www/"{a-first,b-peer,c-later}/node_modules > "$2"; }
purge_artifact_has_authored_content() { return 1; }
purge_node_modules_is_protected() { return 1; }
get_optimal_parallel_jobs() { echo 2; }
get_dir_size_kb() { echo SIZE_PHASE_REACHED >&2; echo 1; }
safe_remove() { echo UNEXPECTED_REMOVE; }
register_temp_file() { printf '%s\n' "$1" >> "$HOME/activity-results"; }
# Widen only the polling sleep so the real PTY interrupt cannot miss its
# 20 ms window. The worker delay and all production reaping logic stay real.
sleep() {
    if [[ "${1:-}" == 0.02 ]]; then
        python3 -I -B "$TEST_ROOT/tests/support/pty_sleep_ready.py" 1
    else
        command sleep "$@"
    fi
}
is_recently_modified() {
    [[ "$1" != *c-later* ]] || { echo LATER_PROBE_REACHED >&2; return 1; }
    printf '%s\n' "$1" >> "$HOME/activity-started"
    sleep 0.4
    printf '%s\n' "$1" >> "$HOME/activity-done"
    _PURGE_ACTIVITY_STATE=old
    return 1
}
trap 'echo UNEXPECTED_CALLER_INT' INT
caller_int_trap=$(trap -p INT)
# No cleanup in EXIT: cleanup here would conceal result files left behind
# when errexit escapes the polling loop before the production drain.
trap 'code=$?; printf "EXIT=%s OUTCOME=%s\n" "$code" "$PURGE_RUN_OUTCOME"; [[ "$(trap -p INT)" != "$caller_int_trap" ]] || echo CALLER_TRAP_RESTORED' EXIT
# Keep this call bare. An || result=$? wrapper disables the set -e path.
clean_project_artifacts
printf 'UNEXPECTED_RETURN\n'
'''
        activity_pair = OwnedPair()
        master_fd = activity_pair.master
        fcntl.ioctl(master_fd, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
        process = activity_pair.spawn(['/bin/bash', '--noprofile', '--norc', '-c', case_script], env=case_env)
        output = b''
        sent_interrupt = False
        deadline = time.monotonic() + 10
        try:
            while time.monotonic() < deadline:
                if select.select([master_fd], [], [], .02)[0]:
                    try:
                        chunk = os.read(master_fd, 65536)
                    except OSError:
                        chunk = b''
                    output += chunk
                if b'POLLING_READY:' in output and not sent_interrupt:
                    # The native child exec handshake supplied this marker;
                    # unknown global ps visibility never authorizes the signal.
                    os.write(master_fd, b'\x03')
                    sent_interrupt = True
                if process.poll() is not None:
                    break
            assert process.poll() is not None, ('activity watchdog expired', output[-2000:])
            # Capture the final EXIT trap output after poll observes exit.
            while select.select([master_fd], [], [], .02)[0]:
                try:
                    chunk = os.read(master_fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                output += chunk
            assert sent_interrupt, ('activity poll was never reached', output[-2000:])
            assert process.returncode == 130, (process.returncode, output[-2000:])
            assert b'EXIT=130 OUTCOME=cancelled' in output, output[-2000:]
            assert b'CALLER_TRAP_RESTORED' in output, output[-2000:]
            started = (case_home / 'activity-started').read_text().splitlines()
            done_file = case_home / 'activity-done'
            done = done_file.read_text().splitlines() if done_file.exists() else []
            assert len(started) == 2 and sorted(done) == sorted(started), ('workers not drained', started, done, output[-2000:])
            results = (case_home / 'activity-results').read_text().splitlines()
            assert results and not any(Path(path).exists() for path in results), ('activity result files leaked', results, output[-2000:])
            for marker in (b'SIZE_PHASE_REACHED', b'UNEXPECTED_REMOVE', b'LATER_PROBE_REACHED', b'UNEXPECTED_RETURN', b'UNEXPECTED_CALLER_INT'):
                assert marker not in output, (marker, output[-2000:])
            print('PASS: bare activity call drains workers and removes results on PTY Ctrl-C')
        finally:
            activity_pair.close()

check_activity_poll_interrupt(root)

fixture.cleanup()
