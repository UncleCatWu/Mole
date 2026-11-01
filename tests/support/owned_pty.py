#!/usr/bin/env python3
"""Test-only PTY ownership: allocate in launcher, inherit only its exact pair."""
import errno
import fcntl
import json
import os
from pathlib import Path
import select
import signal
import stat
import subprocess
import sys
import termios
import time


def identity(fd):
    value = os.fstat(fd)
    return [value.st_dev, value.st_ino]


def write_record(path, value):
    pending = path.with_name(path.name + '.pending')
    pending.write_text(json.dumps(value, sort_keys=True) + '\n')
    pending.replace(path)


def stop_child(child):
    # Descendants may still occupy this owned group after its leader exits.
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        child.wait(timeout=2)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.wait(timeout=2)
    until = time.monotonic() + 2
    escalated = False
    while True:
        try:
            os.killpg(child.pid, 0)
        except ProcessLookupError:
            return child.returncode
        if time.monotonic() >= until:
            if escalated:
                raise RuntimeError('owned child group did not terminate; lease cannot be reused')
            os.killpg(child.pid, signal.SIGKILL)
            escalated = True
            until = time.monotonic() + 2
        time.sleep(.05)


def interrupted(signum, _frame):
    raise SystemExit(128 + signum)


def signal_handlers():
    previous = {}
    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        previous[signum] = signal.signal(signum, interrupted)
    return previous


class OwnedPair:
    """Lease the inherited pair; never allocate or discover a terminal."""
    def __init__(self):
        root = Path(os.environ['MOLE_TEST_RUN_ROOT'])
        record = json.loads((root / 'owned-pty.json').read_text())
        inherited_master = int(os.environ['MOLE_TEST_PTY_MASTER_FD'])
        assert inherited_master == record['fds'][0]
        self.master = os.dup(inherited_master)
        assert identity(self.master) == record['master_identity']
        self.record = record
        path_state = os.stat(record['slave_path'])
        assert [path_state.st_dev, path_state.st_ino] == record['slave_identity']
        assert stat.S_ISCHR(path_state.st_mode)
        self.lock = os.open(root / 'owned-pty.lease', os.O_RDWR | os.O_CREAT, 0o600)
        deadline = time.monotonic() + 30
        while True:
            try:
                fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    os.close(self.lock)
                    raise TimeoutError('owned PTY lease remained occupied')
                time.sleep(.05)
        self.busy_path = root / 'owned-pty.busy'
        if (root / 'owned-pty.poisoned').exists() or self.busy_path.exists():
            os.close(self.lock)
            os.close(self.master)
            raise RuntimeError('previous owned PTY cleanup was incomplete')
        # macOS revokes slave descriptors when their controlling session exits.
        # Reopen only the launcher-held endpoint, rebinding it on every lease.
        self.slave = None
        try:
            self.slave = os.open(record['slave_path'], os.O_RDWR | os.O_NOCTTY)
            assert identity(self.slave) == record['slave_identity']
            assert os.ttyname(self.slave) == record['slave_path']
            self.saved = termios.tcgetattr(self.slave)
            termios.tcflush(self.slave, termios.TCIOFLUSH)
            while select.select([self.master], [], [], 0)[0]:
                if not os.read(self.master, 65536):
                    break
        except BaseException:
            if self.slave is not None:
                os.close(self.slave)
            os.close(self.lock)
            os.close(self.master)
            raise
        self.child = None
        self.previous_handlers = signal_handlers()
        self.receipt_path = root / ('owned-pty-client-' + str(os.getpid()) + '.json')
        self.receipt = dict(client_pid=os.getpid(), slave_identity=record['slave_identity'],
                            state='leased', child_pid=None)
        write_record(self.receipt_path, self.receipt)
        # Persist before any child starts. SIGKILL drops flock but leaves this
        # token, so the next lease refuses rather than trusting missing cleanup.
        write_record(self.busy_path, self.receipt)

    def spawn(self, command, env=None, background=False):
        assert self.child is None, 'one child per owned PTY lease'
        slave = self.slave
        def terminal_session():
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        if background:
            command = [sys.executable, '-B', __file__, 'background-wrapper', *command]
        self.child = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave,
                                      env=env, preexec_fn=terminal_session,
                                      pass_fds=(slave,))
        self.receipt['child_pid'] = self.child.pid
        write_record(self.receipt_path, self.receipt)
        return self.child

    def close(self):
        error = None
        for signum in self.previous_handlers:
            signal.signal(signum, signal.SIG_IGN)
        try:
            if self.child is not None:
                stop_child(self.child)
            # Restore through a fresh identity-bound descriptor after revoke.
            restore_fd = os.open(self.record['slave_path'], os.O_RDWR | os.O_NOCTTY)
            try:
                assert identity(restore_fd) == self.record['slave_identity']
                termios.tcsetattr(restore_fd, termios.TCSANOW, self.saved)
            finally:
                os.close(restore_fd)
        except BaseException as exc:
            error = exc
            (Path(os.environ['MOLE_TEST_RUN_ROOT']) / 'owned-pty.poisoned').write_text(str(exc))
        finally:
            if error is None:
                try:
                    self.busy_path.unlink()
                except OSError as exc:
                    error = exc
            for fd in (self.slave, self.master, self.lock):
                try:
                    os.close(fd)
                except OSError as exc:
                    error = error or exc
            for signum, handler in self.previous_handlers.items():
                signal.signal(signum, handler)
        self.receipt.update(state='closed' if error is None else 'poisoned',
                            child_reaped=self.child is None or self.child.poll() is not None,
                            cleanup_error=str(error) if error else None)
        write_record(self.receipt_path, self.receipt)
        if error:
            raise error

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def capture(pair, command, background=False, deadline=20):
    child = pair.spawn(command, background=background)
    output = bytearray()
    until = time.monotonic() + deadline
    while child.poll() is None or select.select([pair.master], [], [], 0)[0]:
        if time.monotonic() >= until:
            raise TimeoutError('owned PTY child exceeded its bounded capture')
        if select.select([pair.master], [], [], .05)[0]:
            chunk = os.read(pair.master, 65536)
            if not chunk:
                break
            output.extend(chunk)
            if len(output) > 1024 * 1024:
                raise RuntimeError('owned PTY capture exceeded 1 MiB')
    sys.stdout.buffer.write(output)
    sys.stdout.buffer.flush()
    return child.wait(timeout=2)


def launch(root, policy, command):
    import pty
    owned_fds = []
    child = None
    previous_handlers = signal_handlers()
    try:
        master, slave = pty.openpty()
        owned_fds.extend((master, slave))
        other_master, other_slave = pty.openpty()
        owned_fds.extend((other_master, other_slave))
        # Bash relocates script input near its descriptor limit (199 on the
        # system Bash). Keep clear of both that range and Bats' low TAP FDs.
        master_copy = fcntl.fcntl(master, fcntl.F_DUPFD, 100)
        owned_fds.append(master_copy)
        slave_copy = fcntl.fcntl(slave, fcntl.F_DUPFD, 100)
        owned_fds.append(slave_copy)
        record = dict(parent_pid=os.getpid(), fds=[master_copy, slave_copy], master_identity=identity(master_copy),
                      slave_identity=identity(slave_copy), slave_path=os.ttyname(slave_copy),
                      denied_path=os.ttyname(other_slave),
                      denied_identity=identity(other_slave))
        for fd, path in ((slave_copy, record['slave_path']), (other_slave, record['denied_path'])):
            value = os.stat(path)
            assert identity(fd) == [value.st_dev, value.st_ino]
            assert stat.S_ISCHR(value.st_mode)
        write_record(root / 'owned-pty.json', record)
        with policy.open('a') as target:
            target.write('(allow file-write* (literal ' + json.dumps(record['slave_path']) + '))\n')
            target.write('(deny file-write* (literal ' + json.dumps(record['denied_path']) + '))\n')
        env = dict(os.environ, MOLE_TEST_PTY_MASTER_FD=str(master_copy), MOLE_TEST_PTY_SLAVE_FD=str(slave_copy))
        child = subprocess.Popen(['/usr/bin/sandbox-exec', '-f', str(policy), *command],
                                 env=env, pass_fds=(master_copy, slave_copy), start_new_session=True)
        record['sandbox_pid'] = child.pid
        write_record(root / 'owned-pty.json', record)
        return child.wait()
    finally:
        cleanup_error = None
        for signum in previous_handlers:
            signal.signal(signum, signal.SIG_IGN)
        try:
            if child is not None:
                stop_child(child)
        except BaseException as exc:
            cleanup_error = str(exc)
        clients = []
        try:
            clients = [json.loads(path.read_text()) for path in root.glob('owned-pty-client-*.json')]
            if any(item['state'] != 'closed' or not item['child_reaped'] for item in clients):
                cleanup_error = cleanup_error or 'owned PTY client cleanup incomplete; inspect client receipts'
        except BaseException as exc:
            cleanup_error = cleanup_error or str(exc)
        owned_fds_closed = True
        for fd in owned_fds:
            try:
                os.close(fd)
            except OSError as exc:
                cleanup_error = cleanup_error or str(exc)
                owned_fds_closed = False
        receipt = dict(parent_pid=os.getpid(), sandbox_pid=child.pid if child else None,
                       child_reaped=child is None or child.poll() is not None,
                       owned_fds_closed=owned_fds_closed, clients=clients, cleanup_error=cleanup_error)
        (root / 'owned-pty-closed.json').write_text(json.dumps(receipt) + '\n')
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
        print('Mole owned PTY receipt: ' + json.dumps({
            key: receipt[key] for key in ('parent_pid', 'sandbox_pid', 'child_reaped',
                                          'owned_fds_closed', 'cleanup_error')
        }) + '; client_receipts=' + str(len(clients)), file=sys.stderr)
        if cleanup_error:
            raise RuntimeError(cleanup_error)


def background_wrapper(command):
    # Hold the foreground session leader until its explicitly owned background
    # process group has terminated, including on TERM/HUP. No external terminal.
    signal_handlers()
    pid = os.fork()
    if pid == 0:
        os.setpgid(0, 0)
        for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            signal.signal(signum, signal.SIG_DFL)
        os.execvp(command[0], command)
    receipt_path = Path(os.environ['MOLE_TEST_RUN_ROOT']) / ('owned-pty-background-' + str(os.getpid()) + '.json')
    receipt = dict(wrapper_pid=os.getpid(), child_pid=pid, state='running')
    write_record(receipt_path, receipt)
    try:
        _, status = os.waitpid(pid, 0)
        return os.waitstatus_to_exitcode(status)
    finally:
        for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            signal.signal(signum, signal.SIG_IGN)
        try:
            os.killpg(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + 2
        while True:
            try:
                got, _ = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                break
            if got:
                break
            if time.monotonic() >= deadline:
                os.killpg(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
                break
            time.sleep(.05)
        # The child has been reaped; its same-group descendants must also stop.
        until = time.monotonic() + 2
        while True:
            try:
                os.killpg(pid, 0)
            except ProcessLookupError:
                break
            if time.monotonic() >= until:
                os.killpg(pid, signal.SIGKILL)
                raise RuntimeError('owned background group remained alive')
            time.sleep(.05)
        receipt.update(state='closed', child_reaped=True)
        write_record(receipt_path, receipt)


def main():
    mode = sys.argv[1]
    if mode == 'background-wrapper':
        return background_wrapper(sys.argv[2:])
    if mode == 'launch':
        return launch(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4:])
    if mode == 'run':
        with OwnedPair() as pair:
            return capture(pair, ['/bin/bash', '--noprofile', '--norc', sys.argv[2]])
    if mode == 'foreground':
        command = ['/bin/bash', sys.argv[2], sys.argv[3]]
        with OwnedPair() as pair:
            return capture(pair, command, background=len(sys.argv) > 4)
    if mode == 'proof':
        record = json.loads((Path(os.environ['MOLE_TEST_RUN_ROOT']) / 'owned-pty.json').read_text())
        with OwnedPair() as pair:
            fd = os.open(record['slave_path'], os.O_RDWR | os.O_NOCTTY)
            assert identity(fd) == record['slave_identity']
            os.close(fd)
            try:
                denied = os.open(record['denied_path'], os.O_RDWR | os.O_NOCTTY)
            except OSError as error:
                assert error.errno in (errno.EPERM, errno.EACCES), error
            else:
                os.close(denied)
                raise AssertionError('another task-owned PTY endpoint was admitted')
            print('EXACT_OWNED_PTY=allowed; OTHER_OWNED_PTY=denied; IDENTITIES=bound')
        return 0
    raise ValueError('unsupported test-only PTY operation')


if __name__ == '__main__':
    sys.exit(main())
