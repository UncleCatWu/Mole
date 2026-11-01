#!/bin/bash
# Local source generations coexist with official installations. Their owner
# receipt binds management to a physical prefix, never to a PATH guess.
set -euo pipefail
if [[ -n "${_MOLE_LOCAL_GENERATION_OWNER_LOADED:-}" ]]; then return 0; fi
readonly _MOLE_LOCAL_GENERATION_OWNER_LOADED=1

# 0: bound local generation; 1: ordinary installation; 2: expected local owner
# could not be verified. The expected context comes from the authored entry and
# its module root, independently of HOME (including sandbox/private HOME).
_mole_local_generation_owner_state() {
    _MOLE_LOCAL_OWNER_REASON=""
    _MOLE_LOCAL_OWNER_ROLLBACK=""
    _MOLE_LOCAL_OWNER_CONFIG="${SCRIPT_DIR:-}"
    local entry="${MOLE_ENTRY_SCRIPT:-}" config="${SCRIPT_DIR:-}" generation="" expected=false
    case "$entry" in */.local/share/mole/generations/*/bin/mole)
        generation="${entry%/bin/mole}"
        expected=true
        ;;
    esac
    case "$config" in
        */.local/share/mole/generations/*/config)
            expected=true
            [[ -n "$generation" ]] || generation="${config%/config}"
            ;;
    esac
    [[ "$expected" == true ]] || return 1
    _MOLE_LOCAL_OWNER_REASON="entry/config scope mismatch"
    [[ "$entry" == "$generation/bin/mole" && "$config" == "$generation/config" &&
        "${MOLE_CONFIG_DIR:-$config}" == "$config" ]] || return 2
    local prefix="$generation/bin" physical_prefix="" physical_config=""
    _MOLE_LOCAL_OWNER_REASON="generation components are missing or linked"
    [[ -f "$entry" && ! -L "$entry" && -d "$prefix" && ! -L "$prefix" &&
        -d "$config" && ! -L "$config" && ! -L "$generation" ]] || return 2
    physical_prefix=$(cd -P "$prefix" && /bin/pwd -P) || return 2
    physical_config=$(cd -P "$config" && /bin/pwd -P) || return 2
    [[ "$physical_prefix" == "$prefix" && "$physical_config" == "$config" ]] || return 2
    local owner="$config/.local_generation_owner" binding_file="$config/.install_prefix"
    _MOLE_LOCAL_OWNER_REASON="local ownership receipt is missing or unsafe"
    [[ -f "$owner" && ! -L "$owner" && -f "$binding_file" && ! -L "$binding_file" ]] || return 2
    [[ "$(/usr/bin/stat -f%u "$owner" 2> /dev/null)" == "$EUID" &&
    "$(/usr/bin/stat -f%Lp "$owner" 2> /dev/null)" == 600 &&
    "$(/usr/bin/stat -f%u "$prefix" 2> /dev/null)" == "$EUID" &&
    "$(/usr/bin/stat -f%u "$config" 2> /dev/null)" == "$EUID" ]] || return 2
    local schema="" binding="" config_id="" rollback="" rollback_hash="" extra=""
    IFS=$'\t' read -r schema binding config_id rollback rollback_hash extra < "$owner" || return 2
    _MOLE_LOCAL_OWNER_REASON="local ownership receipt is malformed"
    [[ "$schema" == MOLE_LOCAL_SOURCE_V1 && -z "$extra" &&
        "$rollback_hash" =~ ^[0-9a-f]{64}$ && "$(wc -l < "$owner")" -eq 1 ]] || return 2
    local expected_binding="$(/usr/bin/stat -f%d:%i "$prefix")|$physical_prefix" installed_binding=""
    IFS= read -r installed_binding < "$binding_file" || return 2
    _MOLE_LOCAL_OWNER_REASON="physical prefix/config identity does not match its owner"
    [[ "$binding" == "$expected_binding" && "$installed_binding" == "$expected_binding" &&
        "$config_id" == "$(/usr/bin/stat -f%d:%i "$config")" ]] || return 2
    _MOLE_LOCAL_OWNER_REASON="rollback identity or checksum could not be verified"
    [[ "$rollback" == "$config/rollback-to-homebrew.sh" && -f "$rollback" && ! -L "$rollback" &&
        "$(/usr/bin/stat -f%u "$rollback" 2> /dev/null)" == "$EUID" ]] || return 2
    local actual_hash=""
    actual_hash=$(/usr/bin/shasum -a 256 "$rollback" 2> /dev/null) || return 2
    [[ "${actual_hash%% *}" == "$rollback_hash" ]] || return 2
    _MOLE_LOCAL_OWNER_ROLLBACK="$rollback"
    _MOLE_LOCAL_OWNER_REASON="bound local source generation"
    return 0
}

# This is shared by direct CLI and interactive-menu management calls. Refuse
# before Homebrew detection, network resolution, or shared user-state cleanup.
mole_local_generation_management_guard() {
    local action="$1" owner_state=0
    _mole_local_generation_owner_state || owner_state=$?
    [[ $owner_state -ne 1 ]] || return 0
    if [[ $owner_state -eq 0 ]]; then
        printf 'Local source generation: %s cannot run the upstream installer or Homebrew removal.\n' "$action" >&2
        printf 'Restore the preserved official entry with: /bin/bash %q\n' "$_MOLE_LOCAL_OWNER_ROLLBACK" >&2
    else
        printf 'Local installation ownership could not be verified: %s; no installation owner was changed.\n' "$_MOLE_LOCAL_OWNER_REASON" >&2
        printf 'Inspect ownership before retrying: /bin/ls -ld %q\n' "$_MOLE_LOCAL_OWNER_CONFIG" >&2
    fi
    return 16
}
