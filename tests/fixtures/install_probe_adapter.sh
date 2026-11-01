#!/bin/bash
# Test-only process metadata for explicitly registered fixture shell PIDs.
# Real kill -0, children, kernel locks and release behavior remain unchanged.
fixture_prepare_install_probe() {
    export FIXTURE_INSTALL_PROBE_ROOT="$HOME/install-probe"
    mkdir -p "$FIXTURE_INSTALL_PROBE_ROOT/pids"
    cat > "$FIXTURE_INSTALL_PROBE_ROOT/ps" << 'PROBE'
#!/bin/sh
[ "$1" = -p ] && [ "$3" = -o ] && [ "$4" = lstart= ] || exit 2
case "$2" in ''|*[!0-9]*) exit 2 ;; esac
[ -f "$FIXTURE_INSTALL_PROBE_ROOT/pids/$2" ] || exit 1
[ ! -f "$FIXTURE_INSTALL_PROBE_ROOT/unknown" ] || exit 1
kill -0 "$2" 2>/dev/null || exit 1
printf 'fixture-owned-%s\n' "$2"
PROBE
    chmod +x "$FIXTURE_INSTALL_PROBE_ROOT/ps"
}

fixture_patch_install_probe_file() {
    python3 - "$1" "$FIXTURE_INSTALL_PROBE_ROOT" << 'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
root = Path(sys.argv[2])
text = path.read_text()
assert '/bin/ps -p "$pid" -o lstart=' in text
assert '[[ "$current_pid" =~ ^[0-9]+$ ]] || return 1' in text
assert text.count('[[ \"$probe\" == \"/\" ]] && break') == 1
text = text.replace('[[ \"$probe\" == \"/\" ]] && break',
    '[[ \"$probe\" == \"$MOLE_TEST_RUN_ROOT\" ]] && break')
text = text.replace('/bin/ps', str(root / 'ps'))
text = text.replace('[[ "$current_pid" =~ ^[0-9]+$ ]] || return 1',
    '[[ "$current_pid" =~ ^[0-9]+$ ]] || return 1\n'
    '    : > "$FIXTURE_INSTALL_PROBE_ROOT/pids/$current_pid" || return 1')
path.write_text(text)
PY
}

# Native acceptance roots live under sticky /private/tmp. Production must
# reject that ancestry; a fixture's kernel boundary is its explicit trust root.
# Keep ownership, modes, ACLs and symlinks checked through that root itself.
fixture_bind_install_ancestor_check() {
    local prefix="$1" body name old_site new_site
    [[ -n "${MOLE_TEST_RUN_ROOT:-}" && -d "$MOLE_TEST_RUN_ROOT" ]] || return 1
    name="${prefix}has_unsafe_ancestor"
    [[ "$prefix" != _update_lock_ ]] || name="${prefix}path_has_unsafe_ancestor"
    body=$(declare -f "$name") || return 1
    # shellcheck disable=SC2016 # Match one real stop site in the extracted helper.
    old_site='[[ "$probe" == "/" ]] && break'
    # shellcheck disable=SC2016 # The fixture process expands this at runtime.
    new_site='[[ "$probe" == "$MOLE_TEST_RUN_ROOT" ]] && break'
    [[ "$body" == *"$old_site"* ]] || return 1
    local suffix="${body#*"$old_site"}"
    [[ "$suffix" != *"$old_site"* ]] || return 1
    body=${body/"$old_site"/"$new_site"}
    eval "$body"
}

fixture_bind_install_probe_functions() {
    local prefix="$1" body
    fixture_bind_install_ancestor_check "$prefix" || return 1
    # Only these existing production functions receive the metadata adapter.
    # Every acquisition still discovers and registers its actual shell PID.
    body=$(declare -f "${prefix}current_shell_pid") || return 1
    # shellcheck disable=SC2016 # Patch literal production source before evaluating it.
    body=${body/'[[ "$current_pid" =~ ^[0-9]+$ ]] || return 1'/'[[ "$current_pid" =~ ^[0-9]+$ ]] || return 1; : > "$FIXTURE_INSTALL_PROBE_ROOT/pids/$current_pid" || return 1'}
    eval "$body"
    body=$(declare -f "${prefix}process_start") || return 1
    body=${body//\/bin\/ps/$FIXTURE_INSTALL_PROBE_ROOT\/ps}
    eval "$body"
    if [[ "$prefix" == install_lock_ ]]; then
        body=$(declare -f acquire_install_lock)
    else body=$(declare -f _update_acquire_lock); fi
    body=${body//\/bin\/ps/$FIXTURE_INSTALL_PROBE_ROOT\/ps}
    eval "$body"
}
