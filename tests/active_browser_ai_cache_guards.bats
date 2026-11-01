#!/usr/bin/env bats

setup() {
    export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export CASE_ROOT="$BATS_TEST_TMPDIR/owner-cache-guards"
    mkdir -p "$CASE_ROOT"
    cat > "$CASE_ROOT/fixture.sh" <<'EOF'
set -euo pipefail
mkdir -p "$HOME/Library/Caches/Google/Chrome/Default" \
    "$HOME/Library/Application Support/Claude" "$HOME/.claude/projects" "$HOME/.config/mole"
# Saved custom whitelist files replace defaults, as on the observed Mac.
: > "$HOME/.config/mole/whitelist"
printf 'session\n' > "$HOME/.claude/projects/session.json"
printf 'auth\n' > "$HOME/Library/Application Support/Claude/auth.json"
printf 'http cache\n' > "$HOME/Library/Caches/Google/Chrome/Default/cache-entry"
for leaf in Cache 'Code Cache' GPUCache DawnGraphiteCache DawnWebGPUCache sentry; do
    mkdir -p "$HOME/Library/Application Support/Claude/$leaf"
    printf 'cache\n' > "$HOME/Library/Application Support/Claude/$leaf/cache-entry"
done
source "$PROJECT_ROOT/bin/clean.sh"
_fixture_owner_state() {
    printf 'probe\n' >> "$HOME/probes"
    [[ -e "$HOME/owner-started" ]] && return 0
    return "$INITIAL_OWNER_STATE"
}
is_google_chrome_running() { _fixture_owner_state; }
claude_desktop_running() { _fixture_owner_state; }
clean_chrome_old_versions() { :; }
clean_edge_old_versions() { :; }
clean_edge_updater_old_versions() { :; }
clean_brave_old_versions() { :; }
clean_service_worker_cache() { :; }
get_cleanup_path_size_kb() {
    printf '%s\n' "$1" >> "$HOME/sized"
    if [[ "${OWNER_RACE:-}" == size ]]; then
        : > "$HOME/owner-started"
    fi
    echo 1
}
record_dry_run_cleanup_target() {
    printf '%s\n' "$1" >> "$HOME/previewed"
    return 0
}
if [[ "${OWNER_RACE:-}" == final ]]; then
    # safe_remove performs this metadata/policy work after safe_clean's guard.
    # Keep the actual safe_remove and its last-hop guard in the test.
    validate_path_for_deletion() {
        printf 'metadata\n' >> "$HOME/final-metadata"
        : > "$HOME/owner-started"
        return 0
    }
fi
if [[ "$FAMILY" == Chrome ]]; then
    family_root="$HOME/Library/Caches/Google/Chrome"
    family_target="$family_root/Default"
else
    family_root="$HOME/Library/Application Support/Claude"
    family_target="$family_root/GPUCache/cache-entry"
fi
dispatch_family() {
    if [[ "$FAMILY" == Chrome ]]; then clean_browsers; else clean_dev_misc; fi
}
if [[ "$MODE" == preview ]]; then DRY_RUN=true; export MOLE_DRY_RUN=1;
else DRY_RUN=false; export MOLE_DRY_RUN=0 MOLE_DELETE_MODE=permanent; fi
EOF
}

run_family_case() {
    local family="$1" mode="$2" state="$3" race="${4:-}"
    local fixture_home="$CASE_ROOT/$family-$mode-$state-${race:-stable}"
    mkdir -p "$fixture_home"
    # shellcheck disable=SC2016 # The child shell expands fixture variables and calls production helpers.
    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" FIXTURE="$CASE_ROOT/fixture.sh" \
        FAMILY="$family" MODE="$mode" INITIAL_OWNER_STATE="$state" OWNER_RACE="$race" \
        MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc -c '
source "$FIXTURE"
dispatch_family
printf "EXISTS:%s\n" "$([[ -e "$family_target" ]] && echo yes || echo no)"
printf "PREVIEW:%s\n" "$([[ -f "$HOME/previewed" ]] && echo yes || echo no)"
printf "SIZED:%s\n" "$([[ -f "$HOME/sized" ]] && echo yes || echo no)"
printf "FINAL_METADATA:%s\n" "$([[ -f "$HOME/final-metadata" ]] && echo yes || echo no)"
[[ -f "$HOME/.claude/projects/session.json" ]] || exit 1
[[ -f "$HOME/Library/Application Support/Claude/auth.json" ]] || exit 1
'
}

@test "generic user caches leave every dedicated browser root to its specialist" {
    run env HOME="$CASE_ROOT/generic" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
mkdir -p "$HOME/Library/Caches/Google/Chrome/Default" "$HOME/Library/Caches/Firefox/profile/cache2" "$HOME/Library/Caches/OrdinaryCache"
mkdir -p "$HOME/.config/mole"
: > "$HOME/.config/mole/whitelist"
for root in Google Chromium com.apple.Safari com.microsoft.edgemac company.thebrowser.Browser company.thebrowser.dia Dia BraveSoftware net.imput.helium Yandex Firefox com.operasoftware.Opera com.vivaldi.Vivaldi Comet com.kagi.kagimacOS zen com.tencent.QQBrowser3; do
    mkdir -p "$HOME/Library/Caches/$root"
    touch "$HOME/Library/Caches/$root/cache"
done
touch "$HOME/Library/Caches/Google/Chrome/Default/cache" "$HOME/Library/Caches/Firefox/profile/cache2/cache" "$HOME/Library/Caches/OrdinaryCache/cache"
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=true
export MOLE_DRY_RUN=1
safe_clean_guarded() {
    shift
    local last="${!#}" path
    for path in "$@"; do [[ "$path" == "$last" ]] || printf 'PREVIEW:%s\n' "$path"; done
}
clean_user_essentials
EOF
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"PREVIEW:$CASE_ROOT/generic/Library/Caches/OrdinaryCache"* ]] || return 1
    [[ "$output" != *"PREVIEW:$CASE_ROOT/generic/Library/Caches/Google"* ]] || return 1
    [[ "$output" != *"PREVIEW:$CASE_ROOT/generic/Library/Caches/Firefox"* ]] || return 1
    for root in Chromium com.apple.Safari com.microsoft.edgemac company.thebrowser.Browser company.thebrowser.dia Dia BraveSoftware net.imput.helium Yandex com.operasoftware.Opera com.vivaldi.Vivaldi Comet com.kagi.kagimacOS zen com.tencent.QQBrowser3; do
        [[ "$output" != *"PREVIEW:$CASE_ROOT/generic/Library/Caches/$root"* ]] || return 1
    done
}

@test "Chrome running and unknown states block both preview and deletion" {
    for state in 0 2; do
        for mode in preview real; do
            run_family_case Chrome "$mode" "$state"
            [ "$status" -eq 0 ] || return 1
            [[ "$output" == *"EXISTS:yes"* ]] || return 1
            [[ "$output" == *"PREVIEW:no"* ]] || return 1
            [[ "$output" == *"SIZED:no"* ]] || return 1
        done
    done
}

@test "Claude Desktop running and unknown states block both preview and deletion" {
    for state in 0 2; do
        for mode in preview real; do
            run_family_case Claude "$mode" "$state"
            [ "$status" -eq 0 ] || return 1
            [[ "$output" == *"EXISTS:yes"* ]] || return 1
            [[ "$output" == *"PREVIEW:no"* ]] || return 1
            [[ "$output" == *"SIZED:no"* ]] || return 1
        done
    done
}

@test "stopped Chrome and Claude caches retain preview and deletion behavior" {
    for family in Chrome Claude; do
        run_family_case "$family" preview 1
        [ "$status" -eq 0 ] || return 1
        [[ "$output" == *"EXISTS:yes"* ]] || return 1
        [[ "$output" == *"PREVIEW:yes"* ]] || return 1
        run_family_case "$family" real 1
        [ "$status" -eq 0 ] || return 1
        [[ "$output" == *"EXISTS:no"* ]] || return 1
        [[ "$output" == *"SIZED:yes"* ]] || return 1
    done
}

@test "Chrome and Claude caches recheck owners after sizing before preview or deletion" {
    for family in Chrome Claude; do
        for mode in preview real; do
            run_family_case "$family" "$mode" 1 size
            [ "$status" -eq 0 ] || return 1
            [[ "$output" == *"EXISTS:yes"* ]] || return 1
            [[ "$output" == *"SIZED:yes"* ]] || return 1
            [[ "$output" == *"PREVIEW:no"* ]] || return 1
        done
    done
}

@test "Chrome and Claude owner guards survive metadata work at the final safe_remove sink" {
    for family in Chrome Claude; do
        run_family_case "$family" real 1 final
        [ "$status" -eq 0 ] || return 1
        [[ "$output" == *"FINAL_METADATA:yes"* ]] || return 1
        [[ "$output" == *"EXISTS:yes"* ]] || return 1
        [[ "$output" == *"PREVIEW:no"* ]] || return 1
    done
}

@test "whitelisted Chrome and Claude cache targets remain filtered before owner cleanup" {
    for family in Chrome Claude; do
        local fixture_home="$CASE_ROOT/whitelisted-$family"
        mkdir -p "$fixture_home"
        # shellcheck disable=SC2016 # The child shell expands fixture variables and calls production helpers.
        run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" FIXTURE="$CASE_ROOT/fixture.sh" \
            FAMILY="$family" MODE=preview INITIAL_OWNER_STATE=1 MOLE_TEST_NO_AUTH=1 \
            /bin/bash --noprofile --norc -c '
source "$FIXTURE"
printf "%s\n" "$family_root" > "$HOME/.config/mole/whitelist"
load_mole_whitelist "$HOME"
dispatch_family
[[ -e "$family_target" ]] || exit 1
[[ ! -f "$HOME/previewed" ]] || exit 1
[[ ! -f "$HOME/sized" ]] || exit 1
printf "WHITELIST_FILTERED:%s\n" "$FAMILY"
'
        [ "$status" -eq 0 ] || return 1
        [[ "$output" == *"WHITELIST_FILTERED:$family"* ]] || return 1
    done
}
