#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
    export PROJECT_ROOT
    HOME="$BATS_TEST_TMPDIR/home"
    export HOME
    mkdir -p "$HOME"
}

@test "safe_remove reports only acknowledged fixture removal as removed" {
    run /bin/bash -euo pipefail -c '
        source "$PROJECT_ROOT/lib/core/common.sh"
        mkdir -p "$HOME/tree/nested"
        printf fixture > "$HOME/tree/nested/item"
        safe_remove "$HOME/tree" true 0 || exit $?
        printf "OUTCOME=%s\n" "$_MOLE_SAFE_REMOVE_OUTCOME"
        [[ "$_MOLE_SAFE_REMOVE_OUTCOME" == removed && ! -e "$HOME/tree" ]] || exit 1
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"OUTCOME=removed"* ]]
}

@test "safe_remove missing and preview successes never imply completed removal" {
    run /bin/bash -euo pipefail -c '
        source "$PROJECT_ROOT/lib/core/common.sh"
        _MOLE_SAFE_REMOVE_OUTCOME=removed
        safe_remove "$HOME/missing" true 0 || exit $?
        [[ "$_MOLE_SAFE_REMOVE_OUTCOME" == missing ]] || exit 1
        printf "MISSING=%s\n" "$_MOLE_SAFE_REMOVE_OUTCOME"
        printf fixture > "$HOME/preview"
        MOLE_DRY_RUN=1 safe_remove "$HOME/preview" true 0 || exit $?
        [[ "$_MOLE_SAFE_REMOVE_OUTCOME" == preview && -f "$HOME/preview" ]] || exit 1
        printf "PREVIEW=%s\n" "$_MOLE_SAFE_REMOVE_OUTCOME"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"MISSING=missing"* ]] || return 1
    [[ "$output" == *"PREVIEW=preview"* ]]
}

@test "safe_remove rejects false completion from a successful no-op sink" {
    run /bin/bash -euo pipefail -c '
        source "$PROJECT_ROOT/lib/core/common.sh"
        log_operation() { printf "LOG:%s:%s\n" "$2" "$4"; }
        printf fixture > "$HOME/no-op"
        rm() { return 0; }
        safe_remove "$HOME/no-op" true 0 || exit $?
        [[ "$_MOLE_SAFE_REMOVE_OUTCOME" == not_removed && -f "$HOME/no-op" ]] || exit 1
        printf "NOOP=%s\n" "$_MOLE_SAFE_REMOVE_OUTCOME"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOOP=not_removed"* && "$output" != *"LOG:REMOVED"* && "$output" == *"LOG:SKIPPED:removal not completed"* ]]
}

@test "safe_remove does not claim an unacknowledged concurrent disappearance" {
    run /bin/bash -euo pipefail -c '
        source "$PROJECT_ROOT/lib/core/common.sh"
        log_operation() { printf "LOG:%s:%s\n" "$2" "$4"; }
        printf fixture > "$HOME/disappeared"
        rm() { /bin/rm -f "${@: -1}"; return 0; }
        safe_remove "$HOME/disappeared" true 0 || exit $?
        [[ "$_MOLE_SAFE_REMOVE_OUTCOME" == not_observed && ! -e "$HOME/disappeared" ]] || exit 1
        printf "UNACKNOWLEDGED=%s\n" "$_MOLE_SAFE_REMOVE_OUTCOME"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"UNACKNOWLEDGED=not_observed"* && "$output" != *"LOG:REMOVED"* && "$output" == *"LOG:SKIPPED:removal not observed"* ]]
}

@test "safe_remove outcome distinguishes refusal failure and cancellation" {
    run /bin/bash -euo pipefail -c '
        source "$PROJECT_ROOT/lib/core/common.sh"
        printf fixture > "$HOME/kept"
        WHITELIST_PATTERNS=("$HOME/kept")
        rc=0; safe_remove "$HOME/kept" true 0 || rc=$?
        [[ $rc -eq 1 && "$_MOLE_SAFE_REMOVE_OUTCOME" == refused && -f "$HOME/kept" ]] || exit 1
        printf "REFUSAL=%s\n" "$_MOLE_SAFE_REMOVE_OUTCOME"
        WHITELIST_PATTERNS=()
        # A best-effort caller may disable pipefail; the observer must not
        # replace rm status with its own successful EOF status.
        set +o pipefail
        rm() { return 1; }
        rc=0; safe_remove "$HOME/kept" true 0 || rc=$?
        [[ $rc -eq 1 && "$_MOLE_SAFE_REMOVE_OUTCOME" == failed && -f "$HOME/kept" ]] || exit 1
        printf "FAILURE=%s\n" "$_MOLE_SAFE_REMOVE_OUTCOME"
        rm() { return 130; }
        rc=0; safe_remove "$HOME/kept" true 0 || rc=$?
        [[ $rc -eq 130 && "$_MOLE_SAFE_REMOVE_OUTCOME" == cancelled && -f "$HOME/kept" ]] || exit 1
        printf "CANCELLATION=%s\n" "$_MOLE_SAFE_REMOVE_OUTCOME"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"REFUSAL=refused"* ]] || return 1
    [[ "$output" == *"FAILURE=failed"* ]] || return 1
    [[ "$output" == *"CANCELLATION=cancelled"* ]]
}

@test "rm receipt drains nonstandard child fragments with bounded diagnostics and late permission cause" {
    run /bin/bash -euo pipefail -c '
        source "$PROJECT_ROOT/lib/core/common.sh"
        target="$HOME/tree"
        producer() {
            for ((i=0; i<12000; i++)); do printf "nonstandard child fragment %s padding padding padding\n" "$i"; done
            printf "rm: %s: Permission denied\n" "$target"
            printf "%s\n" "$target"
            printf DRAINED > "$HOME/drained"
        }
        receipt=$(producer | _mole_capture_rm_receipt "$target")
        [[ -f "$HOME/drained" ]] || exit 1
        [[ ${#receipt} -le 4700 ]] || exit 1
        [[ "$receipt" == *"Permission denied"* && "$receipt" == *"__MOLE_RM_TARGET_REMOVED__" ]] || exit 1
        printf "BYTES=%s DRAINED=yes PERMISSION=yes\n" "${#receipt}"
    '
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"DRAINED=yes PERMISSION=yes"* ]]
}

@test "mole_delete starts independent safe_remove and Trash routes with no inherited receipt" {
    run /bin/bash -euo pipefail -c '
        source "$PROJECT_ROOT/lib/core/common.sh"
        _MOLE_SAFE_REMOVE_OUTCOME=removed
        printf fixture > "$HOME/permanent"
        safe_remove() {
            [[ "$_MOLE_SAFE_REMOVE_OUTCOME" == "" ]] || return 1
            printf PERMANENT_RECEIPT_EMPTY\\n
            return 0
        }
        rc=0; mole_delete "$HOME/permanent" || rc=$?
        [[ $rc -eq 1 ]] || exit 1
        printf fixture > "$HOME/trash"
        _mole_move_to_trash() {
            [[ "$_MOLE_SAFE_REMOVE_OUTCOME" == "" ]] || return 1
            printf TRASH_RECEIPT_EMPTY\\n
            command rm -f "$1" # SAFE: exact private fixture mocking the Trash sink
        }
        MOLE_DELETE_MODE=trash mole_delete "$HOME/trash" || exit $?
    '
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *PERMANENT_RECEIPT_EMPTY* && "$output" == *TRASH_RECEIPT_EMPTY* ]]
}

@test "mole_delete forensic result rejects no-op and unacknowledged disappearance then admits exact removal" {
    run /bin/bash -euo pipefail -c '
        source "$PROJECT_ROOT/lib/core/common.sh"
        _mole_delete_log() { printf "FORENSIC:%s:%s:%s\n" "$1" "$2" "$3"; }
        get_path_size_kb() { printf "17\n"; }
        printf fixture > "$HOME/no-op"
        rm() { return 0; }
        rc=0; mole_delete "$HOME/no-op" || rc=$?
        [[ $rc -eq 1 && -f "$HOME/no-op" ]] || exit 1
        printf fixture > "$HOME/unacknowledged"
        rm() { /bin/rm -f "${@: -1}"; return 0; }
        rc=0; mole_delete "$HOME/unacknowledged" || rc=$?
        [[ $rc -eq 1 && ! -e "$HOME/unacknowledged" ]] || exit 1
        unset -f rm
        printf fixture > "$HOME/confirmed"
        mole_delete "$HOME/confirmed" || exit $?
        [[ ! -e "$HOME/confirmed" ]] || exit 1
    '
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *FORENSIC:permanent:0:not-removed* && "$output" == *FORENSIC:permanent:unknown:not-observed* && "$output" == *FORENSIC:permanent:17:ok* ]]
}
