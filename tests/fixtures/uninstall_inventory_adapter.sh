#!/bin/bash
# Orchestration cases own these inventories. Dedicated scan tests override
# the roots/providers explicitly and still exercise unknown/missing metadata.
_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$HOME/Applications" "$HOME/OtherApps")
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/Volumes"
pkg_receipt_nonstandard_app_paths() { return 0; }
# Generic batch cases have no Homebrew owner; brew_uninstall.bats supplies
# its own executable inventory and exercises the cask detection branches.
is_homebrew_available() { return 1; }
# sandbox-exec blocks directory-service lookups; whoami may return a numeric
# UID while stat renders the cached owner name. Bind the invoking owner to
# the same stat representation on this private fixture HOME.
whoami() { /usr/bin/stat -f%Su "$HOME"; }

fixture_prepare_uninstall_inventory() {
    local fixture_row fixture_path fixture_id
    # shellcheck disable=SC2154 # Orchestration tests supply these caller-scoped arrays.
    for fixture_row in "${apps_data[@]+"${apps_data[@]}"}" "${selected_apps[@]+"${selected_apps[@]}"}"; do
        IFS='|' read -r _ fixture_path _ fixture_id _ <<< "$fixture_row"
        [[ -d "$fixture_path" ]] || continue
        [[ "$fixture_path" == "$HOME/"* && "$fixture_path" != *'/../'* ]] || return 16
        [[ ! -f "$fixture_path/Contents/Info.plist" ]] || continue
        mkdir -p "$fixture_path/Contents"
        python3 - "$fixture_path/Contents/Info.plist" "$fixture_id" << 'PY'
import plistlib
import sys
with open(sys.argv[1], 'wb') as target:
    plistlib.dump({'CFBundleIdentifier': sys.argv[2]}, target)
PY
    done
}

fixture_bind_uninstall_inventory() {
    local fixture_body
    fixture_body=$(declare -f batch_uninstall_applications) || return 1
    fixture_body=${fixture_body/batch_uninstall_applications ()/fixture_original_batch_uninstall_applications ()}
    eval "$fixture_body"
    # shellcheck disable=SC2329 # The test calls this replacement entry point after binding.
    batch_uninstall_applications() {
        fixture_prepare_uninstall_inventory || return $?
        fixture_original_batch_uninstall_applications "$@"
    }
}
