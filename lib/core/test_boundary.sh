#!/bin/bash
# Internal test contract. This is not a cleanup option or a user preference.
# The runner also applies a kernel sandbox; this gate makes escaped fixture
# targets observable even when a test replaces the process or policy probes.

_mole_test_boundary_required() {
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ||
        -n "${MOLE_TEST_RUN_ROOT:-}" ]]; then
        return 0
    fi
    # Bats exports these supported fields to setup and test subprocesses.
    # Check its concrete file/run directory, never process-name heuristics.
    [[ -n "${BATS_TEST_FILENAME:-}" && -n "${BATS_RUN_TMPDIR:-}" &&
        -f "$BATS_TEST_FILENAME" && -d "$BATS_RUN_TMPDIR" ]]
}

_mole_test_boundary_refuse() {
    printf 'mole test boundary refused (%s): %s\n' "$1" "$2" >&2
    printf 'Run tests through scripts/test_sandbox.sh bats <test files>.\n' >&2
    return 16
}

_mole_test_require_context() {
    _mole_test_boundary_required || return 0
    _mole_test_guard_mutation_path "${MOLE_TEST_RUN_ROOT:-}/.context-check"
}

_mole_test_guard_mutation_path() {
    _mole_test_boundary_required || return 0
    local path="${1%/}"
    local root="${MOLE_TEST_RUN_ROOT:-}"
    local token="${MOLE_TEST_BOUNDARY_TOKEN:-}"
    local recorded_token=""
    if [[ -z "$root" || "$root" != /* || "$root" == / || -L "$root" ||
        -z "$token" || ! -f "$root/.test-boundary" || -L "$root/.test-boundary" ]]; then
        _mole_test_boundary_refuse missing-run-root "$1"
        return $?
    fi
    IFS= read -r recorded_token < "$root/.test-boundary" || recorded_token=""
    if [[ "$recorded_token" != "$token" ]]; then
        _mole_test_boundary_refuse invalid-run-root "$1"
        return $?
    fi
    case "$path" in
        "$root"/*) ;;
        *)
            _mole_test_boundary_refuse outside-fixture "$1"
            return $?
            ;;
    esac
    case "$path/" in
        */../* | */./* | *//*)
            _mole_test_boundary_refuse noncanonical-fixture "$1"
            return $?
            ;;
    esac
    if [[ -L "$path" && "$1" == */ ]]; then
        _mole_test_boundary_refuse symlink-traversal "$1"
        return $?
    fi
    # The leaf may itself be a symlink: unlinking that object is safe. Never
    # permit traversal through a symlink ancestor, including a replaced root.
    local ancestor="${path%/*}"
    while [[ "$ancestor" != / && -n "$ancestor" ]]; do
        if [[ -L "$ancestor" ]]; then
            _mole_test_boundary_refuse symlink-ancestor "$1"
            return $?
        fi
        [[ "$ancestor" == "$root" ]] && return 0
        ancestor="${ancestor%/*}"
    done
    _mole_test_boundary_refuse invalid-run-root "$1"
}
