#!/usr/bin/env bats
@test "install and update mkdir holders bind generations through acquire and release" {
    local project_root fixture
    project_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    fixture="$(mktemp -d "$BATS_TEST_TMPDIR/install-lock-hardening.XXXXXX")"
    run python3 "$project_root/tests/fixtures/install_lock_probe.py" "$project_root" "$fixture"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [[ "$output" == *"install: GAP_MISSING_DENIED; NORMAL_REACQUIRE_OK"* ]] || return 1
    [[ "$output" == *"update: GAP_DEAD_DENIED; NORMAL_REACQUIRE_OK"* ]] || return 1
    [[ "$output" == *"UNKNOWN_PS_RETAINS_LEASE; CONTENDER_DENIED"* ]] || return 1
    [[ "$output" == *"RELEASE_ABA_PEER_PRESERVED"* ]] || return 1
    [[ "$output" == *"MARKER_IDENTITY_CHANGE_PRESERVED"* ]]
}
