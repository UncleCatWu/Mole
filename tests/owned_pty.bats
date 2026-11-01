#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
}

@test "owned PTY admits exactly its identity-bound endpoint" {
    run python3 -B "$PROJECT_ROOT/tests/support/owned_pty.py" proof
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"EXACT_OWNED_PTY=allowed; OTHER_OWNED_PTY=denied; IDENTITIES=bound"* ]] || return 1
}

@test "owned PTY serializes leases and reaps signaled or leaderless children" {
    run python3 -B "$PROJECT_ROOT/tests/support/owned_pty_regression.py"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"TERM foreground/background children reaped; exited leader descendants stopped"* ]] || return 1
}
