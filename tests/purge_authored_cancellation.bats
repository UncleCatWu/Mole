#!/usr/bin/env bats

setup() {
    export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "authored find and git inspection preserve signal cancellation and timeout unknown" {
    for kind in find git; do
        for expected in 129 130 143 2; do
            local status_code="$expected"
            [[ "$expected" != 2 ]] || status_code=124
            run env HOME="$BATS_TEST_TMPDIR/$kind-$status_code" PROJECT_ROOT="$PROJECT_ROOT" \
                KIND="$kind" STATUS_CODE="$status_code" EXPECTED="$expected" /bin/bash <<'EOF'
set -euo pipefail
mkdir -p "$HOME/artifact"
source "$PROJECT_ROOT/lib/clean/project.sh"
# This fixture isolates authored evidence; the independent Node-owner gate is eligible.
purge_node_modules_is_protected() { return 1; }
[[ "$KIND" != git ]] || mkdir "$HOME/.git"
run_with_timeout() {
    shift
    printf 'PROBE:%s\n' "$1" >> "$HOME/probes"
    if [[ "$KIND" == git && "$1" == /usr/bin/find ]]; then return 0; fi
    return "$STATUS_CODE"
}
rc=0
purge_artifact_has_authored_content "$HOME/artifact" || rc=$?
[[ "$rc" -eq "$EXPECTED" ]] || { echo "HELPER_RC=$rc EXPECTED=$EXPECTED"; exit 1; }
[[ -s "$HOME/probes" ]] || exit 1
rc=0
is_protected_purge_artifact "$HOME/artifact" || rc=$?
if [[ "$EXPECTED" -ge 128 ]]; then
    [[ "$rc" -eq "$EXPECTED" && "$PURGE_PROTECTION_UNVERIFIED" == false ]] || { echo "CLASSIFIER_RC=$rc"; exit 1; }
else
    [[ "$rc" -eq 0 && "$PURGE_PROTECTION_UNVERIFIED" == true ]] || exit 1
fi
EOF
            [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
        done
    done
}

@test "authored discovery interruption stops before probing a later eligible artifact" {
    for code in 0 129 130 143; do
        run env HOME="$BATS_TEST_TMPDIR/discovery-$code" PROJECT_ROOT="$PROJECT_ROOT" CODE="$code" /bin/bash <<'EOF'
set -euo pipefail
mkdir -p "$HOME/first/node_modules" "$HOME/second/node_modules"
source "$PROJECT_ROOT/lib/clean/project.sh"
# This fixture isolates authored evidence; the independent Node-owner gate is eligible.
purge_node_modules_is_protected() { return 1; }
run_with_timeout() {
    shift
    printf 'PROBE:%s\n' "$2" >> "$HOME/probes"
    [[ "$2" != "$HOME/first/node_modules" || "$CODE" == 0 ]] || return "$CODE"
    return 0
}
get_optimal_parallel_jobs() { echo 1; } # Weigh the stop after the first completed probe.
rc=0
printf '%s\n' "$HOME/first/node_modules" "$HOME/second/node_modules" | filter_protected_artifacts > "$HOME/output" || rc=$?
if [[ "$CODE" == 0 ]]; then
    [[ "$rc" == 0 ]] || exit 1
    grep -qF "$HOME/second/node_modules" "$HOME/output" || exit 1
    grep -qF "$HOME/second/node_modules" "$HOME/probes" || exit 1
    echo SECOND_ELIGIBLE_CONTROL
else
    [[ "$rc" == "$CODE" ]] || { echo "DISCOVERY_RC=$rc"; exit 1; }
    ! grep -qF "$HOME/second/node_modules" "$HOME/probes" || exit 1
fi
EOF
        [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
        if [[ "$code" == 0 ]]; then [[ "$output" == *SECOND_ELIGIBLE_CONTROL* ]] || return 1; fi
    done
}

@test "authored review preaction and final-hook interruption stops the next eligible sink" {
    for phase in 1 2 3; do
        for code in 0 129 130 143; do
            run env HOME="$BATS_TEST_TMPDIR/phase-$phase-$code" PROJECT_ROOT="$PROJECT_ROOT" \
                PHASE="$phase" CODE="$code" /bin/bash <<'EOF'
set -euo pipefail
mkdir -p "$HOME/www"
source "$PROJECT_ROOT/lib/clean/project.sh"
# This fixture isolates authored evidence; the independent Node-owner gate is eligible.
purge_node_modules_is_protected() { return 1; }
for project in first second; do
    mkdir -p "$HOME/www/$project/node_modules"
    printf payload > "$HOME/www/$project/node_modules/file"
    printf '{}' > "$HOME/www/$project/package.json"
    touch -t 202001010101 "$HOME/www/$project/node_modules" "$HOME/www/$project/node_modules/file"
done
PURGE_SEARCH_PATHS=("$HOME/www")
export MOLE_DRY_RUN=1
scan_purge_targets() { printf '%s\n' "$HOME/www/first/node_modules" "$HOME/www/second/node_modules" > "$2"; }
get_dir_size_kb() { echo 1; }
is_recently_modified() { _PURGE_ACTIVITY_STATE=old; return 1; }
eval "$(declare -f run_with_timeout | sed '1s/run_with_timeout/original_run_with_timeout/')"
run_with_timeout() {
    local probe="${3:-}"
    if [[ "${2:-}" == /usr/bin/find && "$probe" == "$HOME/www/"*/node_modules ]]; then
        local label="${probe%/node_modules}"; label="${label##*/}"
        local count=0
        [[ ! -f "$HOME/$label.count" ]] || count=$(cat "$HOME/$label.count")
        count=$((count + 1)); printf '%s\n' "$count" > "$HOME/$label.count"
        printf 'PROBE:%s:%s\n' "$label" "$count" >> "$HOME/trace"
        if [[ "$label" == first && "$count" == "$PHASE" && "$CODE" != 0 ]]; then
            printf 'INTERRUPT\n' >> "$HOME/trace"
            return "$CODE"
        fi
        return 0
    fi
    original_run_with_timeout "$@"
}
safe_remove() {
    local rc=0
    "${_MOLE_SAFE_REMOVE_FINAL_GUARD}" "$1" || rc=$?
    [[ "$rc" == 0 ]] || return "$rc"
    printf 'SINK:%s\n' "$1" >> "$HOME/trace"
}
rc=0
clean_project_artifacts </dev/null || rc=$?
if [[ "$CODE" == 0 ]]; then
    [[ "$rc" == 0 ]] || exit 1
    grep -qF "SINK:$HOME/www/second/node_modules" "$HOME/trace" || exit 1
    echo SECOND_SINK_ELIGIBLE_CONTROL
else
    [[ "$rc" == "$CODE" && "$PURGE_RUN_OUTCOME" == cancelled ]] || { echo "RUN_RC=$rc OUTCOME=$PURGE_RUN_OUTCOME"; cat "$HOME/trace"; exit 1; }
    [[ -f "$HOME/www/second/node_modules/file" ]] || exit 1
    after=$(sed -n '/^INTERRUPT$/,$p' "$HOME/trace")
    [[ "$after" != *PROBE:second* && "$after" != *SINK:* ]] || { echo "$after"; exit 1; }
fi
EOF
            [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
            if [[ "$code" == 0 ]]; then [[ "$output" == *SECOND_SINK_ELIGIBLE_CONTROL* ]] || return 1; fi
        done
    done
}

@test "Git fatal 128 keeps the invalid repository artifact out of purge sinks" {
    run env HOME="$BATS_TEST_TMPDIR/git-fatal-home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash <<'EOF'
set -euo pipefail
mkdir -p "$HOME/www/first/.git" "$HOME/www/first/node_modules" "$HOME/www/second/node_modules"
printf authored > "$HOME/www/first/node_modules/file"
printf payload > "$HOME/www/second/node_modules/file"
source "$PROJECT_ROOT/lib/clean/project.sh"
# This fixture isolates authored evidence; the independent Node-owner gate is eligible.
purge_node_modules_is_protected() { return 1; }
PURGE_SEARCH_PATHS=("$HOME/www")
export MOLE_DRY_RUN=1
scan_purge_targets() { printf '%s\n' "$HOME/www/first/node_modules" "$HOME/www/second/node_modules" > "$2"; }
get_dir_size_kb() { echo 1; }
is_recently_modified() { _PURGE_ACTIVITY_STATE=old; return 1; }
safe_remove() { printf 'SINK:%s\n' "$1" >> "$HOME/sinks"; }
clean_project_artifacts </dev/null
[[ "$PURGE_RUN_OUTCOME" == incomplete ]] || exit 1
[[ -f "$HOME/www/first/node_modules/file" ]] || exit 1
[[ -f "$HOME/sinks" ]] || exit 1
grep -qF "$HOME/www/second/node_modules" "$HOME/sinks" || exit 1
! grep -qF "$HOME/www/first/node_modules" "$HOME/sinks" || exit 1
printf 'INVALID_GIT_KEPT_SECOND_ELIGIBLE\n'
EOF
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$output" == *"Could not inspect ~/www/first/node_modules; kept"* ]] || return 1
    [[ "$output" == *INVALID_GIT_KEPT_SECOND_ELIGIBLE* ]] || return 1
}
