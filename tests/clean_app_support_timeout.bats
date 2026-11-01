#!/usr/bin/env bats

setup_file() {
    export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

run_app_support_case() {
    local case_home="$BATS_TEST_TMPDIR/support-$1"
    mkdir -p "$case_home"
    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" CASE_MODE="$1" MOLE_TEST_MODE=0 \
        MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=true
SYSTEM_CLEAN=false
EXTERNAL_VOLUME_TARGET=""
WHITELIST_PATTERNS=()
WHITELIST_WARNINGS=()
MOLE_CURRENT_COMMAND=clean
MOLE_CLEAN_CANCEL_STATUS=0
_MOLE_CLEAN_INVENTORY_PARTIAL=false
MO_DEBUG=1
mkdir -p "$HOME/.config/mole"
check_tcc_permissions() { :; }
start_section() { :; }
end_section() { :; }
log_operation_session_end() { :; }
log_operation_session_start() { :; }
adopt_sudo_session() { return 1; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
should_protect_path() { return 1; }
is_path_whitelisted() { return 1; }
should_protect_data() { return 1; }
is_critical_system_component() { return 1; }
holds_compiled_model_cache() { return 1; }
_mole_should_refuse_live_user_cache_path() { return 1; }
for step in clean_user_essentials clean_finder_metadata clean_app_caches clean_browsers \
    run_cloud_and_office_cleanup clean_developer_tools clean_user_gui_applications \
    clean_virtualization_tools clean_orphaned_system_services clean_orphaned_container_stubs \
    show_user_launch_agent_hint_notice clean_apple_silicon_caches clean_cached_device_firmware \
    clean_time_machine_failed_backups check_large_file_candidates show_project_artifact_hint_notice; do
    eval "$step() { :; }"
done
clean_orphaned_app_data() { echo LATER_SECTION; }
update_progress_if_needed() {
    if [[ "$CASE_MODE" == budget ]]; then SECONDS=$_MOLE_APP_SUPPORT_DEADLINE; fi
    return 0
}
root="$HOME/Library/Application Support"
mkdir -p "$root/TestApp/Code Cache"
if [[ "$CASE_MODE" != guard_positive ]]; then printf cache > "$root/TestApp/Code Cache/a"; fi
printf cache > "$root/TestApp/Code Cache/b"
# Exercise the real materialize-and-discard producer. A timeout emits a
# seemingly eligible prefix which must never reach sizing or the preview.
eval "$(declare -f run_with_timeout | sed '1s/run_with_timeout/_test_native_timeout/')"
run_with_timeout() {
    if [[ "$2" == find && "$CASE_MODE" == scan && "$3" == "$root/TestApp/Code Cache" ]]; then
        printf '%s\0' "$root/TestApp/Code Cache/a"
        return 124
    fi
    if [[ "$2" == find && ("$CASE_MODE" == root_scan || "$CASE_MODE" == root_scan_real) && "$3" == "$root" ]]; then
        printf '%s\0' "$root/TestApp"
        return 124
    fi
    _test_native_timeout "$@"
}
app_support_item_size_bytes() {
    printf 'SIZE:%s\n' "${1##*/}" >> "$HOME/trace"
    if [[ "${1##*/}" == a ]]; then
        case "$CASE_MODE" in size) return 124 ;; signal) return 130 ;; esac
    fi
    printf '2048\n'
}
eval "$(declare -f record_dry_run_cleanup_target | sed '1s/record_dry_run_cleanup_target/_test_preview/')"
eval "$(declare -f safe_remove | sed '1s/safe_remove/_test_safe_remove/')"
record_dry_run_cleanup_target() {
    printf 'PREVIEW:%s\n' "${1##*/}" >> "$HOME/trace"
    if [[ "$CASE_MODE" == preview_guard && "${1##*/}" == a ]]; then return 124; fi
    _test_preview "$@" || return $?
    if [[ "$CASE_MODE" == budget_after && "${1##*/}" == a ]]; then SECONDS=$_MOLE_APP_SUPPORT_DEADLINE; fi
}
_test_final_guard() {
    printf 'GUARD:%s\n' "${1##*/}" >> "$HOME/trace"
    if [[ "${1##*/}" == a ]]; then return "$guard_status"; fi
    return 0
}
safe_remove() {
    printf 'SINK:%s\n' "${1##*/}" >> "$HOME/trace"
    if [[ "$CASE_MODE" == guard || "$CASE_MODE" == guard_signal || "$CASE_MODE" == guard_positive ]]; then
        _test_safe_remove "$@"
        return $?
    fi
    if [[ "${1##*/}" == a ]]; then
        case "$CASE_MODE" in
            removal) return 124 ;;
        esac
    fi
    _MOLE_SAFE_REMOVE_OUTCOME=removed
}
guard_status=124
[[ "$CASE_MODE" != guard_signal ]] || guard_status=130
case "$CASE_MODE" in removal|guard|guard_signal|guard_positive|root_scan_real) DRY_RUN=false ;; esac
case "$CASE_MODE" in guard|guard_signal|guard_positive) _MOLE_SAFE_REMOVE_FINAL_GUARD=_test_final_guard ;; esac
start_cleanup > /dev/null
rc=0
perform_cleanup || rc=$?
printf 'RC=%s CANCEL=%s PARTIAL=%s KB=%s\n' "$rc" "$MOLE_CLEAN_CANCEL_STATUS" "$DRY_RUN_TOTAL_PARTIAL" "$total_size_cleaned"
[[ ! -f "$HOME/trace" ]] || cat "$HOME/trace"
if [[ "$CASE_MODE" == guard_positive ]]; then
    [[ ! -e "$root/TestApp/Code Cache/b" ]] || exit 1
else
    [[ -f "$root/TestApp/Code Cache/a" && -f "$root/TestApp/Code Cache/b" ]] || exit 1
fi
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "Application Support section budget continues later clean sections" {
    run_app_support_case budget
    [[ "$output" == *"RC=0 CANCEL=0"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"LATER_SECTION"* ]] || return 1
    [[ "$output" != *"PREVIEW:"* ]] || return 1
}

@test "Application Support discards timed out candidate and root scan prefixes" {
    for mode in scan root_scan; do
        run_app_support_case "$mode"
        [[ "$output" == *"RC=0 CANCEL=0"* ]] || { echo "$output"; return 1; }
        [[ "$output" == *"LATER_SECTION"* ]] || return 1
        [[ "$output" != *"SIZE:"* && "$output" != *"PREVIEW:"* ]] || return 1
    done
}

@test "Application Support item size timeout keeps item and continues eligible sibling" {
    run_app_support_case size
    [[ "$output" == *"RC=0 CANCEL=0"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"SIZE:a"* && "$output" == *"SIZE:b"* ]] || return 1
    [[ "$output" != *"PREVIEW:a"* && "$output" == *"PREVIEW:b"* ]] || return 1
    [[ "$output" == *"PARTIAL=true KB=2"* ]] || return 1
    [[ "$output" == *"LATER_SECTION"* ]] || return 1
}

@test "Application Support removal timeout continues eligible sibling" {
    run_app_support_case removal
    [[ "$output" == *"RC=0 CANCEL=0"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"SINK:a"* && "$output" == *"SINK:b"* ]] || return 1
    [[ "$output" == *"LATER_SECTION"* ]] || return 1
}

@test "Application Support final guard timeout and signal remain sticky" {
    for mode in guard guard_signal preview_guard signal; do
        run_app_support_case "$mode"
        expected=124
        [[ "$mode" != signal && "$mode" != guard_signal ]] || expected=130
        [[ "$output" == *"RC=$expected CANCEL=$expected"* ]] || { echo "$output"; return 1; }
        [[ "$output" == *"SIZE:a"* ]] || return 1
        if [[ "$mode" == guard || "$mode" == guard_signal ]]; then
            [[ "$output" == *"GUARD:a"* ]] || { echo "$output"; return 1; }
        fi
        [[ "$output" != *"SIZE:b"* && "$output" != *"LATER_SECTION"* ]] || return 1
        [[ "$output" != *"PREVIEW:b"* && "$output" != *"SINK:b"* && "$output" != *"GUARD:b"* ]] || return 1
    done
    # A separate shell and fixture prove b is eligible without resetting the
    # cancellation state inside the interrupted production invocation.
    run_app_support_case guard_positive
    [[ "$output" == *"RC=0 CANCEL=0"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"SIZE:b"* && "$output" == *"SINK:b"* && "$output" == *"GUARD:b"* ]] || return 1
    [[ "$output" == *"LATER_SECTION"* ]] || return 1
}

@test "Application Support completed candidate positive control reaches later section" {
    run_app_support_case complete
    [[ "$output" == *"RC=0 CANCEL=0"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"PREVIEW:a"* && "$output" == *"PREVIEW:b"* ]] || return 1
    [[ "$output" == *"LATER_SECTION"* ]] || return 1
}

@test "Application Support preserves completed preview when cumulative budget expires" {
    run_app_support_case budget_after
    [[ "$output" == *"RC=0 CANCEL=0 PARTIAL=true KB=2"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"PREVIEW:a"* && "$output" != *"SIZE:b"* ]] || return 1
    [[ "$output" == *"LATER_SECTION"* ]] || return 1
    [[ "$output" == *"Application Support logs/caches"*"at least"* ]] || return 1
    [[ "$output" == *"Potential space:"*"2KB+"* ]] || return 1
}

@test "clean inventory partial state survives finalization and resets with new session" {
    run env HOME="$BATS_TEST_TMPDIR/reset" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 \
        MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME/.config/mole"
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=true
SYSTEM_CLEAN=false
EXTERNAL_VOLUME_TARGET=""
WHITELIST_PATTERNS=()
WHITELIST_WARNINGS=()
log_operation_session_start() { :; }
hide_cursor() { :; }
adopt_sudo_session() { return 1; }
start_cleanup > /dev/null
_MOLE_CLEAN_INVENTORY_PARTIAL=true
render_clean_preview_from_ledger
printf 'FIRST=%s\n' "$DRY_RUN_TOTAL_PARTIAL"
start_cleanup > /dev/null
render_clean_preview_from_ledger
printf 'SECOND=%s INVENTORY=%s\n' "$DRY_RUN_TOTAL_PARTIAL" "$_MOLE_CLEAN_INVENTORY_PARTIAL"
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"FIRST=true"* ]] || return 1
    [[ "$output" == *"SECOND=false INVENTORY=false"* ]] || return 1
}

@test "Application Support empty partial real scan does not claim system already clean" {
    run_app_support_case root_scan_real
    [[ "$output" == *"RC=0 CANCEL=0"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"LATER_SECTION"* ]] || return 1
    [[ "$output" == *"Cleanup scan incomplete; no additional space freed."* ]] || return 1
    [[ "$output" != *"already clean"* && "$output" != *"SINK:"* ]] || return 1
}
