#!/usr/bin/env python3
"""Signal only launcher processes created and held by this bounded harness."""
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time


if len(sys.argv) > 1 and sys.argv[1] == 'hold':
    from owned_pty import OwnedPair
    with OwnedPair() as pair:
        pair.spawn(['/bin/bash', '-c', 'while :; do sleep 1; done'], background=True)
        print(json.dumps({'root': os.environ['MOLE_TEST_RUN_ROOT']}), flush=True)
        time.sleep(30)
    sys.exit(0)

project = Path(__file__).resolve().parents[2]
for target in ('wrapper', 'launcher'):
    child = subprocess.Popen([str(project / 'scripts/test_sandbox.sh'), sys.executable, '-B',
                              str(project / 'tests/support/owned_pty_launcher_regression.py'), 'hold'],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    until = time.monotonic() + 30
    while not select.select([child.stdout], [], [], .05)[0]:
        assert child.poll() is None, child.communicate(timeout=1)
        assert time.monotonic() < until, 'launcher readiness deadline'
    root = Path(json.loads(child.stdout.readline())['root'])
    record = json.loads((root / 'owned-pty.json').read_text())
    until = time.monotonic() + 5
    while not list(root.glob('owned-pty-background-*.json')):
        assert time.monotonic() < until
        time.sleep(.02)
    if target == 'wrapper':
        child.send_signal(signal.SIGTERM)
    else:
        launcher_pid = record['parent_pid']
        parent = subprocess.check_output(['/bin/ps', '-p', str(launcher_pid), '-o', 'ppid='], text=True)
        assert int(parent.strip()) == child.pid, 'launcher lineage changed'
        os.kill(launcher_pid, signal.SIGTERM)
    out, err = child.communicate(timeout=12)
    assert child.returncode == 143, (target, child.returncode, out[-1000:], err[-1000:])
    receipt = json.loads((root / 'owned-pty-closed.json').read_text())
    assert receipt['child_reaped'] and receipt['owned_fds_closed'] and receipt['cleanup_error'] is None, receipt
    for client in receipt['clients']:
        assert client['state'] == 'closed' and client['child_reaped'], client
    for path in root.glob('owned-pty-background-*.json'):
        background = json.loads(path.read_text())
        assert background['state'] == 'closed' and background['child_reaped'], background
        try:
            os.killpg(background['child_pid'], 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError('background child group survived')
    print('PASS: ' + target + ' TERM reaped owned children, closed FDs; retained ' + str(root))
