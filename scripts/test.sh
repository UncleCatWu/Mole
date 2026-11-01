#!/bin/bash
# Test runner for Mole.
# Runs unit, Go, and integration tests.
# Exits non-zero on failures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# The outer invocation only starts the test sandbox. All test setup, lint,
# fixtures, module loading, and cleanup then happen in its private snapshot.
if [[ -z "${MOLE_TEST_SANDBOX_ACTIVE:-}" ||
    "${MOLE_TEST_SANDBOX_ACTIVE:-}" != "${MOLE_TEST_BOUNDARY_TOKEN:-}" ||
    "$SCRIPT_DIR" != "${MOLE_TEST_RUN_ROOT:-}/"* ]]; then
    exec /bin/bash "$SCRIPT_DIR/test_sandbox.sh" /bin/bash scripts/test.sh "$@"
fi
cd "$PROJECT_ROOT"
# shellcheck source=lib/core/test_boundary.sh
source "$PROJECT_ROOT/lib/core/test_boundary.sh"
_mole_test_guard_mutation_path "$SCRIPT_DIR/runner-identity" || exit $?

# Never allow the scripted test run to trigger real sudo or Touch ID prompts.
export MOLE_TEST_NO_AUTH=1

# Tests assert deterministic ANSI escape output. The suite runs without a
# terminal, so lib/core/base.sh would otherwise drop color; the MOLE_TEST_NO_AUTH
# export above is what forces it back on. Strip any NO_COLOR the developer has
# set in their shell, since that still wins over the force, so the color-escape
# assertions match regardless of the host environment.
unset NO_COLOR

TEST_SYSTEM_STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mole-test-stubs.XXXXXX")"
TEST_SYSTEM_STUB_DIR="$(cd -P "$TEST_SYSTEM_STUB_DIR" && pwd -P)"
TEST_GO_HELPER_DIR=""
# shellcheck disable=SC2329  # Invoked by trap.
cleanup_test_stubs() {
    rm -rf "$TEST_SYSTEM_STUB_DIR" # SAFE: exact mktemp-created test stub directory
    if [[ -n "$TEST_GO_HELPER_DIR" ]]; then
        rm -rf "$TEST_GO_HELPER_DIR" # SAFE: exact mktemp-created Go helper directory
    fi
    prune_test_launchservices || true
}

# Spotlight indexes tests/tmp-* within seconds and registers every fixture
# .app with LaunchServices; deleting the fixture leaves the record behind.
# Thousands of dead records slow every `lsregister -dump`, which Mole Mac's
# uninstall reads (66,532 of them made each read take 36 to 56 s,
# 2026-10-26). Unregister only records under tests/ whose bundle is gone.
# shellcheck disable=SC2329  # Invoked by cleanup_test_stubs.
prune_test_launchservices() {
    local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    [[ -x "$lsregister" ]] || return 0
    "$lsregister" -dump Bundle 2> /dev/null |
        sed -n -E 's/^path: +(.*) \(0x[0-9a-f]+\)$/\1/p' |
        while IFS= read -r path; do
            [[ "$path" == "$PROJECT_ROOT/tests/"* ]] || continue
            [[ -e "$path" || -L "$path" ]] || printf '%s\0' "$path"
        done |
        xargs -0 -n 200 "$lsregister" -u > /dev/null 2>&1
}
trap cleanup_test_stubs EXIT

# Module-loading and installation probes run outside the Bats helper too.
# Keep their temp registries and stale-temp pruning inside this owned tree.
mkdir -p "$TEST_SYSTEM_STUB_DIR/tmp"
export TMPDIR="$TEST_SYSTEM_STUB_DIR/tmp"
unset MOLE_RESOLVED_TMPDIR MOLE_TEMP_REGISTRY_FILE

cat > "$TEST_SYSTEM_STUB_DIR/sudo" << 'EOF'
#!/bin/bash
case "${1:-}" in
    -k)
        exit 0
        ;;
    -n)
        exit 1
        ;;
esac

printf 'mole test blocked sudo: %s\n' "$*" >&2
exit 1
EOF

cat > "$TEST_SYSTEM_STUB_DIR/osascript" << 'EOF'
#!/bin/bash
printf 'mole test blocked osascript: %s\n' "$*" >&2
exit 1
EOF

cat > "$TEST_SYSTEM_STUB_DIR/launchctl" << 'EOF'
#!/bin/bash
printf 'mole test blocked launchctl: %s\n' "$*" >&2
exit 0
EOF

chmod +x "$TEST_SYSTEM_STUB_DIR/sudo" "$TEST_SYSTEM_STUB_DIR/osascript" "$TEST_SYSTEM_STUB_DIR/launchctl"
export PATH="$TEST_SYSTEM_STUB_DIR:$PATH"

# shellcheck source=lib/core/file_ops.sh
source "$PROJECT_ROOT/lib/core/file_ops.sh"

echo "==============================="
echo "Mole Test Runner"
echo "==============================="
echo ""

FAILED=0

enforce_timeout_dependency_in_ci() {
    if [[ "${CI:-}" != "true" && "${GITHUB_ACTIONS:-}" != "true" ]]; then
        return 0
    fi

    if command -v gtimeout > /dev/null 2>&1 || command -v timeout > /dev/null 2>&1; then
        return 0
    fi

    printf '%b' "${RED}${ICON_ERROR} Missing timeout binary (gtimeout/timeout) in CI${NC}\n"
    printf '%b' "${YELLOW}${ICON_WARNING} Install coreutils to provide gtimeout${NC}\n"
    exit 1
}

# Print the slowest test files from the JUnit report written during the run.
# Attribution is per file, which is what a parallel run hides: wall clock is
# set by the single slowest file, not by the total.
report_slowest_test_files() {
    local report="${MOLE_TEST_REPORT_DIR:-}/report.xml"
    [[ -n "${MOLE_TEST_REPORT_DIR:-}" && -f "$report" ]] || return 0

    printf "\n%s\n" "Slowest test files (seconds):"
    sed -n 's/.*<testsuite name="\([^"]*\)".*time="\([0-9.]*\)".*/\2 \1/p' "$report" |
        sort -rn | head -n 10 |
        awk '{ printf "  %8.1f  %s\n", $1, $2 }'
}

report_unit_result() {
    if [[ $1 -eq 0 ]]; then
        printf '%b' "${GREEN}${ICON_SUCCESS} Unit tests passed${NC}\n"
    else
        printf '%b' "${RED}${ICON_ERROR} Unit tests failed${NC}\n"
        FAILED=$((FAILED + 1))
    fi
}

enforce_timeout_dependency_in_ci

GO_TEST_CACHE="$MOLE_TEST_RUN_ROOT/go-cache"
export MOLE_GO_TEST_CACHE="$GO_TEST_CACHE"

test_selection_needs_go_helpers() {
    local test_file
    for test_file in "$@"; do
        case "$test_file" in
            tests | ./tests | */tests | tests/cli.bats | ./tests/cli.bats | */tests/cli.bats)
                return 0
                ;;
        esac
    done
    return 1
}

prepare_go_test_helpers() {
    command -v go > /dev/null 2>&1 || return 0

    TEST_GO_HELPER_DIR="$(mktemp -d "${TMPDIR%/}/mole-go-helpers.XXXXXX")"
    mkdir -p "$GO_TEST_CACHE"

    # shellcheck source=tests/support/build_go_cli_helpers.sh
    source "$PROJECT_ROOT/tests/support/build_go_cli_helpers.sh"
    mole_build_go_cli_helpers "$TEST_GO_HELPER_DIR" || return $?
}

echo "1. Linting test scripts..."
if command -v shellcheck > /dev/null 2>&1; then
    # Concurrent Bats runs own tests/tmp-* fixtures, not lint inputs.
    TEST_FILES=()
    while IFS= read -r file; do
        TEST_FILES+=("$file")
    done < <(find tests -type d -path 'tests/tmp-*' -prune -o -type f \( -name '*.bats' -o -name '*.bash' -o -name '*.sh' \) -print | sort)
    if [[ ${#TEST_FILES[@]} -gt 0 ]]; then
        if shellcheck --rcfile "$PROJECT_ROOT/.shellcheckrc" "${TEST_FILES[@]}"; then
            printf '%b' "${GREEN}${ICON_SUCCESS} Test script lint passed${NC}\n"
        else
            printf '%b' "${RED}${ICON_ERROR} Test script lint failed${NC}\n"
            FAILED=$((FAILED + 1))
        fi
    else
        printf '%b' "${YELLOW}${ICON_WARNING} No test scripts found, skipping${NC}\n"
    fi
else
    printf '%b' "${YELLOW}${ICON_WARNING} shellcheck not installed, skipping${NC}\n"
fi
echo ""

echo "2. Running unit tests..."
if command -v bats > /dev/null 2>&1 && [ -d "tests" ]; then
    # bats needs a real terminfo entry; it exits 1 with zero assertions without
    # one. A non-interactive bash supplies TERM=dumb rather than leaving it
    # empty, so an emptiness check never fires for the case this guard exists
    # for, and `make test` reported "Unit tests failed" after running 28 of
    # 1935 assertions with nothing actually broken.
    if [[ -z "${TERM:-}" || "${TERM}" == "dumb" ]]; then
        export TERM="xterm-256color"
    fi
    if [[ $# -eq 0 ]]; then
        fd_available=0
        zip_available=0
        zip_list_available=0
        if command -v fd > /dev/null 2>&1; then
            fd_available=1
        fi
        if command -v zip > /dev/null 2>&1; then
            zip_available=1
        fi
        if command -v zipinfo > /dev/null 2>&1 || command -v unzip > /dev/null 2>&1; then
            zip_list_available=1
        fi

        TEST_FILES=()
        while IFS= read -r file; do
            case "$file" in
                tests/installer_fd.bats)
                    if [[ $fd_available -eq 1 ]]; then
                        TEST_FILES+=("$file")
                    fi
                    ;;
                tests/installer_zip.bats)
                    if [[ $zip_available -eq 1 && $zip_list_available -eq 1 ]]; then
                        TEST_FILES+=("$file")
                    fi
                    ;;
                *)
                    TEST_FILES+=("$file")
                    ;;
            esac
        done < <(find tests -type f -name '*.bats' | sort)

        if [[ ${#TEST_FILES[@]} -gt 0 ]]; then
            set -- "${TEST_FILES[@]}"
        else
            set -- tests
        fi
    fi
    if test_selection_needs_go_helpers "$@"; then
        prepare_go_test_helpers
    fi
    use_color=false
    if [[ -t 1 && "${TERM:-}" != "dumb" ]]; then
        use_color=true
    fi

    bats_help="$(bats --help 2>&1 || true)"
    bats_has_jobs=false
    bats_has_formatter=false
    if grep -q -- "--jobs" <<< "$bats_help"; then
        bats_has_jobs=true
    fi
    if grep -q -- "--formatter" <<< "$bats_help"; then
        bats_has_formatter=true
    fi

    # Enable parallel execution across test files when Bats and its backend support it.
    # Cap at 6 jobs by default to balance speed vs. system load during CI.
    bats_opts=()
    if $bats_has_jobs && { command -v parallel > /dev/null 2>&1 || command -v rush > /dev/null 2>&1; }; then
        _ncpu="$(sysctl -n hw.logicalcpu 2> /dev/null || nproc 2> /dev/null || echo 4)"
        if [[ "${MOLE_TEST_JOBS:-}" =~ ^[0-9]+$ && "${MOLE_TEST_JOBS:-0}" -gt 0 ]]; then
            _jobs="$MOLE_TEST_JOBS"
        else
            _jobs="$((_ncpu > 6 ? 6 : (_ncpu < 2 ? 2 : _ncpu)))"
        fi
        # --no-parallelize-within-files ensures each test file's tests run
        # sequentially (they share a $HOME set by setup_file and are not safe
        # to run concurrently). Parallelism is only across files.
        if [[ $_jobs -gt 1 ]]; then
            bats_opts+=("--jobs" "$_jobs" "--no-parallelize-within-files")
        fi
        unset _ncpu _jobs
    fi
    if [[ "${MOLE_TEST_TIMING:-0}" == "1" ]]; then
        bats_opts+=("--timing")
    fi

    # Per-file timings. Parallel TAP output cannot be attributed back to a file,
    # so one slow file is invisible until it dominates the whole run. The JUnit
    # report carries one <testsuite name= time=> per file; CI sets this and the
    # slowest files are printed after the run.
    if [[ -n "${MOLE_TEST_REPORT_DIR:-}" ]] && $bats_has_formatter; then
        mkdir -p "$MOLE_TEST_REPORT_DIR"
        # shellcheck source=tests/support/bats_report.sh
        source "$PROJECT_ROOT/tests/support/bats_report.sh"
    fi

    # Some test files include wall-clock timing assertions that are skewed by
    # CPU contention from parallel test workers. Safety/optimize fixtures also
    # use 1-2s subprocess budgets that must reach their mocked action first.
    # Project-cache stalled-root probes have a five-second outer alarm.
    # The uninstall and main-menu PTY cases depend on one-second
    # escape-sequence reads and real-terminal signal timing, and the history
    # load-time case compares wall-clock work. cli.bats, uninstall_review.bats
    # and history.bats each hold such a case and have gone red on main only
    # under the parallel batch, then passed unchanged on a serial rerun.
    # When parallel mode is active,
    # split them out to run sequentially after the parallel batch completes.
    _sequential_files=()
    if [[ ${#bats_opts[@]} -gt 0 ]]; then
        _all=("$@")
        _rest=()
        if [[ ${#_all[@]} -eq 1 && -d "${_all[0]}" ]]; then
            while IFS= read -r _f; do
                case "$_f" in
                    *core_performance.bats | *regression.bats | *core_safe_functions.bats | *clean_system_caches.bats | *optimize.bats | *uninstall_menu.bats | *cli.bats | *uninstall_review.bats | *history.bats) _sequential_files+=("$_f") ;;
                    *) _rest+=("$_f") ;;
                esac
            done < <(find "${_all[0]}" -type f -name '*.bats' | sort)
        else
            for _f in "${_all[@]}"; do
                case "$_f" in
                    *core_performance.bats | *regression.bats | *core_safe_functions.bats | *clean_system_caches.bats | *optimize.bats | *uninstall_menu.bats | *cli.bats | *uninstall_review.bats | *history.bats) _sequential_files+=("$_f") ;;
                    *) _rest+=("$_f") ;;
                esac
            done
        fi
        if [[ ${#_rest[@]} -gt 0 ]]; then
            set -- "${_rest[@]}"
        else
            set --
        fi
        unset _all _rest _f
    fi

    # Accumulate pass/fail across all bats invocations.
    _unit_rc=0

    # Main run (parallel when bats_opts has --jobs, skipped if no files remain).
    if [[ $# -gt 0 ]]; then
        if [[ -n "${MOLE_TEST_REPORT_DIR:-}" ]] && $bats_has_formatter; then
            mole_run_reported_bats ${bats_opts[@]+"${bats_opts[@]}"} "$@" || _unit_rc=$?
        elif $bats_has_formatter; then
            formatter="${BATS_FORMATTER:-pretty}"
            if [[ "$formatter" == "tap" ]]; then
                if $use_color; then
                    esc=$'\033'
                    bats ${bats_opts[@]+"${bats_opts[@]}"} --formatter tap "$@" |
                        sed -e "s/^ok /${esc}[32mok ${esc}[0m /" \
                            -e "s/^not ok /${esc}[31mnot ok ${esc}[0m /" || _unit_rc=1
                else
                    bats ${bats_opts[@]+"${bats_opts[@]}"} --formatter tap "$@" || _unit_rc=1
                fi
            else
                # Pretty format for local development
                bats ${bats_opts[@]+"${bats_opts[@]}"} --formatter "$formatter" "$@" || _unit_rc=1
            fi
        else
            if $use_color; then
                esc=$'\033'
                bats ${bats_opts[@]+"${bats_opts[@]}"} --tap "$@" |
                    sed -e "s/^ok /${esc}[32mok ${esc}[0m /" \
                        -e "s/^not ok /${esc}[31mnot ok ${esc}[0m /" || _unit_rc=1
            else
                bats ${bats_opts[@]+"${bats_opts[@]}"} --tap "$@" || _unit_rc=1
            fi
        fi
    fi

    # Post-run: timing-sensitive tests run after parallel workers have finished
    # so CPU contention does not skew wall-clock assertions.
    for _pf in ${_sequential_files[@]+"${_sequential_files[@]}"}; do
        if mole_rc_timeout_or_signal "$_unit_rc"; then break; fi
        if [[ -n "${MOLE_TEST_REPORT_DIR:-}" ]] && $bats_has_formatter; then
            _sequential_rc=0
            mole_run_reported_bats "$_pf" || _sequential_rc=$?
            if [[ $_sequential_rc -ne 0 ]]; then _unit_rc=$_sequential_rc; fi
        elif [[ "${MOLE_TEST_TIMING:-0}" == "1" ]]; then
            bats --timing "$_pf" || _unit_rc=1
        else
            bats "$_pf" || _unit_rc=1
        fi
    done
    unset _sequential_files _pf

    if [[ -n "${MOLE_TEST_REPORT_DIR:-}" ]] && $bats_has_formatter; then
        _report_rc=0
        mole_finish_bats_report || _report_rc=$?
        if [[ $_unit_rc -eq 0 && $_report_rc -ne 0 ]]; then _unit_rc=$_report_rc; fi
    fi
    report_slowest_test_files
    report_unit_result "$_unit_rc"
    if mole_rc_timeout_or_signal "$_unit_rc"; then exit "$_unit_rc"; fi
else
    printf '%b' "${YELLOW}${ICON_WARNING} bats not installed or no tests found, skipping${NC}\n"
fi
echo ""

echo "3. Running Go tests..."
if command -v go > /dev/null 2>&1; then
    mkdir -p "$GO_TEST_CACHE"
    # Kept quiet on success; on failure the output names the failing test,
    # which CI otherwise never shows (a CI-only Go failure on #1839).
    go_test_log="$TEST_SYSTEM_STUB_DIR/go-test.log"
    if GOCACHE="$GO_TEST_CACHE" go build ./... > "$go_test_log" 2>&1 &&
        GOCACHE="$GO_TEST_CACHE" go vet ./... >> "$go_test_log" 2>&1 &&
        GOCACHE="$GO_TEST_CACHE" go test ./... >> "$go_test_log" 2>&1; then
        printf '%b' "${GREEN}${ICON_SUCCESS} Go tests passed${NC}\n"
    else
        cat "$go_test_log"
        printf '%b' "${RED}${ICON_ERROR} Go tests failed${NC}\n"
        FAILED=$((FAILED + 1))
    fi
else
    printf '%b' "${YELLOW}${ICON_WARNING} Go not installed, skipping Go tests${NC}\n"
fi
echo ""

echo "4. Testing module loading..."
if bash -c 'source lib/core/common.sh && echo "OK"' > /dev/null 2>&1; then
    printf '%b' "${GREEN}${ICON_SUCCESS} Module loading passed${NC}\n"
else
    printf '%b' "${RED}${ICON_ERROR} Module loading failed${NC}\n"
    FAILED=$((FAILED + 1))
fi
echo ""

echo "5. Running integration tests..."
# Quick syntax check for main scripts
if bash -n mole && bash -n bin/clean.sh && bash -n bin/optimize.sh; then
    printf '%b' "${GREEN}${ICON_SUCCESS} Integration tests passed${NC}\n"
else
    printf '%b' "${RED}${ICON_ERROR} Integration tests failed${NC}\n"
    FAILED=$((FAILED + 1))
fi
echo ""

echo "6. Checking installation entry syntax (read-only)..."
# Installation behavior is exercised by the private mocked Bats regressions.
# This final stage never dispatches a real installer or downloads a release.
if bash -n install.sh && bash -n lib/manage/update.sh; then
    printf '%b' "${GREEN}${ICON_SUCCESS} Installation entry syntax passed (no installation performed)${NC}\n"
else
    printf '%b' "${RED}${ICON_ERROR} Installation entry syntax failed${NC}\n"
    FAILED=$((FAILED + 1))
fi
echo ""

echo "==============================="
if [[ $FAILED -eq 0 ]]; then
    printf '%b' "${GREEN}${ICON_SUCCESS} All tests passed!${NC}\n"
    exit 0
fi
printf '%b' "${RED}${ICON_ERROR} $FAILED tests failed!${NC}\n"
exit 1
