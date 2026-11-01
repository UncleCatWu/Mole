#!/usr/bin/env bats

@test "install fixture adapter retains inner safety and leaves production tmp refusal intact" {
    run env HOME="$BATS_TEST_TMPDIR/home" PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)" /bin/bash <<'EOF'
set -euo pipefail
mkdir -p "$HOME/safe/child"
INSTALL_DIR=/private/tmp
eval "$(sed -n '/^install_lock_has_unsafe_ancestor() {/,/^install_lock_process_start() {/p' "$PROJECT_ROOT/install.sh" | sed '$d')"
# Probe the real sticky root read-only; the fixture itself may live elsewhere.
install_lock_has_unsafe_ancestor false || exit 1
[[ "$INSTALL_LOCK_UNSAFE_ANCESTOR" == /private/tmp && "$INSTALL_LOCK_UNSAFE_ANCESTOR_REASON" == writable ]] || exit 1
printf 'PRODUCTION_TMP_DENIED\n'
INSTALL_DIR="$HOME/safe/child"
source "$PROJECT_ROOT/tests/fixtures/install_probe_adapter.sh"
fixture_bind_install_ancestor_check install_lock_
if install_lock_has_unsafe_ancestor false; then exit 1; fi
printf 'FIXTURE_SAFE_ALLOWED\n'
chmod 0777 "$HOME/safe"
install_lock_has_unsafe_ancestor false || exit 1
[[ "$INSTALL_LOCK_UNSAFE_ANCESTOR" == "$HOME/safe" && "$INSTALL_LOCK_UNSAFE_ANCESTOR_REASON" == writable ]] || exit 1
printf 'FIXTURE_UNSAFE_DENIED\n'
chmod 0700 "$HOME/safe"
ln -s "$HOME/safe/child" "$HOME/link"
INSTALL_DIR="$HOME/link"
install_lock_has_unsafe_ancestor false || exit 1
[[ "$INSTALL_LOCK_UNSAFE_ANCESTOR_REASON" == symlink ]] || exit 1
printf 'FIXTURE_SYMLINK_DENIED\n'
grep -qF '[[ "$probe" == "/" ]] && break' "$PROJECT_ROOT/install.sh" || exit 1
EOF
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    for expected in PRODUCTION_TMP_DENIED FIXTURE_SAFE_ALLOWED FIXTURE_UNSAFE_DENIED FIXTURE_SYMLINK_DENIED; do
        [[ "$output" == *"$expected"* ]] || return 1
    done
}

@test "update fixture adapter retains unsafe ancestors and production tmp refusal" {
    run env HOME="$BATS_TEST_TMPDIR/update-home" PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)" /bin/bash <<'EOF'
set -euo pipefail
mkdir -p "$HOME/safe/child"
eval "$(sed -n '/^_update_lock_path_has_unsafe_ancestor() {/,/^_update_lock_prepare_dir() {/p' "$PROJECT_ROOT/lib/manage/update.sh" | sed '$d')"
_update_lock_path_has_unsafe_ancestor /private/tmp false || exit 1
printf 'UPDATE_PRODUCTION_TMP_DENIED\n'
source "$PROJECT_ROOT/tests/fixtures/install_probe_adapter.sh"
fixture_bind_install_ancestor_check _update_lock_
if _update_lock_path_has_unsafe_ancestor "$HOME/safe/child" false; then exit 1; fi
printf 'UPDATE_FIXTURE_SAFE_ALLOWED\n'
chmod 0777 "$HOME/safe"
_update_lock_path_has_unsafe_ancestor "$HOME/safe/child" false || exit 1
printf 'UPDATE_FIXTURE_UNSAFE_DENIED\n'
chmod 0700 "$HOME/safe"
ln -s "$HOME/safe/child" "$HOME/link"
_update_lock_path_has_unsafe_ancestor "$HOME/link" false || exit 1
printf 'UPDATE_FIXTURE_SYMLINK_DENIED\n'
grep -qF '[[ "$probe" == "/" ]] && break' "$PROJECT_ROOT/lib/manage/update.sh" || exit 1
EOF
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    for expected in UPDATE_PRODUCTION_TMP_DENIED UPDATE_FIXTURE_SAFE_ALLOWED UPDATE_FIXTURE_UNSAFE_DENIED UPDATE_FIXTURE_SYMLINK_DENIED; do
        [[ "$output" == *"$expected"* ]] || return 1
    done
}
