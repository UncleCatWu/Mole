#!/usr/bin/env bats

setup() {
    export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export HOME="$(mktemp -d "$BATS_TEST_DIRNAME/tmp-clean-hardening.XXXXXX")"
    export TRACE="$HOME/trace"
}
teardown() {
    rm -rf "$HOME" # SAFE: exact per-test mktemp fixture inside the private test snapshot
}

@test "owner cache signals reach developer orchestration and stop next step" {
    for rc in 130 143; do
        run env RC="$rc" /bin/bash << 'SH'
: > "$TRACE"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
MOLE_CURRENT_COMMAND=clean
MOLE_CLEAN_CANCEL_STATUS=0
is_path_whitelisted() { return 1; }
note_activity() { :; }
mkdir -p "$HOME/.cache/npm"
owner() { echo OWNER >> "$TRACE"; return "$RC"; }
later() { echo LATER >> "$TRACE"; }
step() { clean_tool_cache cache "$HOME/.cache/npm" owner; echo INSIDE >> "$TRACE"; }
status=0
_run_developer_cleanup_step step || status=$?
if [[ $status -eq 0 ]]; then _run_developer_cleanup_step later || status=$?; fi
printf 'STATUS=%s CANCEL=%s\n' "$status" "${MOLE_CLEAN_CANCEL_STATUS:-0}"
cat "$TRACE"
SH
        [ "$status" -eq 0 ] || return 1
        [[ "$output" == *"OWNER"* && "$output" == *"STATUS=$rc CANCEL=$rc"* ]] || return 1
        [[ "$output" != *"LATER"* ]] || return 1
    done
}

@test "owner cache ordinary failure stays diagnostic and does not cancel cleanup" {
    run /bin/bash << 'SH'
: > "$TRACE"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
is_path_whitelisted() { return 1; }
note_activity() { :; }
mkdir -p "$HOME/.cache/npm"
MO_DEBUG=1
owner() { echo OWNER >> "$TRACE"; return 7; }
rc=0
clean_tool_cache cache "$HOME/.cache/npm" owner || rc=$?
printf 'RC=%s\n' "$rc"
cat "$TRACE"
SH
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=0"* && "$output" == *"OWNER"* && "$output" == *"owner command exited 7"* ]]
}

@test "developer cleanup preserves Prometheus WAL Git lock and Homebrew locks" {
    run /bin/bash << 'SH'
: > "$TRACE"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { printf 'CANDIDATE:%s\n' "$*"; }
clean_dev_cicd
clean_dev_misc
# Inspect executable function body as Homebrew roots are real system paths.
body=$(declare -f clean_developer_tools)
if [[ "$body" == *'Homebrew lock files'* ]]; then echo UNEXPECTED_BREW_LOCK; fi
SH
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Terraform cache"* ]] || return 1
    [[ "$output" != *"Prometheus WAL"* && "$output" != *"Git config lock"* && "$output" != *"UNEXPECTED_BREW_LOCK"* ]]
}

@test "Application Support counts only completed removal receipts across both families" {
    for outcome in removed missing refused failed not_observed not_removed legacy 130; do
        run env OUTCOME="$outcome" /bin/bash << 'SH'
: > "$TRACE"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
DRY_RUN=false
MOLE_CURRENT_COMMAND=clean
MOLE_CLEAN_CANCEL_STATUS=0
start_section_spinner() { :; }; stop_section_spinner() { :; }; note_activity() { :; }
update_progress_if_needed() { return 1; }; should_protect_data() { return 1; }
is_critical_system_component() { return 1; }; should_protect_path() { return 1; }
is_path_whitelisted() { return 1; }
app_support_item_size_bytes() { echo 2048; }
safe_remove() {
 printf 'SINK:%s\n' "$1" >> "$TRACE"
 if [[ "$1" == */two ]]; then
  command rm -f "$1" # SAFE: exact private fixture completing the positive control
  [[ ! -e "$1" ]] || return 1
  _MOLE_SAFE_REMOVE_OUTCOME=removed
  return 0
 fi
 if [[ "$OUTCOME" == 130 ]]; then return 130; fi
 if [[ "$OUTCOME" == legacy ]]; then return 0; fi
 _MOLE_SAFE_REMOVE_OUTCOME="$OUTCOME"
 if [[ "$OUTCOME" == removed || "$OUTCOME" == missing ]]; then
  command rm -f "$1" # SAFE: exact private fixture modeling completed or concurrent removal
 fi
 [[ "$OUTCOME" != failed && "$OUTCOME" != refused ]]
}
files_cleaned=0; total_size_cleaned=0; total_items=0
mkdir -p "$HOME/Library/Application Support/TestApp/Code Cache" "$HOME/Library/Group Containers/group.com.apple.contentdelivery/Logs"
printf fixture > "$HOME/Library/Application Support/TestApp/Code Cache/one"
printf fixture > "$HOME/Library/Group Containers/group.com.apple.contentdelivery/Logs/two"
rc=0; clean_application_support_logs || rc=$?
printf 'COUNT=%s KB=%s RC=%s\n' "$files_cleaned" "$total_size_cleaned" "$rc"
cat "$TRACE"
SH
        [ "$status" -eq 0 ] || {
            echo "$output"
            return 1
        }
        [[ "$output" == *"SINK:"* ]] || return 1
        if [[ "$outcome" == removed ]]; then
            [[ "$output" == *"COUNT=2 KB=4"* ]] || return 1
        elif [[ "$outcome" == 130 ]]; then
            [[ "$output" == *"COUNT=0 KB=0 RC=130"* && "$output" != *"Logs/two"* ]] || return 1
        else
            [[ "$output" == *"COUNT=1 KB=2 RC=0"* && "$output" == *"Logs/two"* ]] || return 1
        fi
    done
}

@test "Application Support scan failure discards partial candidates" {
    run /bin/bash << 'SH'
: > "$TRACE"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
DRY_RUN=false
start_section_spinner() { :; }; stop_section_spinner() { :; }; note_activity() { :; }
update_progress_if_needed() { return 1; }; should_protect_data() { return 1; }
is_critical_system_component() { return 1; }; should_protect_path() { return 1; }; is_path_whitelisted() { return 1; }
files_cleaned=0; total_size_cleaned=0; total_items=0
mkdir -p "$HOME/Library/Application Support/TestApp/Code Cache"
printf fixture > "$HOME/Library/Application Support/TestApp/Code Cache/one"
run_with_timeout() {
 shift
 if [[ "$1" == find ]]; then
  echo PRODUCER >> "$TRACE"
  printf '%s\0' "$HOME/Library/Application Support/TestApp/Code Cache/one"
  return 1
 fi
 "$@"
}
safe_remove() { echo UNEXPECTED_SINK >> "$TRACE"; _MOLE_SAFE_REMOVE_OUTCOME=removed; }
clean_application_support_logs || true
cat "$TRACE"
printf 'COUNT=%s KB=%s\n' "$files_cleaned" "$total_size_cleaned"
SH
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"PRODUCER"* && "$output" == *"COUNT=0 KB=0"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SINK"* ]]
}

@test "installer cancellation preserves exact first status and leaves next target untouched" {
    for rc in 124 130 143; do
        run env RC="$rc" /bin/bash << 'SH'
: > "$TRACE"
export MOLE_TEST_MODE=1
source "$PROJECT_ROOT/bin/installer.sh"
first="$HOME/first.dmg"; second="$HOME/second.dmg"
printf first > "$first"; printf second > "$second"
INSTALLER_DELETE_PATHS=("$first" "$second")
INSTALLER_DELETE_SIZES=(5 6)
INSTALLER_DELETE_IDENTITIES=("$(mole_deletion_identity "$first")" "$(mole_deletion_identity "$second")")
reset_installer_delete_results
mole_delete() {
 printf 'SINK:%s\n' "$1" >> "$TRACE"
 if [[ "$1" == "$first" ]]; then return "$RC"; fi
 command rm -f "$1" # SAFE: otherwise eligible exact private next-target fixture
}
rc=0
execute_installer_delete_plan || rc=$?
printf 'RC=%s\n' "$rc"
cat "$TRACE"
SH
        [ "$status" -eq 0 ] || return 1
        [[ "$output" == *"RC=$rc"* && "$output" == *"SINK:$HOME/first.dmg"* ]] || return 1
        [[ "$output" != *"SINK:$HOME/second.dmg"* ]] || return 1
    done
}

@test "ZIP fully drains bounded producer while applying only first fifty entries" {
    run /bin/bash << 'SH'
: > "$TRACE"
export MOLE_TEST_MODE=1
source "$PROJECT_ROOT/bin/installer.sh"
listing() {
 printf 'Installer.app/Contents/Info.plist\n'
 local i
 for ((i=0; i<20000; i++)); do printf 'long-entry-%s-padding-padding-padding-padding.txt\n' "$i"; done
 echo COMPLETED >> "$TRACE"
}
run_with_timeout() { shift; "$@"; }
ZIP_LIST_CMD=(listing)
rc=0
is_installer_zip "$HOME/private.zip" || rc=$?
printf 'RC=%s\n' "$rc"
cat "$TRACE"
listing_late() { local i; for ((i=0; i<50; i++)); do echo document.txt; done; echo Installer.app/Contents; }
ZIP_LIST_CMD=(listing_late)
rc=0; is_installer_zip "$HOME/late.zip" || rc=$?; printf 'LATE=%s\n' "$rc"
listing_failed() { echo Installer.app/Contents; return 1; }
ZIP_LIST_CMD=(listing_failed)
rc=0; is_installer_zip "$HOME/broken.zip" || rc=$?; printf 'FAILED=%s\n' "$rc"
SH
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"RC=0"* && "$output" == *"COMPLETED"* && "$output" == *"LATE=1"* && "$output" == *"FAILED=1"* ]]
}

@test "installer size cancellation stops before any sink and the otherwise eligible next probe" {
    for rc in 130 143; do
        run env RC="$rc" /bin/bash << 'SH'
: > "$TRACE"
export MOLE_TEST_MODE=1
source "$PROJECT_ROOT/bin/installer.sh"
first="$HOME/size-first.dmg"; second="$HOME/size-second.dmg"
printf first > "$first"; printf second > "$second"
INSTALLER_DELETE_PATHS=("$first" "$second")
INSTALLER_DELETE_SIZES=(5 6)
INSTALLER_DELETE_IDENTITIES=("$(mole_deletion_identity "$first")" "$(mole_deletion_identity "$second")")
reset_installer_delete_results
installer_file_size_bytes() {
 printf 'SIZE:%s\n' "$1" >> "$TRACE"
 if [[ "$1" == "$first" ]]; then return "$RC"; fi
 printf '6\n'
}
mole_delete() { printf 'SINK:%s\n' "$1" >> "$TRACE"; command rm -f "$1"; }
rc=0; execute_installer_delete_plan || rc=$?
printf 'RC=%s\n' "$rc"
cat "$TRACE"
[[ -f "$first" && -f "$second" ]] || exit 1
# Positive control uses the same fixture and gives both probes known sizes.
installer_file_size_bytes() { if [[ "$1" == "$first" ]]; then printf '5\n'; else printf '6\n'; fi; }
reset_installer_delete_results
execute_installer_delete_plan || exit $?
[[ $total_deleted -eq 2 && ! -e "$first" && ! -e "$second" ]] || exit 1
echo POSITIVE_DELETED=2
SH
        [ "$status" -eq 0 ] || {
            echo "$output"
            return 1
        }
        [[ "$output" == *"RC=$rc"* && "$output" == *"SIZE:$HOME/size-first.dmg"* && "$output" != *"SIZE:$HOME/size-second.dmg"* ]] || return 1
        [[ "$output" != *"SINK:"* && "$output" == *"POSITIVE_DELETED=2"* ]] || return 1
    done
}

@test "automation profile owner states and post-size changes fail closed with idle positive control" {
    run /bin/bash << 'SH'
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
MOLE_CURRENT_COMMAND=clean
note_activity() { :; }; stop_section_spinner() { :; }; start_section_spinner() { :; }
update_progress_if_needed() { return 1; }
root="$HOME/profiles"
mkdir -p "$root"
profile="$root/playwright_chromiumdev_profile-test"
owner_state=1; size_mode=idle
run_with_timeout() {
 local timeout="$1"; shift
 if [[ "$1" == pgrep ]]; then return "$owner_state"; fi
 "$@"
}
get_cleanup_path_size_kb() {
 printf 'SIZE:%s\n' "$1" >> "$TRACE"
 if [[ "$size_mode" == started ]]; then printf active > "$HOME/owner-started"; fi
 if [[ "$size_mode" == swapped ]]; then mv "$profile" "$profile-old"; mkdir "$profile"; printf replacement > "$profile/sentinel"; fi
 printf '1\n'
}
# owner state must be observable across the size probe command substitution.
run_with_timeout() {
 local timeout="$1"; shift
 if [[ "$1" == pgrep ]]; then
  [[ ! -e "$HOME/owner-started" ]] || return 0
  return "$owner_state"
 fi
 "$@"
}
trial() {
 mkdir -p "$profile"; printf fixture > "$profile/sentinel"
 _mole_snapshot_path_identity "$profile" || exit 1
 local _MOLE_AUTOMATION_PROFILE="$profile"
 local _MOLE_AUTOMATION_PARENT="$_MOLE_PATH_SNAPSHOT_PARENT"
 local _MOLE_AUTOMATION_PARENT_ID="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
 local _MOLE_AUTOMATION_TARGET_ID="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
 MOLE_CLEAN_CANCEL_STATUS=0
 rc=0
 _dev_safe_clean_process_guarded _automation_profile_cleanup_state automation automation "$profile" automation || rc=$?
 printf 'STATE=%s MODE=%s RC=%s EXISTS=%s\n' "$owner_state" "$size_mode" "$rc" "$(test -d "$profile" && echo yes || echo no)"
}
for owner_state in 0 2; do
 trial
 [[ -f "$profile/sentinel" ]] || exit 1
done
owner_state=1
for size_mode in started swapped; do
 trial
 [[ -f "$profile/sentinel" ]] || exit 1
 command rm -f "$HOME/owner-started" # SAFE: exact private marker owned by this test
 done
size_mode=idle
trial
[[ ! -e "$profile" ]] || exit 1
echo POSITIVE_IDLE_REMOVED
SH
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"STATE=0 MODE=idle"* && "$output" == *"STATE=2 MODE=idle"* && "$output" == *"MODE=started"* && "$output" == *"MODE=swapped"* && "$output" == *"POSITIVE_IDLE_REMOVED"* ]]
}
