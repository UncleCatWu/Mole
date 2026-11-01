#!/usr/bin/env python3
"""Run real timeout/color fixtures on the inherited identity-bound terminal."""
import json
import os
from pathlib import Path
import select
import sys
import time

from owned_pty import OwnedPair

project, mode, *arguments = sys.argv[1:]
env = dict(os.environ)
record = json.loads((Path(env['MOLE_TEST_RUN_ROOT']) / 'owned-pty.json').read_text())
env['MOLE_TEST_TTY_PATH'] = record['slave_path']
marker, reply = None, None
if mode in ('read', 'restore'):
    command = ['/bin/bash', project + '/tests/timeout_tty_read_fixture.sh', project]
    if mode == 'restore':
        command.append('timeout')
        marker, reply = b'READY-AFTER', b'typed-after\n'
    else:
        marker, reply = b'READY', b'typed-value\n'
elif mode == 'concurrent':
    command = ['/bin/bash', project + '/tests/timeout_tty_concurrent_fixture.sh', project]
    marker, reply = b'READY', b'typed-value\n'
elif mode == 'background':
    assert arguments in (['tty'], ['devnull'])
    command = ['/bin/bash', project + '/tests/timeout_tty_background_fixture.sh', project, *arguments]
elif mode == 'color':
    assert len(arguments) == 1
    env['TERM'] = arguments[0]
    for key in ('NO_COLOR', 'MOLE_TEST_MODE', 'MOLE_TEST_NO_AUTH'):
        env.pop(key, None)
    command = ['/bin/bash', project + '/tests/color_tty_fixture.sh', project]
else:
    raise ValueError('unknown owned terminal fixture')

with OwnedPair() as pair:
    child = pair.spawn(command, env=env)
    output = bytearray()
    sent = False
    until = time.monotonic() + 12
    while child.poll() is None or select.select([pair.master], [], [], 0)[0]:
        assert time.monotonic() < until, ('fixture deadline', bytes(output[-1000:]))
        if select.select([pair.master], [], [], .05)[0]:
            chunk = os.read(pair.master, 65536)
            if not chunk:
                break
            output.extend(chunk)
            assert len(output) <= 1024 * 1024, 'fixture output exceeded 1 MiB'
            if mode == 'concurrent':
                assert b'CHILD:OWNS' not in output, 'helper stole another group terminal'
            if marker and marker in output and not sent:
                os.write(pair.master, reply)
                sent = True
    rc = child.wait(timeout=2)
    sys.stdout.buffer.write(output)
    sys.stdout.buffer.flush()
    assert rc == 0, ('real fixture exit', rc)
    assert marker is None or sent, 'fixture never reached the real read'
