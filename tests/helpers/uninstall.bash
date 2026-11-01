#!/usr/bin/env bash
# shellcheck shell=bash

# For batch tests whose app inventory is confined to their temporary HOME.
# Keep the production sibling scan and final recheck, but never inspect the
# host's Applications, mounted volumes, or package receipts.
mole_test_isolate_uninstall_inventory() {
    # Match the owner representation that stat uses inside the kernel sandbox.
    # shellcheck disable=SC2329 # Called by the production ownership check.
    whoami() { /usr/bin/stat -f%Su "$HOME"; }
    mkdir -p "$HOME"
    fixture_bind_uninstall_inventory
    _MOLE_UNINSTALL_LIVE_APP_ROOTS=("$HOME/Applications")
    _MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/no-volumes"
    # shellcheck disable=SC2329  # Invoked by the production sibling scan.
    pkg_receipt_nonstandard_app_paths() {
        printf 'RECEIPT_FIXTURE\n' >> "$HOME/inventory.trace"
        return 0
    }
}

# Model an explicit selection of every offered personal-data row, not the default.
mole_test_select_all_uninstall_data() {
    # shellcheck disable=SC2329  # Called by the production preview.
    drain_pending_input() { :; }
    # shellcheck disable=SC2329  # Called by the production data selector.
    paginated_multi_select() {
        local index
        MOLE_SELECTION_RESULT=""
        for ((index = 0; index < $# - 1; index++)); do
            [[ -z "$MOLE_SELECTION_RESULT" ]] || MOLE_SELECTION_RESULT+=,
            MOLE_SELECTION_RESULT+="$index"
        done
        return 0
    }
}

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
    # Shared fixture setup may be called by both old and new cases.
    declare -f fixture_original_batch_uninstall_applications > /dev/null 2>&1 && return 0
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
