#!/bin/bash
# Test-only entrypoint: run a command from a private source snapshot, with
# kernel-enforced writes confined to that run. Never sweep another run's files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

refuse() {
    printf 'Mole test sandbox refused (%s): %s\n' "$1" "$2" >&2
    exit 16
}

[[ $# -gt 0 ]] || refuse missing-command 'run scripts/test_sandbox.sh bats <test files>'
[[ "$(uname -s)" == Darwin && -x /usr/bin/sandbox-exec ]] ||
    refuse sandbox-unavailable 'run on macOS with sandbox-exec; no unsandboxed fallback is supported'

run_root=$(mktemp -d "${TMPDIR:-/tmp}/mole-test-run.XXXXXX") ||
    refuse fixture-create-failed 'could not create a private test directory'
run_root=$(cd "$run_root" && pwd -P)
# Failed runs retain their private snapshot and evidence. Successful runs only
# remove this exact directory, created by this invocation, never old fixtures.
# shellcheck disable=SC2329  # Invoked by trap.
cleanup_run() {
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        /bin/rm -rf -- "$run_root" # SAFE: exact mktemp-created root owned by this test invocation
    else
        printf 'Mole test artifacts retained: %s\n' "$run_root" >&2
    fi
}
trap cleanup_run EXIT

mkdir -p "$run_root/repo" "$run_root/home" "$run_root/tmp" "$run_root/go-cache" "$run_root/go-work" "$run_root/stubs"
token="$$.$RANDOM.$RANDOM"
printf '%s\n' "$token" > "$run_root/.test-boundary"

# A source snapshot keeps existing BATS_TEST_DIRNAME/tmp-* fixtures inside the
# kernel boundary without granting write access to the user's checkout.
git -C "$PROJECT_ROOT" ls-files -z --cached --others --exclude-standard > "$run_root/source-files"
while IFS= read -r -d '' relative; do
    case "$relative" in
        tests/tmp-* | .git/*) continue ;;
    esac
    [[ -e "$PROJECT_ROOT/$relative" || -L "$PROJECT_ROOT/$relative" ]] || continue
    # A dirty index may still list children of a directory upstream converted
    # to a symlink. Copy the lexical link once; never descend through it.
    snapshot_parent="$relative"
    snapshot_skip=false
    while [[ "$snapshot_parent" == */* ]]; do
        snapshot_parent="${snapshot_parent%/*}"
        if [[ -L "$PROJECT_ROOT/$snapshot_parent" ]]; then
            snapshot_skip=true
            break
        fi
    done
    [[ "$snapshot_skip" == false ]] || continue
    mkdir -p "$run_root/repo/$(dirname "$relative")"
    /bin/cp -P "$PROJECT_ROOT/$relative" "$run_root/repo/$relative"
done < "$run_root/source-files"
# Bind each receipt to the bytes copied before the command starts. Retained
# failure roots keep this manifest beside their source snapshot and reports.
(
    cd "$run_root/repo"
    find . -type f -exec /usr/bin/shasum -a 256 {} +
) | LC_ALL=C sort > "$run_root/source-sha256"
source_digest=$(/usr/bin/shasum -a 256 "$run_root/source-sha256")
printf 'Mole test source snapshot sha256: %s\n' "${source_digest%% *}" >&2

# SBPL strings must not be assembled from unescaped path contents.
write_policy() {
    local escaped_root="${1//\\/\\\\}"
    escaped_root="${escaped_root//\"/\\\"}"
    cat << EOF
(version 1)
(allow default)
(deny file-write*)
(allow file-write* (subpath "$escaped_root"))
(deny file-write* (subpath "$escaped_root/kernel-denied"))
(allow file-write* (literal "/dev/null"))
(deny network*)
(deny mach-lookup)
(deny signal)
(allow signal (target same-sandbox))
(deny process-exec
    (literal "/usr/bin/sudo")
    (literal "/usr/bin/osascript")
    (literal "/bin/launchctl")
    (literal "/usr/bin/defaults")
    (literal "/usr/bin/killall")
    (literal "/usr/bin/pkill")
    (literal "/usr/bin/open")
    (literal "/usr/bin/security")
    (literal "/usr/bin/tmutil")
    (literal "/usr/bin/hdiutil")
    (literal "/usr/bin/xcrun")
    (literal "/usr/sbin/diskutil")
    (literal "/usr/sbin/systemsetup")
    (literal "/usr/bin/pmset")
    (literal "/usr/sbin/softwareupdate"))
EOF
}
write_policy "$run_root" > "$run_root/policy.sb"
kernel_sentinel="$run_root/kernel-denied/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/old/sentinel"
mkdir -p "$(dirname "$kernel_sentinel")"
printf 'private kernel-denial sentinel\n' > "$kernel_sentinel"

# Verify that kernel enforcement actually rejects a write outside its allowed
# subtree, using only a sentinel owned by this run. PATH shims are not involved.
mkdir -p "$run_root/probe/allowed" "$run_root/probe/denied"
write_policy "$run_root/probe/allowed" > "$run_root/probe/policy.sb"
probe_rc=0
# shellcheck disable=SC2016 # Child shell expands its positional arguments.
/usr/bin/sandbox-exec -f "$run_root/probe/policy.sb" /bin/bash -c '
    printf allowed > "$1/allowed/sentinel" || exit 1
    if /bin/bash -c '\''printf denied > "$1/denied/sentinel"'\'' _ "$1" 2>/dev/null; then
        exit 1
    fi
    [[ ! -e "$1/denied/sentinel" ]]
' _ "$run_root/probe" || probe_rc=$?
[[ $probe_rc -eq 0 ]] || refuse sandbox-probe-failed "inspect $run_root/probe"

# PATH mocks remain useful for readable test failures and for shell scripts
# such as brew whose interpreter alone is insufficient to identify the owner.
# Kernel denial still applies to absolute system executables and raw syscalls.
for blocked_command in sudo osascript launchctl defaults killall pkill open security \
    tmutil hdiutil xcrun diskutil systemsetup pmset softwareupdate brew; do
    cat > "$run_root/stubs/$blocked_command" << 'EOF'
#!/bin/bash
printf 'mole test sandbox blocked system command: %s %s\n' "${0##*/}" "$*" >&2
exit 16
EOF
    chmod +x "$run_root/stubs/$blocked_command"
done

# External report/cache destinations are not extra sandbox grants.
if [[ -n "${MOLE_TEST_REPORT_DIR:-}" && "$MOLE_TEST_REPORT_DIR" != "$run_root/"* ]]; then
    refuse report-outside-fixture 'omit MOLE_TEST_REPORT_DIR; reports are written inside the private run'
fi
export GOPROXY=off GOTOOLCHAIN=local
# Read already-installed modules, but never let tests download dependencies or
# acquire a toolchain. The kernel refuses writes to that existing module cache.
if command -v go > /dev/null 2>&1; then
    # Go may open telemetry counters even for `go env`. Resolve the original
    # user's existing module cache under the same kernel boundary as tests;
    # keep that HOME readable, but direct scratch/cache writes into this run.
    original_module_cache=$(/usr/bin/sandbox-exec -f "$run_root/policy.sb" \
        /usr/bin/env GOTELEMETRY=off GOPROXY=off GOTOOLCHAIN=local \
        TMPDIR="$run_root/tmp/" GOCACHE="$run_root/go-cache" \
        go env GOMODCACHE) ||
        refuse go-cache-unavailable 'could not locate the existing Go module cache'
    export GOMODCACHE="$original_module_cache"
fi
export MOLE_TEST_RUN_ROOT="$run_root" MOLE_TEST_BOUNDARY_TOKEN="$token"
export MOLE_TEST_SANDBOX_ACTIVE="$token"
export MOLE_TEST_KERNEL_SENTINEL="$kernel_sentinel"
export PATH="$run_root/stubs:$PATH"
export HOME="$run_root/home" TMPDIR="$run_root/tmp/"
export MOLE_TEST_NO_AUTH=1
# Keep build state private even when the denied account lookup returns only a
# numeric uid. GOMODCACHE still reads the pre-provisioned modules above.
export GOPATH="$run_root/go-work" MOLE_GO_TEST_CACHE="$run_root/go-cache" GOCACHE="$run_root/go-cache"
export MOLE_TEST_REPORT_DIR="$run_root/report"
unset XDG_CACHE_HOME XDG_CONFIG_HOME MO_NO_OPLOG
unset MOLE_RESOLVED_TMPDIR MOLE_TEMP_REGISTRY_FILE MOLE_TEST_TRASH_DIR MOLE_DELETE_LOG

# Translate only explicit checkout-contained paths. Relative paths remain
# relative to the snapshot; arbitrary command arguments are left untouched.
command_args=()
for argument in "$@"; do
    case "$argument" in
        "$PROJECT_ROOT"/*) argument="$run_root/repo/${argument#"$PROJECT_ROOT"/}" ;;
    esac
    command_args+=("$argument")
done
cd "$run_root/repo"
python3 -B "$run_root/repo/tests/support/owned_pty.py" launch \
    "$run_root" "$run_root/policy.sb" "${command_args[@]}" &
launcher_pid=$!
# shellcheck disable=SC2329  # Invoked by trap.
stop_launcher() {
    local signal_name="$1" signal_status="$2"
    trap '' HUP INT TERM
    # This PID is the still-owned direct child from this invocation. Wait for
    # its PTY/child cleanup before EXIT may inspect or remove the fixture root.
    kill -"$signal_name" "$launcher_pid" 2> /dev/null || true
    wait "$launcher_pid" || true
    exit "$signal_status"
}
trap 'stop_launcher HUP 129' HUP
trap 'stop_launcher INT 130' INT
trap 'stop_launcher TERM 143' TERM
if wait "$launcher_pid"; then
    exit 0
else
    exit "$?"
fi
