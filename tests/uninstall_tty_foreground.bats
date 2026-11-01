#!/usr/bin/env bats

load helpers/common

setup_file() {
	mole_test_setup_project_root
}

@test "tty ownership helper distinguishes foreground and background processes" {
	run /bin/bash -euo pipefail -c '
        python3 -B "$1/tests/support/owned_pty.py" foreground "$1/tests/uninstall_tty_foreground_fixture.sh" "$1"
        python3 -B "$1/tests/support/owned_pty.py" foreground "$1/tests/uninstall_tty_foreground_fixture.sh" "$1" background
    ' _ "$PROJECT_ROOT"

	[ "$status" -eq 0 ]
	[[ "$output" == *"TTY-STATE:foreground"* ]] || return 1
	[[ "$output" == *"TTY-STATE:background"* ]]
}

@test "completed uninstall checks tty ownership before countdown input" {
	run grep -n 'if ! mole_tty_is_foreground; then' "$PROJECT_ROOT/bin/uninstall.sh"

	[ "$status" -eq 0 ]
}

@test "tty ownership helper permits non-terminal input" {
	run /bin/bash -c '
        set -euo pipefail
        source "$1/lib/core/timeout.sh"
        mole_tty_is_foreground
    ' _ "$PROJECT_ROOT"

	[ "$status" -eq 0 ]
}
