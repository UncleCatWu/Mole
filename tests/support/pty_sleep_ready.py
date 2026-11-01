#!/usr/bin/env python3
"""Witness a fixture-owned native sleep before sending terminal Ctrl-C."""
import os
import signal
import subprocess
import sys


def interrupted(signum, _frame):
    raise SystemExit(128 + signum)


for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(signum, interrupted)

child = None
try:
    # Popen's exec handshake returns after the native program starts. Keep
    # this child in the foreground terminal group; no process-table probe or
    # permission change is needed to prove the fixture is ready.
    child = subprocess.Popen(['/bin/sleep', sys.argv[1]])
    assert os.getpgid(child.pid) == os.getpgrp()
    print('POLLING_READY:' + str(child.pid), flush=True)
    code = child.wait()
    raise SystemExit(code if code >= 0 else 128 - code)
finally:
    if child is not None:
        if child.poll() is None:
            child.terminate()
        try:
            child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=2)
