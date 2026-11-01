#!/usr/bin/env python3
"""Bounded real-process regressions for the sandbox's exact owned terminal."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from owned_pty import OwnedPair

root = Path(os.environ['MOLE_TEST_RUN_ROOT'])
master = int(os.environ['MOLE_TEST_PTY_MASTER_FD'])
support = str(Path(__file__).parent)


def client(code):
    return subprocess.Popen([sys.executable, '-B', '-c',
                             'import sys; sys.path.insert(0, ' + repr(support) + '); ' + code],
                            pass_fds=(master,), stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def wait_file(path, child):
    until = time.monotonic() + 5
    while not path.exists():
        assert child.poll() is None, child.communicate(timeout=1)
        assert time.monotonic() < until, str(path)
        time.sleep(.02)
    return json.loads(path.read_text())


def group_gone(pid):
    try:
        os.killpg(pid, 0)
    except ProcessLookupError:
        return
    raise AssertionError('owned process group survived: ' + str(pid))


# Two clients contend across processes; no test-file-specific lock is involved.
holder = client('from owned_pty import OwnedPair; import time; '
                'p=OwnedPair(); time.sleep(.5); p.close()')
wait_file(root / ('owned-pty-client-' + str(holder.pid) + '.json'), holder)
started = time.monotonic()
with OwnedPair():
    assert time.monotonic() - started >= .3, 'lease admitted two concurrent clients'
assert holder.communicate(timeout=3) == (b'', b'')
assert holder.returncode == 0

# Signal a client holding a foreground or true background child. Its context
# manager must reap every known group before another client acquires the lease.
for background in (False, True):
    code = ('from owned_pty import OwnedPair; import time; '
            'p=OwnedPair(); '
            'p.spawn(["/bin/bash", "-c", "while :; do sleep 1; done"], background=' + repr(background) + '); '
            '\ntry: time.sleep(30)\nfinally: p.close()')
    actor = client(code)
    receipt_path = root / ('owned-pty-client-' + str(actor.pid) + '.json')
    receipt = wait_file(receipt_path, actor)
    until = time.monotonic() + 5
    while not receipt.get('child_pid'):
        assert time.monotonic() < until
        time.sleep(.02)
        receipt = json.loads(receipt_path.read_text())
    if background:
        bg = wait_file(root / ('owned-pty-background-' + str(receipt['child_pid']) + '.json'), actor)
    actor.send_signal(signal.SIGTERM)
    out, err = actor.communicate(timeout=8)
    assert actor.returncode == 143, (actor.returncode, out[-1000:], err[-1000:])
    final = json.loads(receipt_path.read_text())
    assert final['state'] == 'closed' and final['child_reaped'], final
    group_gone(receipt['child_pid'])
    if background:
        group_gone(bg['child_pid'])
        assert json.loads((root / ('owned-pty-background-' + str(receipt['child_pid']) + '.json')).read_text())['child_reaped']
    with OwnedPair():
        pass

# A leader can exit while a same-group descendant still owns the terminal.
with OwnedPair() as pair:
    child = pair.spawn(['/bin/bash', '-c', 'trap "" HUP; sleep 30 & exit 0'])
    assert child.wait(timeout=3) == 0
    child_pid = child.pid
    os.killpg(child_pid, 0)  # Positive control: descendants actually remain.
group_gone(child_pid)

print('PASS: concurrent lease serialized; TERM foreground/background children reaped; exited leader descendants stopped')
