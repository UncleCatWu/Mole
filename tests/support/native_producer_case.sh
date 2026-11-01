#!/bin/bash
# shellcheck disable=SC2154 # Counters are initialized by the sourced bin/clean.sh.
set -euo pipefail
[[ "$HOME" == "$MOLE_TEST_RUN_ROOT/"* && "$MOLE_TEST_SANDBOX_ACTIVE" == "$MOLE_TEST_BOUNDARY_TOKEN" ]] || exit 16
export NATIVE_CASE="$1"
export NATIVE_EVENTS="$HOME/events.jsonl"
mkdir -p "$HOME/.config/mole" "$HOME/observer-bin"
for kind in find du; do
    printf '#!/bin/bash\nexec python3 -I -B "%s" "%s" "$@"\n' "$PWD/tests/support/native_stall_observer.py" "$kind" > "$HOME/observer-bin/$kind"
    chmod +x "$HOME/observer-bin/$kind"
done
export PATH="$HOME/observer-bin:$PATH"
# Existing production timeout bounds are shortened only in this test shell.
export MOLE_TIMEOUT_HINT_SCAN_SEC=15 MOLE_PROJECT_CACHE_SCAN_TIMEOUT=2
[[ "$NATIVE_CASE" != app_scan ]] || export MOLE_TIMEOUT_HINT_SCAN_SEC=2
export MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=1
source "$PWD/bin/clean.sh"
# Pin the backend actually used on this Mac. No replacement of run_with_timeout.
MO_TIMEOUT_BIN=""
MO_TIMEOUT_PERL_BIN=/usr/bin/perl
printf 'BACKEND=%s SOURCE=%s\n' "$MO_TIMEOUT_PERL_BIN" "$PWD/lib/core/timeout.sh"
DRY_RUN=true
SYSTEM_CLEAN=false
EXTERNAL_VOLUME_TARGET=""
WHITELIST_PATTERNS=()
WHITELIST_WARNINGS=()
MOLE_CURRENT_COMMAND=clean
MOLE_CLEAN_CANCEL_STATUS=0
_MOLE_CLEAN_INVENTORY_PARTIAL=false
MO_DEBUG=1
check_tcc_permissions() { :; }
start_section() { :; }
end_section() { :; }
log_operation_session_end() { :; }
log_operation_session_start() { :; }
adopt_sudo_session() { return 1; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
update_progress_if_needed() { :; }
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
# Trace the genuine size helper; only wrappers add evidence.
eval "$(declare -f app_support_item_size_bytes | sed '1s/app_support_item_size_bytes/native_size_helper/')"
app_support_item_size_bytes() {
    printf 'SIZE:%s\n' "${1##*/}" >> "$HOME/action-trace"
    # Observer startup is part of the native command. Give healthy controls
    # their fixture budget through the existing size-helper argument, without
    # restoring an undocumented production setting. The cumulative deadline
    # and the real recursive producer remain unchanged.
    case "$NATIVE_CASE" in
        app_complete | app_du) native_size_helper "$1" 2 ;;
        *) native_size_helper "$@" ;;
    esac
}
eval "$(declare -f record_dry_run_cleanup_target | sed '1s/record_dry_run_cleanup_target/native_preview_helper/')"
record_dry_run_cleanup_target() {
    printf 'PREVIEW:%s\n' "${1##*/}" >> "$HOME/action-trace"
    native_preview_helper "$@"
}
# This test authorizes preview only, and asserts no real sink was reached.
safe_remove() {
    printf 'SINK:%s\n' "$1" >> "$HOME/action-trace"
    return 16
}
root="$HOME/Library/Application Support/TestApp/Code Cache"
export NATIVE_STALL_TARGET=""
case "$NATIVE_CASE" in
    app_scan | app_signal) export NATIVE_STALL_TARGET="$root" ;;
    app_du) export NATIVE_STALL_TARGET="$root/a" ;;
esac
python3 -I -B - "$root" "$NATIVE_CASE" << 'PY'
import sys
from pathlib import Path
r=Path(sys.argv[1]);r.mkdir(parents=True)
if sys.argv[2] in ('app_scan','app_signal'):
    # >10000 actual entries and output >native pipe capacity; no fabricated prefix.
    for i in range(12000): (r/f'entry-{i:05d}').touch()
else:
    a=r/'a';(a/'level1'/'level2'/'level3').mkdir(parents=True)
    for i in range(1500): (a/'level1'/'level2'/'level3'/f'file-{i:05d}').touch()
    (a/'level1'/'payload').write_bytes(b'x'*4096)
    (r/'b').write_bytes(b'x'*2048)
PY
if [[ "$NATIVE_CASE" == project_* ]]; then
    FIND_BSD="find" # Route the native BSD producer through the audited observer.
    project="$HOME/Documents/fixture"
    python3 -I -B - "$project" << 'PY'
from pathlib import Path
import sys,os
r=Path(sys.argv[1]);r.mkdir(parents=True)
for i in range(1800 if os.environ['NATIVE_CASE']=='project_scan' else 20):
 c=r/f'project-{i:04d}'/'.next'/'cache';c.mkdir(parents=True);(c/'payload').write_bytes(b'x')
# Producer depth9, source prune, no-follow, newline/tab format, LC_ALL=C sort.
(r/'node_modules'/'hidden'/'.next'/'cache').mkdir(parents=True)
p=r
for i in range(8): p=p/f'depth-{i}';p.mkdir()
(p/'.next'/'cache').mkdir(parents=True);(p/'.next'/'cache'/'payload').write_bytes(b'x')
p=p/'beyond';p.mkdir();(p/'.next'/'cache').mkdir(parents=True)
(r/'link').symlink_to(r/'node_modules',target_is_directory=True)
PY
    [[ "$NATIVE_CASE" != project_scan ]] || export NATIVE_STALL_TARGET="$project"
    out="$HOME/project-output"
    project_rc=0
    scan_project_cache_root "$project" "$out" < /dev/null || project_rc=$?
    clean_project_cache_target() {
        [[ -f "$1" ]] || return 1
        printf 'PROJECT_SINK:%s\n' "$*" >> "$HOME/action-trace"
    }
    process_project_cache_matches "$out"
    printf 'PROJECT_RC=%s OUTPUT_BYTES=%s\n' "$project_rc" "$(stat -f%z "$out")"
    if [[ "$NATIVE_CASE" == project_scan ]]; then
        [[ $project_rc -eq 124 && ! -s "$out" && ! -e "$HOME/action-trace" ]]
    else
        [[ $project_rc -eq 0 && -s "$out" && -s "$HOME/action-trace" ]]
        if grep -q 'node_modules\|beyond\|/link/' "$out"; then exit 1; fi
        grep -q '/depth-7/.next' "$out"
        LC_ALL=C sort -c "$HOME/action-trace"
        printf 'PROJECT_CONSUMED=%s\n' "$(wc -l < "$HOME/action-trace")"
    fi
else
    start_cleanup > /dev/null
    rc=0
    perform_cleanup || rc=$?
    printf 'RESULT RC=%s CANCEL=%s PARTIAL=%s KB=%s ITEMS=%s\n' "$rc" "$MOLE_CLEAN_CANCEL_STATUS" "$DRY_RUN_TOTAL_PARTIAL" "$total_size_cleaned" "$files_cleaned"
    if [[ "$NATIVE_CASE" == app_signal ]]; then
        [[ $rc -eq 130 && $MOLE_CLEAN_CANCEL_STATUS -eq 130 && "$files_cleaned" -eq 0 && "$total_size_cleaned" -eq 0 ]]
        [[ ! -e "$HOME/action-trace" ]]
    elif [[ "$NATIVE_CASE" == app_scan ]]; then
        [[ $rc -eq 0 && $MOLE_CLEAN_CANCEL_STATUS -eq 0 ]]
        [[ "$DRY_RUN_TOTAL_PARTIAL" == true && "$total_size_cleaned" -eq 0 && "$files_cleaned" -eq 0 ]]
        [[ ! -e "$HOME/action-trace" ]]
        [[ -z "$(/usr/bin/find "$TMPDIR" -name '*app-support-scan*' -print)" ]]
    elif [[ "$NATIVE_CASE" == app_du ]]; then
        [[ $rc -eq 0 && $MOLE_CLEAN_CANCEL_STATUS -eq 0 ]]
        [[ "$DRY_RUN_TOTAL_PARTIAL" == true && "$total_size_cleaned" -eq 2 && "$files_cleaned" -eq 1 ]]
        if grep -q 'PREVIEW:a\|SINK:' "$HOME/action-trace"; then exit 1; fi
        grep -q 'PREVIEW:b' "$HOME/action-trace"
    else
        [[ $rc -eq 0 && $MOLE_CLEAN_CANCEL_STATUS -eq 0 ]]
        [[ "$DRY_RUN_TOTAL_PARTIAL" == false && "$files_cleaned" -eq 2 ]]
        grep -q 'PREVIEW:a' "$HOME/action-trace"
        grep -q 'PREVIEW:b' "$HOME/action-trace"
    fi
    [[ ! -f "$HOME/action-trace" ]] || cat "$HOME/action-trace"
fi
python3 -I -B - "$NATIVE_EVENTS" << 'PY'
import json,os,sys,time
from pathlib import Path
rows=[json.loads(x) for x in Path(sys.argv[1]).read_text().splitlines()]
for row in rows:
 if row['stage'] in ('native-prefix','controlled-native-stop','backend-signal','native-reaped'): print('NATIVE_EVENT='+json.dumps(row,sort_keys=True))
starts=[r for r in rows if r['stage']=='native-exec'];ends=[r for r in rows if r['stage']=='native-reaped']
assert len(starts)==len(ends)
for r in ends: assert r['pipes_closed']
identities=set()
for r in starts: identities.update((r['native_pid'],r['observer_pid'],r['backend_pid']))
for p in identities:
 try: os.kill(p,0)
 except ProcessLookupError: continue
 raise AssertionError('owned PID remains '+str(p))
for p in {r['pgid'] for r in starts}:
 try: os.killpg(p,0)
 except ProcessLookupError: continue
 raise AssertionError('owned PGID remains '+str(p))
if os.environ['NATIVE_CASE'] in ('app_scan','app_du','app_signal','project_scan'):
 stops=[r for r in rows if r['stage']=='controlled-native-stop']; assert len(stops)==1
 matching=[r for r in ends if r['native_pid']==stops[0]['native_pid']];assert matching[0]['native_exit']<0
 assert any(r['stage']=='backend-signal' and r['signum']==15 for r in rows)
 if os.environ['NATIVE_CASE']=='app_signal': assert any(r['stage']=='injected-backend-signal' and r['signum']==2 for r in rows)
 if os.environ['NATIVE_CASE']!='app_du': assert any(r['stage']=='native-prefix' and r['bytes']>0 for r in rows)
print('OWNED_NATIVE_CLOSURE='+json.dumps({'native_calls':len(starts),'pids':sorted(identities),'pgids':sorted({r['pgid'] for r in starts}),'all_reaped':True,'pipes_closed':True,'all_ESRCH':True}))
PY
