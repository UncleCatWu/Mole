#!/usr/bin/env bats
setup_file() { export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"; }

@test "Application Support intermediate Crashpad symlink never reaches preview while a real sibling does" {
    run env HOME="$BATS_TEST_TMPDIR/home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME/.config/mole"
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=true
MOLE_CURRENT_COMMAND=clean
MOLE_CLEAN_CANCEL_STATUS=0
WHITELIST_PATTERNS=()
WHITELIST_WARNINGS=()
start_section_spinner() { :; }
stop_section_spinner() { :; }
update_progress_if_needed() { :; }
note_activity() { :; }
app="$HOME/Library/Application Support/TestApp"
outside="$HOME/Documents/authored"
mkdir -p "$app/GPUCache" "$outside/completed"
printf authored > "$outside/completed/PRIVATE_SENTINEL"
printf cache > "$app/GPUCache/cache.bin"
ln -s "$outside" "$app/Crashpad"
prepare_clean_preview_file
_MOLE_APP_SUPPORT_DEADLINE=$((SECONDS + 30))
size_timeout_seconds=0.4
total_size_bytes=0
total_size_partial=false
cleaned_count=0
found_any=false
_clean_app_support_candidate "$app/Crashpad/completed" first
_clean_app_support_candidate "$app/GPUCache" positive
while IFS= read -r -d '' identity && IFS= read -r -d '' size && IFS= read -r -d '' count && IFS= read -r -d '' known && IFS= read -r -d '' section && IFS= read -r -d '' path; do
    printf 'PREVIEW:%s\n' "$path"
done < "$CLEAN_PREVIEW_LEDGER_FILE"
printf 'COMPLETED_CANDIDATES=%s\n' "$cleaned_count"
[[ -f "$outside/completed/PRIVATE_SENTINEL" ]] || exit 1
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"PREVIEW:"*"Crashpad/completed"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"PREVIEW:"*"GPUCache/cache.bin"* ]] || return 1
    [[ "$output" == *"COMPLETED_CANDIDATES=1"* ]] || return 1
}

@test "Application Support rebinds candidate after scan and after sizing before preview" {
    for phase in scan size; do
        run env HOME="$BATS_TEST_TMPDIR/$phase" PROJECT_ROOT="$PROJECT_ROOT" PHASE="$phase" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME/.config/mole"
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=true
MOLE_CURRENT_COMMAND=clean
WHITELIST_PATTERNS=()
WHITELIST_WARNINGS=()
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
app="$HOME/Library/Application Support/TestApp"
outside="$HOME/Documents/authored"
mkdir -p "$app/Crashpad/completed" "$app/GPUCache" "$outside/completed"
printf cache > "$app/Crashpad/completed/a"
printf authored > "$outside/completed/a"
printf cache > "$app/GPUCache/positive"
swap() {
    if [[ ! -L "$app/Crashpad" ]]; then
        mv "$app/Crashpad" "$app/RetainedCrashpad"
        ln -s "$outside" "$app/Crashpad"
    fi
}
eval "$(declare -f _app_support_scan_entries | sed '1s/_app_support_scan_entries/_original_support_scan/')"
eval "$(declare -f app_support_item_size_bytes | sed '1s/app_support_item_size_bytes/_original_support_size/')"
_app_support_scan_entries() {
    _original_support_scan "$@" || return $?
    if [[ "$PHASE" == scan && "$1" == "$app/Crashpad/completed" ]]; then swap; fi
}
app_support_item_size_bytes() {
    _original_support_size "$@" || return $?
    if [[ "$PHASE" == size && "$1" == "$app/Crashpad/completed/a" ]]; then swap; fi
}
prepare_clean_preview_file
_MOLE_APP_SUPPORT_DEADLINE=$((SECONDS + 30))
size_timeout_seconds=0.4
total_size_bytes=0
total_size_partial=false
cleaned_count=0
found_any=false
_clean_app_support_candidate "$app/Crashpad/completed" race
_clean_app_support_candidate "$app/GPUCache" positive
while IFS= read -r -d '' id && IFS= read -r -d '' size && IFS= read -r -d '' count && IFS= read -r -d '' known && IFS= read -r -d '' section && IFS= read -r -d '' path; do
    printf 'PREVIEW:%s\n' "$path"
done < "$CLEAN_PREVIEW_LEDGER_FILE"
printf 'COUNT=%s PHASE=%s\n' "$cleaned_count" "$PHASE"
[[ -f "$outside/completed/a" && -f "$app/RetainedCrashpad/completed/a" ]] || exit 1
EOF
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        [[ "$output" != *"PREVIEW:"*"Crashpad/completed"* ]] || { echo "$output"; return 1; }
        [[ "$output" == *"PREVIEW:"*"GPUCache/positive"* && "$output" == *"COUNT=1"* ]] || return 1
    done
}

@test "Application Support composes the existing final guard and preserves sticky cancellation" {
    for guard_rc in 124 130; do
        run env HOME="$BATS_TEST_TMPDIR/guard-$guard_rc" PROJECT_ROOT="$PROJECT_ROOT" GUARD_RC="$guard_rc" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME/.config/mole"
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
MOLE_CURRENT_COMMAND=clean
MOLE_CLEAN_CANCEL_STATUS=0
WHITELIST_PATTERNS=()
WHITELIST_WARNINGS=()
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
candidate="$HOME/Library/Application Support/TestApp/GPUCache"
mkdir -p "$candidate"
printf a > "$candidate/a"
printf b > "$candidate/b"
eval "$(declare -f app_support_item_size_bytes | sed '1s/app_support_item_size_bytes/_real_support_size/')"
eval "$(declare -f safe_remove | sed '1s/safe_remove/_real_support_remove/')"
app_support_item_size_bytes() { printf 'SIZE:%s\n' "${1##*/}" >> "$HOME/guard.trace"; _real_support_size "$@"; }
safe_remove() { printf 'SINK:%s\n' "${1##*/}" >> "$HOME/guard.trace"; _real_support_remove "$@"; }
prior_guard() {
    printf 'PRIOR:%s\n' "${1##*/}" >> "$HOME/guard.trace"
    if [[ "${1##*/}" == a ]]; then return "$GUARD_RC"; fi
    return 0
}
_MOLE_SAFE_REMOVE_FINAL_GUARD=prior_guard
_MOLE_APP_SUPPORT_DEADLINE=$((SECONDS + 30))
size_timeout_seconds=0.4
total_size_bytes=0
total_size_partial=false
cleaned_count=0
found_any=false
rc=0
_clean_app_support_candidate "$candidate" guard || rc=$?
printf 'RC=%s CANCEL=%s COUNT=%s\n' "$rc" "$MOLE_CLEAN_CANCEL_STATUS" "$cleaned_count"
cat "$HOME/guard.trace"
[[ -f "$candidate/a" && -f "$candidate/b" ]] || exit 1

EOF
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        [[ "$output" == *"RC=$guard_rc CANCEL=$guard_rc COUNT=0"* ]] || { echo "$output"; return 1; }
        [[ "$output" == *"PRIOR:a"* && "$output" != *"PRIOR:b"* ]] || return 1
        [[ "$output" == *"SIZE:a"* && "$output" == *"SINK:a"* ]] || return 1
        [[ "$output" != *"SIZE:b"* && "$output" != *"SINK:b"* ]] || return 1
    done
}

@test "Application Support native preview rejects replacement during its real admission probe" {
    run env HOME="$BATS_TEST_TMPDIR/admission" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME/.config/mole"
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=true
MOLE_CURRENT_COMMAND=clean
WHITELIST_PATTERNS=()
WHITELIST_WARNINGS=()
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
app="$HOME/Library/Application Support/TestApp"
outside="$HOME/Documents/authored"
mkdir -p "$app/Crashpad/completed" "$app/GPUCache" "$outside/completed"
printf cache > "$app/Crashpad/completed/a"
printf authored > "$outside/completed/a"
printf cache > "$app/GPUCache/positive"
_mole_should_refuse_live_user_cache_path() {
    if [[ "$1" == "$app/Crashpad/completed/a" && ! -L "$app/Crashpad" ]]; then
        mv "$app/Crashpad" "$app/RetainedCrashpad"
        ln -s "$outside" "$app/Crashpad"
        printf 'ADMISSION_SWAP\n' >> "$HOME/admission.trace"
    fi
    return 1
}
prepare_clean_preview_file
_MOLE_APP_SUPPORT_DEADLINE=$((SECONDS + 30))
size_timeout_seconds=0.4
total_size_bytes=0
total_size_partial=false
cleaned_count=0
found_any=false
_clean_app_support_candidate "$app/Crashpad/completed" admission
_clean_app_support_candidate "$app/GPUCache" positive
while IFS= read -r -d '' id && IFS= read -r -d '' size && IFS= read -r -d '' count && IFS= read -r -d '' known && IFS= read -r -d '' section && IFS= read -r -d '' path; do printf 'PREVIEW:%s\n' "$path"; done < "$CLEAN_PREVIEW_LEDGER_FILE"
cat "$HOME/admission.trace"
printf 'COUNT=%s\n' "$cleaned_count"
[[ -f "$outside/completed/a" ]] || exit 1
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"ADMISSION_SWAP"* && "$output" == *"GPUCache/positive"* ]] || return 1
    [[ "$output" != *"PREVIEW:"*"Crashpad/completed"* && "$output" == *"COUNT=1"* ]] || { echo "$output"; return 1; }
}

@test "Application Support independent real helper and sink accept an otherwise eligible b" {
    run env HOME="$BATS_TEST_TMPDIR/independent-b" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME/.config/mole"
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
MOLE_CURRENT_COMMAND=clean
MOLE_CLEAN_CANCEL_STATUS=0
WHITELIST_PATTERNS=()
WHITELIST_WARNINGS=()
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
candidate="$HOME/Library/Application Support/TestApp/GPUCache"
mkdir -p "$candidate"
printf cache > "$candidate/b"
prior_guard() { printf 'PRIOR:%s\n' "${1##*/}" >> "$HOME/trace"; return 0; }
_MOLE_SAFE_REMOVE_FINAL_GUARD=prior_guard
_MOLE_APP_SUPPORT_DEADLINE=$((SECONDS + 30))
size_timeout_seconds=0.4
total_size_bytes=0
total_size_partial=false
cleaned_count=0
found_any=false
_clean_app_support_candidate "$candidate" positive
cat "$HOME/trace"
printf 'COUNT=%s CANCEL=%s\n' "$cleaned_count" "$MOLE_CLEAN_CANCEL_STATUS"
[[ ! -e "$candidate/b" ]] || exit 1
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"PRIOR:b"* && "$output" == *"COUNT=1 CANCEL=0"* ]] || return 1
}

@test "Application Support native preview rejects a same-path item replacement during admission" {
    run env HOME="$BATS_TEST_TMPDIR/admission" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME/.config/mole"
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=true
MOLE_CURRENT_COMMAND=clean
WHITELIST_PATTERNS=()
WHITELIST_WARNINGS=()
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
app="$HOME/Library/Application Support/TestApp"
outside="$HOME/Documents/authored"
mkdir -p "$app/Crashpad/completed" "$app/GPUCache" "$outside/completed"
printf cache > "$app/Crashpad/completed/a"
printf authored > "$outside/completed/a"
printf cache > "$app/GPUCache/positive"
_mole_should_refuse_live_user_cache_path() {
    if [[ "$1" == "$app/Crashpad/completed/a" && ! -L "$app/Crashpad" ]]; then
        if [[ ! -f "$1.retained" ]]; then
            mv "$1" "$1.retained"
            printf replacement > "$1"
        fi
        printf 'ADMISSION_SWAP\n' >> "$HOME/admission.trace"
    fi
    return 1
}
prepare_clean_preview_file
_MOLE_APP_SUPPORT_DEADLINE=$((SECONDS + 30))
size_timeout_seconds=0.4
total_size_bytes=0
total_size_partial=false
cleaned_count=0
found_any=false
_clean_app_support_candidate "$app/Crashpad/completed" admission
_clean_app_support_candidate "$app/GPUCache" positive
while IFS= read -r -d '' id && IFS= read -r -d '' size && IFS= read -r -d '' count && IFS= read -r -d '' known && IFS= read -r -d '' section && IFS= read -r -d '' path; do printf 'PREVIEW:%s\n' "$path"; done < "$CLEAN_PREVIEW_LEDGER_FILE"
cat "$HOME/admission.trace"
printf 'COUNT=%s\n' "$cleaned_count"
[[ -f "$outside/completed/a" ]] || exit 1
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"ADMISSION_SWAP"* && "$output" == *"GPUCache/positive"* ]] || return 1
    [[ "$output" != *"PREVIEW:"*"Crashpad/completed"* && "$output" == *"COUNT=1"* ]] || { echo "$output"; return 1; }
}

