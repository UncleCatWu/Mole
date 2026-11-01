#!/bin/bash
# Shared runner seam, used by the full test runner and report regressions.
mole_run_reported_bats() {
    local part rc=0 bats_entry=bats
    # Bats prepends its internal executor to PATH. Nested runs need the public
    # bootstrap instead of relying on functions inherited from a parent shell.
    if [[ -n "${BATS_ROOT:-}" && -x "$BATS_ROOT/bin/bats" ]]; then
        bats_entry="$BATS_ROOT/bin/bats"
    fi
    _mole_test_guard_mutation_path "$MOLE_TEST_REPORT_DIR/parts" || return $?
    mkdir -p "$MOLE_TEST_REPORT_DIR" || return $?
    part=$(mktemp -d "$MOLE_TEST_REPORT_DIR/part.XXXXXX") || return $?
    printf '%s\n' "$part" >> "$MOLE_TEST_REPORT_DIR/parts" || return $?
    MOLE_TEST_BATS_PART_DIR="$part" "$bats_entry" --timing --formatter \
        "$PROJECT_ROOT/tests/support/bats_report_formatter.sh" "$@" || rc=$?
    printf '%s\n' "$rc" > "$part/bats-exit-status" || return $?
    return "$rc"
}

mole_finish_bats_report() {
    python3 -B "$PROJECT_ROOT/tests/support/bats_report.py" merge "$MOLE_TEST_REPORT_DIR"
}
