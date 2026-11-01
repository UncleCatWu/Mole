#!/usr/bin/env python3
"""Smoke-test a built Nix package without cleanup, network or authorization."""

import json
import os
from pathlib import Path
import re
import select
import subprocess
import sys
import tempfile
import termios
import time


def check_menu(launcher, env):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tests/support"))
    from owned_pty import OwnedPair

    # Keep the controlling terminal alive while Bash restores it on exit.
    keeper = (
        "import subprocess,sys,time; "
        "p=subprocess.run(sys.argv[1:]); "
        "print('MENU_EXIT='+str(p.returncode),flush=True); time.sleep(30)"
    )
    with OwnedPair() as pair:
        master, slave = pair.master, pair.slave
        process = pair.spawn([sys.executable, "-B", "-c", keeper, str(launcher)], env=env)
        output = b""
        deadline = time.monotonic() + 15
        while b"Q Quit" not in output or termios.tcgetattr(slave)[3] & termios.ECHO:
            if time.monotonic() >= deadline or process.poll() is not None:
                raise AssertionError(("menu failed to start", output))
            if select.select([master], [], [], 0.05)[0]:
                output += os.read(master, 65536)
                assert len(output) <= 1024 * 1024, "menu output exceeded 1 MiB"
        assert b"99.0.0" not in output, output
        previous_renders = output.count(b"Q Quit")
        os.write(master, b"u")
        deadline = time.monotonic() + 5
        while output.count(b"Q Quit") <= previous_renders:
            if time.monotonic() >= deadline or process.poll() is not None:
                raise AssertionError(("hidden update key dispatched", output))
            if select.select([master], [], [], 0.05)[0]:
                output += os.read(master, 65536)
                assert len(output) <= 1024 * 1024, "menu output exceeded 1 MiB"
        os.write(master, b"q")
        deadline = time.monotonic() + 5
        while b"MENU_EXIT=" not in output:
            assert time.monotonic() < deadline, ("menu failed to exit", output)
            if select.select([master], [], [], 0.05)[0]:
                output += os.read(master, 65536)
                assert len(output) <= 1024 * 1024, "menu output exceeded 1 MiB"
        assert b"MENU_EXIT=0" in output, output


def require_test_context(root):
    result = subprocess.run(
        ["/bin/bash", "-c", 'source "$1/lib/core/test_boundary.sh"; _mole_test_require_context',
         "nix-smoke-boundary", str(root)],
        env=dict(os.environ, MOLE_TEST_NO_AUTH="1"), stdin=subprocess.DEVNULL, timeout=5,
    )
    if result.returncode:
        raise SystemExit(result.returncode)


def main():
    root = Path(__file__).resolve().parents[1]
    require_test_context(root)
    package = Path(sys.argv[1]).resolve(strict=True)
    assert str(package).startswith("/nix/store/"), package
    version = re.search(r'^VERSION="([^"]+)"$', (root / "mole").read_text(), re.M)[1]
    entry = package / "share/mole/mole"
    assert entry.read_text().splitlines()[0] == "#!/bin/bash"
    for helper in ("analyze", "status"):
        assert (package / f"share/mole/bin/{helper}.sh").read_text().splitlines()[0] == "#!/bin/bash"
        assert os.access(package / f"share/mole/bin/{helper}-go", os.X_OK)

    with tempfile.TemporaryDirectory(prefix="mole-nix-smoke-") as scratch:
        home = Path(scratch)
        stubs = home / "stubs"
        stubs.mkdir()
        forbidden = home / "forbidden"
        for command in ("curl", "wget", "sudo", "osascript", "launchctl", "brew"):
            stub = stubs / command
            stub.write_text('#!/bin/bash\nprintf "%s\\n" "$0" >> "$MOLE_SMOKE_FORBIDDEN"\nexit 97\n')
            stub.chmod(0o755)
        env = dict(os.environ, HOME=str(home), TERM="xterm-256color",
                   MOLE_TEST_NO_AUTH="1", MOLE_SMOKE_FORBIDDEN=str(forbidden),
                   PATH=f"{stubs}:/usr/bin:/bin:/usr/sbin:/sbin")
        for key in ("MOLE_TEST_MODE", "MOLE_SKIP_MAIN", "MOLE_NIX_INSTALL"):
            env.pop(key, None)

        def run(launcher, args, status=0, text=None):
            result = subprocess.run([str(launcher), *args], env=env, cwd=home,
                                    text=True, capture_output=True, timeout=20)
            output = result.stdout + result.stderr
            assert result.returncode == status, (args, result.returncode, output)
            if text:
                assert text in output, (args, output)
            return result.stdout

        notice = home / ".cache/mole/update_message"
        notice.parent.mkdir(parents=True)
        notice.write_text("Mole 99.0.0 available. Run mo update")
        fixture = home / "analysis-fixture"
        fixture.mkdir()
        (fixture / "sample.txt").write_text("Nix package smoke fixture")
        for name in ("mo", "mole"):
            launcher = package / "bin" / name
            version_output = run(launcher, ["--version"], text=version)
            assert "Install: Nix" in version_output, version_output
            run(launcher, ["--help"], text="COMMANDS")
            run(launcher, ["history"], text="No operation history yet")
            history = json.loads(run(launcher, ["history", "--json"]))
            assert history["sessions"] == [] and history["deletions"] == [], history
            analysis = json.loads(run(launcher, ["analyze", "--json", str(fixture)]))
            assert any(row["name"] == "sample.txt" for row in analysis["entries"]), analysis
            run(launcher, ["analyze", "--help"], text="Usage:")
            run(launcher, ["status", "--help"], text="Usage:")
            for args in (["update"], ["update", "--nightly"],
                         ["update", "--force"], ["remove"], ["remove", "--dry-run"]):
                run(launcher, args, status=1, text="Nix")
            check_menu(launcher, env)
        assert notice.read_text() == "Mole 99.0.0 available. Run mo update"
        assert not forbidden.exists(), forbidden.read_text() if forbidden.exists() else ""
    print("Nix installed-package smoke checks passed")


if __name__ == "__main__":
    main()
