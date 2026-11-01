#!/usr/bin/env bats
# Regressions for receipt completeness, channel ownership, and menu trap scope.

setup() {
    export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export REVIEW_FIXTURE="$(mktemp -d "$BATS_TEST_TMPDIR/uninstall-hardening.XXXXXX")"
    export HOME="$REVIEW_FIXTURE/home" TMPDIR="$REVIEW_FIXTURE/tmp"
    mkdir -p "$HOME" "$TMPDIR" "$REVIEW_FIXTURE/stubs" "$HOME/receipt-db"
    export MOLE_RESOLVED_TMPDIR="$TMPDIR" MOLE_TEST_NO_AUTH=1 MOLE_TEST_MODE=1
    export MOLE_PKG_RECEIPT_DB_DIR="$HOME/receipt-db"
    unset SUDO_USER SUDO_UID SUDO_GID MOLE_TEMP_REGISTRY_FILE
}

@test "ordinary incomplete receipt discovery never publishes a complete UI cache" {
    cat > "$REVIEW_FIXTURE/stubs/pkgutil" <<'STUB'
#!/bin/bash
case "$1" in
    --pkgs) printf 'com.example.survivor\n' ;;
    --files) printf 'opt/vendor/Survivor.app/Contents/Info.plist\n'; exit 124 ;;
    *) exit 2 ;;
esac
STUB
    chmod +x "$REVIEW_FIXTURE/stubs/pkgutil"
    run env PATH="$REVIEW_FIXTURE/stubs:/usr/bin:/bin" /bin/bash <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
run_with_timeout() { shift; "$@"; }
get_file_mtime() { /usr/bin/stat -f%m "$1"; }
MOLE_PKG_RECEIPT_CACHE_FILE="$HOME/receipt-cache"
output=$(pkg_receipt_nonstandard_app_paths)
[[ -z "$output" && ! -e "$MOLE_PKG_RECEIPT_CACHE_FILE" ]] || exit 1
rc=0
output=$(pkg_receipt_nonstandard_app_paths --require-complete) || rc=$?
[[ $rc -eq 124 && -z "$output" ]] || exit 2
printf 'PARTIAL_NOT_PUBLISHED; STRICT_TIMEOUT=124\n'
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"PARTIAL_NOT_PUBLISHED; STRICT_TIMEOUT=124"* ]]
}

@test "strict receipt proof rereads payloads even when package ids and UI cache are unchanged" {
    cat > "$REVIEW_FIXTURE/stubs/pkgutil" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$HOME/receipt-probes"
case "$1" in
    --pkgs) printf 'com.example.survivor\n' ;;
    --files) [[ ! -e "$HOME/payload-now-unreadable" ]] || exit 124 ;;
    *) exit 2 ;;
esac
STUB
    chmod +x "$REVIEW_FIXTURE/stubs/pkgutil"
    run env PATH="$REVIEW_FIXTURE/stubs:/usr/bin:/bin" /bin/bash <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
run_with_timeout() { shift; "$@"; }
get_file_mtime() { /usr/bin/stat -f%m "$1"; }
MOLE_PKG_RECEIPT_CACHE_FILE="$HOME/receipt-cache"
pkg_receipt_nonstandard_app_paths
[[ -s "$MOLE_PKG_RECEIPT_CACHE_FILE" ]] || exit 1
: > "$HOME/payload-now-unreadable"
# UI may reuse its completed observation. It is never deletion authority.
pkg_receipt_nonstandard_app_paths
rc=0
output=$(pkg_receipt_nonstandard_app_paths --require-complete) || rc=$?
[[ $rc -eq 124 && -z "$output" ]] || exit 2
[[ $(grep -c '^--files ' "$HOME/receipt-probes") -eq 2 ]] || exit 3
printf 'STRICT_REREAD_CHANGED_PAYLOAD=124\n'
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"STRICT_REREAD_CHANGED_PAYLOAD=124"* ]]
}

@test "strict receipt proof does not promote a legacy fingerprint-only cache" {
    cat > "$REVIEW_FIXTURE/stubs/pkgutil" <<'STUB'
#!/bin/bash
case "$1" in
    --pkgs) printf 'com.example.survivor\n' ;;
    --files) exit 124 ;;
    *) exit 2 ;;
esac
STUB
    chmod +x "$REVIEW_FIXTURE/stubs/pkgutil"
    run env PATH="$REVIEW_FIXTURE/stubs:/usr/bin:/bin" /bin/bash <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
run_with_timeout() { shift; "$@"; }
get_file_mtime() { /usr/bin/stat -f%m "$1"; }
MOLE_PKG_RECEIPT_CACHE_FILE="$HOME/receipt-cache"
fingerprint=$(printf 'com.example.survivor\n' | cksum | tr ' ' '-')
printf '#receipts:%s\n' "$fingerprint" > "$MOLE_PKG_RECEIPT_CACHE_FILE"
rc=0
pkg_receipt_nonstandard_app_paths --require-complete || rc=$?
[[ $rc -eq 124 ]] || exit 1
printf 'LEGACY_CACHE_NOT_PROOF\n'
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"LEGACY_CACHE_NOT_PROOF"* ]]
}

@test "simple selector preserves caller cleanup body and traps across nested selectors" {
    run /bin/bash <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/ui/menu_simple.sh"
stty() { :; }; tput() { :; }; show_cursor() { :; }; hide_cursor() { :; }
_ms_calculate_items_per_page() { printf '1\n'; }
read_key() { printf 'ENTER\n'; }
MOLE_MANAGED_ALT_SCREEN=1
ICON_EMPTY='' ICON_SOLID='' CYAN='' ICON_ARROW='' NC='' PURPLE_BOLD='' GRAY='' ICON_NAV_UP='' ICON_NAV_DOWN=''
cleanup() { printf 'OUTER_CLEANUP_FIRED\n'; }
trap cleanup EXIT
trap 'printf OUTER_INT' INT
trap 'printf OUTER_TERM' TERM
before=$(declare -f cleanup)
outer_exit=$(trap -p EXIT); outer_int=$(trap -p INT); outer_term=$(trap -p TERM)
# The second menu runs in the same shell while the first menu's locals and
# cleanup trap are active, rather than inside read_key's command substitution.
nested=false
hide_cursor() {
    if [[ "$nested" == false ]]; then
        nested=true
        inner_exit=$(trap -p EXIT)
        paginated_multi_select Inner beta >/dev/null 2>&1 || return 1
        [[ "$(trap -p EXIT)" == "$inner_exit" ]] || return 2
    fi
}
paginated_multi_select Outer alpha >/dev/null 2>&1
[[ "$(declare -f cleanup)" == "$before" ]] || exit 1
[[ "$(trap -p EXIT)" == "$outer_exit" ]] || exit 2
[[ "$(trap -p INT)" == "$outer_int" ]] || exit 3
[[ "$(trap -p TERM)" == "$outer_term" ]] || exit 4
printf 'CLEANUP_BODY_AND_NESTED_TRAPS_PRESERVED\n'
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"CLEANUP_BODY_AND_NESTED_TRAPS_PRESERVED"* ]] || return 1
    [[ "$output" == *"OUTER_CLEANUP_FIRED"* ]]
}

@test "Zed cask removal skips zap even though another channel has a different bundle id" {
    printf '#!/bin/sh\nexit 0\n' > "$REVIEW_FIXTURE/stubs/find"
    chmod +x "$REVIEW_FIXTURE/stubs/find"
    run env PATH="$REVIEW_FIXTURE/stubs:/usr/bin:/bin" /bin/bash <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
# Every action and live-app lookup is a no-op. Only the production cask-mode
# decision executes; a positive call trace proves the plan reached that sink.
_batch_selected_app_plan_matches() { return 0; }
uninstall_live_bundle_has_other_install() { _MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT=""; return 1; }
stop_launch_services() { :; }; unregister_app_bundle() { :; }; remove_login_item() { :; }
force_kill_app() { :; }; remove_file_list() { :; }; bootout_login_item_helpers() { :; }
defaults() { return 1; }
find() { return 0; }
brew_uninstall_cask() { printf 'CASK_MODE:%s\n' "$3" >> "$HOME/cask-mode.trace"; return 0; }
mkdir -p "$HOME/Applications/Zed Nightly.app"
selected_apps=() success_items=() success_dock_targets=() running_at_uninstall_apps=()
review_only_system_leftover_keys=() review_only_system_leftovers=() system_extension_warning_apps=()
failed_items=()
success_count=0 failed_count=0 brew_apps_removed=0 files_cleaned=0 total_items=0 total_size_freed=0
app_details=("Zed Nightly|$HOME/Applications/Zed Nightly.app|dev.zed.Zed-Nightly|0|||false|false|true|zed-nightly||||none|identity|dev.zed.Zed-Nightly||info")
MOLE_UNINSTALL_MODE=1
_batch_execute_removals
[[ $success_count -eq 1 ]] || exit 1
[[ $(cat "$HOME/cask-mode.trace") == CASK_MODE:nozap ]] || exit 2
printf 'ZED_CASK_SHARED_STATE_PRESERVED\n'
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"ZED_CASK_SHARED_STATE_PRESERVED"* ]]
}

@test "strict receipt scan shares the caller budget across listing and payloads" {
    cat > "$REVIEW_FIXTURE/stubs/pkgutil" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$HOME/budget-probes"
case "$1" in
    --pkgs) /bin/sleep 2; printf 'com.example.survivor\n' ;;
    --files) printf 'UNEXPECTED_PAYLOAD_READ\n' >> "$HOME/budget-probes" ;;
    *) exit 2 ;;
esac
STUB
    chmod +x "$REVIEW_FIXTURE/stubs/pkgutil"
    run env PATH="$REVIEW_FIXTURE/stubs:/usr/bin:/bin" /bin/bash <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
run_with_timeout() { shift; "$@"; }
MOLE_PKG_RECEIPT_CACHE_DISABLE=1
MOLE_PKG_RECEIPT_SCAN_TIMEOUT=2
MOLE_PKG_RECEIPT_LIST_TIMEOUT=2
rc=0
pkg_receipt_nonstandard_app_paths --require-complete || rc=$?
[[ $rc -eq 124 ]] || exit 1
[[ $(cat "$HOME/budget-probes") == --pkgs ]] || exit 2
printf 'LIST_AND_PAYLOAD_SHARE_BUDGET=124\n'
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"LIST_AND_PAYLOAD_SHARE_BUDGET=124"* ]]
}
