#!/usr/bin/env python3
"""Test-only native exec/partial-output observer; never fabricates exit124."""
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

kind = sys.argv[1]
argv = ['/usr/bin/' + kind, *sys.argv[2:]]
mode = os.environ['NATIVE_CASE']
record = Path(os.environ['NATIVE_EVENTS'])
target = os.environ.get('NATIVE_STALL_TARGET', '')
paused = target in argv and ((kind == 'find' and mode in ('app_scan', 'app_signal', 'project_scan')) or
                             (kind == 'du' and mode == 'app_du'))
child = None
forwarded = 0
start = time.monotonic()


def event(stage, **extra):
    with record.open('a') as stream:
        stream.write(json.dumps(dict(stage=stage, kind=kind, argv=argv, mode=mode,
                                    observer_pid=os.getpid(), backend_pid=os.getppid(),
                                    pgid=os.getpgrp(), elapsed=time.monotonic()-start,
                                    **extra), sort_keys=True) + '\n')


class Cancelled(Exception):
    pass


def cancel(signum, _frame):
    raise Cancelled(signum)


for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(sig, cancel)
rc = 1
try:
    # Popen's exec-error handshake returns only after the native exec succeeds.
    # No new session/group is requested: the native child inherits this group.
    # Querying its PID after exec races commands that have already completed.
    native_group = os.getpgrp()
    child = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    event('native-exec', native_pid=child.pid, native_pgid=native_group,
          stdout_fd=child.stdout.fileno(), stderr_fd=child.stderr.fileno())
    if paused and kind == 'find':
        # The large fixture exceeds pipe capacity: after a real native prefix
        # arrives the native producer is still alive, then a controlled stop
        # represents a stalled filesystem producer. Production backend owns
        # its deadline, termination and wait, not this observer.
        data = os.read(child.stdout.fileno(), 8192)
        assert data and child.poll() is None, 'native producer must be active with real prefix'
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
        forwarded += len(data)
        event('native-prefix', native_pid=child.pid, bytes=len(data),
              nul_records=data.count(b'\0'), newline_records=data.count(b'\n'))
    if paused:
        os.kill(child.pid, signal.SIGSTOP)
        event('controlled-native-stop', native_pid=child.pid, forwarded=forwarded)
        if mode == 'app_signal':
            event('injected-backend-signal', signum=2, target_pid=os.getppid())
            os.kill(os.getppid(), signal.SIGINT)
        while True:
            time.sleep(.05)
    while True:
        data = os.read(child.stdout.fileno(), 65536)
        if not data:
            break
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
        forwarded += len(data)
    error = child.stderr.read()
    sys.stderr.buffer.write(error)
    rc = child.wait(timeout=5)
except Cancelled as stopped:
    event('backend-signal', signum=stopped.args[0], forwarded=forwarded)
    rc = 128 + stopped.args[0]
finally:
    # Reap the owned native child even if the backend terminated our group.
    # A stopped process needs CONT before TERM can take effect.
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, signal.SIG_IGN)
    if child is not None:
        if child.poll() is None:
            for sig in (signal.SIGCONT, signal.SIGTERM):
                try:
                    os.kill(child.pid, sig)
                except ProcessLookupError:
                    pass
            try:
                child.wait(timeout=1)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=1)
        child.stdout.close()
        child.stderr.close()
        event('native-reaped', native_pid=child.pid, native_exit=child.returncode,
              pipes_closed=child.stdout.closed and child.stderr.closed,
              forwarded=forwarded, observer_exit=rc)
sys.exit(rc)
