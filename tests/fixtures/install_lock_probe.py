#!/usr/bin/env python3
"""Exercise only extracted holder scripts and owned fixture/process identities."""
from pathlib import Path
import os
import re
import subprocess
import sys
import time

repo = Path(sys.argv[1])
root = Path(sys.argv[2])
root.mkdir(parents=True, exist_ok=True)
processes = []


def wait_for(predicate, label, seconds=4):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError("timed out: " + label)


def start_time(pid):
    # Kernel sandbox deliberately refuses live ps. This controller owns the
    # only live pid admitted by its metadata stub; kill -0 remains real.
    assert pid == os.getpid()
    return "fixture-owner-start"


def launch(script, token, owner, owner_start, lock, control, mutex, env):
    control.write_text(token + "\n")
    process = subprocess.Popen(
        ["/bin/sh", "-c", script, "sh", token, str(owner), owner_start,
         str(lock), str(control), str(mutex)],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    processes.append(process)
    return process


def stop_control(process, control):
    if control.exists():
        control.unlink()  # Exact fixture-owned lease control.
    return process.wait(timeout=4)


try:
    for source, label in [("install.sh", "install"), ("lib/manage/update.sh", "update")]:
        text = (repo / source).read_text()
        match = re.search(r"local holder_script='\n(.*?)\n    '\n", text, re.S)
        assert match, source
        owner = os.getpid()
        owner_start = start_time(owner)
        ps_owned = root / (label + "-owned-ps")
        ps_owned.write_text(
            '#!/bin/sh\n[ "$2" = "' + str(owner) + '" ] || exit 1\n'
            'printf "%s\\n" "fixture-owner-start"\n'
        )
        ps_owned.chmod(0o755)
        script = match.group(1).replace("/bin/ps", str(ps_owned))
        token_a = f"{owner}|{owner_start}|A"
        token_b = f"{owner}|{owner_start}|B"
        token_c = f"{owner}|{owner_start}|C"
        env = {**os.environ, "LC_ALL": "C"}
        for old_token in ["missing", "dead"]:
            case = root / (label + "-gap-" + old_token)
            case.mkdir()
            lock, mutex = case / "kernel.lock", case / "holder"
            if old_token == "dead":
                lock.write_text("999999999|old start|old\n")
            ready, release = case / "ready", case / "release"
            wrapper = case / "mkdir-pause"
            wrapper.write_text(
                '#!/bin/sh\n/bin/mkdir "$@" || exit $?\nprintf ready > "$PROBE_READY"\n'
                'count=0\nwhile [ ! -f "$PROBE_RELEASE" ]; do\n'
                'count=$((count+1)); [ "$count" -lt 200 ] || exit 99\n/bin/sleep 0.02\ndone\n'
            )
            wrapper.chmod(0o755)
            pause_env = {**env, "PROBE_READY": str(ready), "PROBE_RELEASE": str(release)}
            a = launch(script.replace("/bin/mkdir", str(wrapper)), token_a, owner, owner_start,
                       lock, case / "control.A", mutex, pause_env)
            wait_for(ready.exists, label + " initial mkdir")
            b = launch(script, token_b, owner, owner_start, lock, case / "control.B", mutex, env)
            wait_for(lambda: b.poll() is not None or (lock.exists() and lock.read_text().strip() == token_b),
                     label + " contender outcome")
            assert b.poll() in (73, 74), "initial publication gap admitted a contender"
            release.touch()
            wait_for(lambda: lock.exists() and lock.read_text().strip() == token_a, label + " first owner publication")
            assert a.poll() is None
            assert stop_control(a, case / "control.A") == 0
            assert not mutex.exists(), "normal owner release failed"
            c = launch(script, token_c, owner, owner_start, lock, case / "control.C", mutex, env)
            wait_for(lambda: lock.read_text().strip() == token_c, label + " reacquire after release")
            assert stop_control(c, case / "control.C") == 0
            print(label + ": GAP_" + old_token.upper() + "_DENIED; NORMAL_REACQUIRE_OK", flush=True)

        case = root / (label + "-unknown-process")
        case.mkdir()
        lock, mutex = case / "kernel.lock", case / "holder"
        failure = case / "ps-fails"
        ps = case / "ps-probe"
        ps.write_text('#!/bin/sh\n[ ! -f "$PROBE_PS_FAIL" ] || exit 1\nexec "' + str(ps_owned) + '" "$@"\n')
        ps.chmod(0o755)
        unknown_script = script.replace(str(ps_owned), str(ps))
        unknown_env = {**env, "PROBE_PS_FAIL": str(failure)}
        a = launch(unknown_script, token_a, owner, owner_start, lock, case / "control.A", mutex, unknown_env)
        wait_for(lambda: lock.exists() and lock.read_text().strip() == token_a, label + " initial lease")
        active = launch(script, token_b, owner, owner_start, lock, case / "control.active", mutex, env)
        assert active.wait(timeout=4) == 73, "live owner was not diagnosed as contention"
        failure.touch()
        time.sleep(0.15)
        assert a.poll() is None and mutex.exists(), "unknown process metadata released a live owner"
        b = launch(unknown_script, token_b, owner, owner_start, lock, case / "control.B", mutex, unknown_env)
        assert b.wait(timeout=4) == 74
        assert lock.read_text().strip() == token_a
        assert stop_control(a, case / "control.A") == 0
        print(label + ": ACTIVE_OWNER=73; UNKNOWN_PS_RETAINS_LEASE; CONTENDER_DENIED", flush=True)

        case = root / (label + "-release-aba")
        case.mkdir()
        lock, mutex = case / "kernel.lock", case / "holder"
        a = launch(script, token_a, owner, owner_start, lock, case / "control.A", mutex, env)
        wait_for(lambda: lock.exists() and lock.read_text().strip() == token_a, label + " ABA initial lease")
        mutex.rename(case / "old-holder")
        mutex.mkdir()  # Peer publication gap, before its marker exists.
        lock.write_text(token_b + "\n")
        assert stop_control(a, case / "control.A") == 0
        assert mutex.is_dir() and lock.read_text().strip() == token_b, "old releaser removed a new generation"
        print(label + ": RELEASE_ABA_PEER_PRESERVED", flush=True)

        case = root / (label + "-marker-replacement")
        case.mkdir()
        lock, mutex = case / "kernel.lock", case / "holder"
        a = launch(script, token_a, owner, owner_start, lock, case / "control.A", mutex, env)
        wait_for(lambda: lock.exists() and lock.read_text().strip() == token_a, label + " marker initial lease")
        replacement = case / "replaced-owner"
        replacement.write_text(token_a + "\n")
        replacement.replace(mutex / "owner")
        assert stop_control(a, case / "control.A") == 0
        assert (mutex / "owner").read_text().strip() == token_a, "marker identity replacement was ignored"
        print(label + ": MARKER_IDENTITY_CHANGE_PRESERVED", flush=True)
finally:
    for process in processes:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=4)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=4)
