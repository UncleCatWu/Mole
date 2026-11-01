#!/usr/bin/env bats

run_owner_case() {
    run env HOME="$BATS_TEST_TMPDIR/$1-$2" OWNER_MODE="$1" OWNER_ACTION="$2" \
        PROJECT_ROOT="$BATS_TEST_DIRNAME/.." MOLE_TEST_MODE=1 MOLE_SKIP_MAIN=1 MOLE_TEST_NO_AUTH=1 \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME"
source "$PROJECT_ROOT/mole"
export MOLE_TEST_MODE=0
generation="$HOME/.local/share/mole/generations/fixture"
prefix="$generation/bin"
config="$generation/config"
mkdir -p "$prefix" "$config" "$HOME/.config/mole" "$HOME/Library/Logs/mole"
printf '#!/bin/bash\nexit 0\n' > "$prefix/mole"
printf '#!/bin/bash\nexit 0\n' > "$config/rollback-to-homebrew.sh"
chmod 700 "$prefix/mole" "$config/rollback-to-homebrew.sh"
binding="$(stat -f%d:%i "$prefix")|$prefix"
printf '%s\n' "$binding" > "$config/.install_prefix"
digest=$(shasum -a 256 "$config/rollback-to-homebrew.sh");digest=${digest%% *}
printf 'MOLE_LOCAL_SOURCE_V1\t%s\t%s\t%s\t%s\n' "$binding" "$(stat -f%d:%i "$config")" "$config/rollback-to-homebrew.sh" "$digest" > "$config/.local_generation_owner"
chmod 600 "$config/.local_generation_owner"
SCRIPT_DIR="$config"
MOLE_CONFIG_DIR="$config"
MOLE_ENTRY_SCRIPT="$prefix/mole"
case "$OWNER_MODE" in
    private_home) HOME="$HOME/private-runtime-home"; export HOME; mkdir -p "$HOME/.config/mole" "$HOME/Library/Logs/mole" ;;
    missing) mv "$config/.local_generation_owner" "$config/owner-backup" ;;
    bad_marker) printf bad > "$config/.local_generation_owner" ;;
    marker_symlink) mv "$config/.local_generation_owner" "$config/owner-backup"; ln -s owner-backup "$config/.local_generation_owner" ;;
    bad_prefix) printf '0:0|%s\n' "$prefix" > "$config/.install_prefix" ;;
    bad_config) mv "$config" "$generation/old-config"; cp -R "$generation/old-config" "$config" ;;
    bad_rollback) printf 'changed\n' >> "$config/rollback-to-homebrew.sh" ;;
    bad_env) MOLE_CONFIG_DIR="$HOME/other-config" ;;
    official) MOLE_ENTRY_SCRIPT="$HOME/official/bin/mole"; SCRIPT_DIR="$PROJECT_ROOT"; unset MOLE_CONFIG_DIR ;;
esac
mkdir -p "$HOME/.cache/mole"
printf keep > "$HOME/.cache/mole/update_message"
printf keep > "$HOME/.config/mole/update_message"
printf keep > "$HOME/.config/mole/whitelist"
printf keep > "$HOME/.config/mole/purge_paths"
printf keep > "$HOME/Library/Logs/mole/operations.log"
is_homebrew_install() { printf 'OWNER_PROBE\n' >> "$HOME/trace"; return 0; }
brew() { printf 'BREW_ACTION:%s\n' "$*" >> "$HOME/trace"; }
brew_mole_formula_installed() { printf 'FORMULA_PROBE\n' >> "$HOME/trace"; return 0; }
update_via_homebrew() { printf 'BREW_UPDATE\n' >> "$HOME/trace"; }
cleanup_and_exit() { exit 0; }
show_brand_banner() { :; }
show_main_menu() { :; }
show_cursor() { :; }
hide_cursor() { :; }
clear() { :; }
MAIN_MENU_SHOW_UPDATE=true
read_key() { printf 'UPDATE\n'; }
trap 'rc=$?; for f in .cache/mole/update_message .config/mole/update_message .config/mole/whitelist .config/mole/purge_paths Library/Logs/mole/operations.log; do [[ "$(cat "$HOME/$f")" == keep ]] || exit 90; done; [[ ! -f "$HOME/trace" ]] || cat "$HOME/trace"; printf "SHARED_STATE_KEPT\n"; exit "$rc"' EXIT
case "$OWNER_ACTION" in
    update) main update --force ;;
    nightly) main update --nightly --force ;;
    remove) main remove ;;
    remove_dry) main remove --dry-run ;;
    menu) interactive_main_menu ;;
esac
EOF
    printf '%s\n' "$output"
}

@test "local source generation shared update refuses before Homebrew action" {
    for mode in valid private_home; do
        run_owner_case "$mode" update
        [ "$status" -eq 16 ]
        [[ "$output" == *'Restore the preserved official entry with:'* ]]
        [[ "$output" != *'OWNER_PROBE'* && "$output" != *'BREW_UPDATE'* ]]
        [[ "$output" == *'SHARED_STATE_KEPT'* ]]
    done
}

@test "local source generation menu nightly and remove share the early owner guard" {
    for action in menu nightly remove remove_dry; do
        run_owner_case valid "$action"
        [ "$status" -eq 16 ]
        [[ "$output" == *'Restore the preserved official entry with:'* ]]
        [[ "$output" != *'OWNER_PROBE'* && "$output" != *'FORMULA_PROBE'* && "$output" != *'BREW_ACTION'* ]]
        [[ "$output" == *'SHARED_STATE_KEPT'* ]]
    done
}

@test "expected local generation with missing corrupt or replaced ownership stays fail closed" {
    for mode in missing bad_marker marker_symlink bad_prefix bad_config bad_rollback bad_env; do
        for action in update remove_dry; do
            run_owner_case "$mode" "$action"
            [ "$status" -eq 16 ]
            [[ "$output" != *'Restore the preserved official entry with:'* ]]
            [[ "$output" != *'OWNER_PROBE'* && "$output" != *'FORMULA_PROBE'* && "$output" != *'BREW_ACTION'* && "$output" != *'BREW_UPDATE'* ]]
            [[ "$output" == *'SHARED_STATE_KEPT'* ]]
        done
    done
}

@test "official nonlocal context retains the existing Homebrew update route" {
    run_owner_case official update
    [ "$status" -eq 0 ]
    [[ "$output" == *'OWNER_PROBE'* && "$output" == *'BREW_UPDATE'* ]]
}
