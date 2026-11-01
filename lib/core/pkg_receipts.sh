#!/bin/bash
# Mole - pkgutil receipt helpers.
# Finds package-installed app bundles outside the standard app locations.

set -euo pipefail

if [[ -n "${MOLE_PKG_RECEIPTS_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_PKG_RECEIPTS_LOADED=1

pkg_receipt_nonstandard_app_paths() {
    local require_complete=0
    [[ "${1:-}" == "--require-complete" ]] && require_complete=1
    if ! command -v pkgutil > /dev/null 2>&1; then
        [[ "$require_complete" != "1" ]] || return 2
        return 0
    fi
    local cache_file="${MOLE_PKG_RECEIPT_CACHE_FILE:-$HOME/.cache/mole/pkg_receipt_apps_v2}"
    local cache_ttl=3600
    local now_epoch=0
    if declare -f get_epoch_seconds > /dev/null 2>&1; then
        now_epoch=$(get_epoch_seconds)
    else
        now_epoch=$(date +%s 2> /dev/null || echo 0)
    fi

    # One budget covers both receipt listing and every payload read. Starting
    # it after --pkgs would spend the caller's remaining deadline twice.
    local scan_start=$SECONDS
    local scan_timeout="${MOLE_PKG_RECEIPT_SCAN_TIMEOUT:-8}"
    local scan_deadline=0
    if [[ "$scan_timeout" =~ ^[0-9]+$ && $scan_timeout -gt 0 ]]; then
        scan_deadline=$((scan_start + scan_timeout))
    elif [[ "$require_complete" == "1" ]]; then
        return 2
    fi
    local list_timeout="${MOLE_PKG_RECEIPT_LIST_TIMEOUT:-3}"
    if [[ $scan_deadline -gt 0 ]]; then
        local list_remaining=$((scan_deadline - SECONDS))
        if [[ $list_remaining -le 0 ]]; then
            [[ "$require_complete" != "1" ]] || return 124
            return 0
        fi
        local list_whole="${list_timeout%%.*}"
        if [[ "$list_whole" =~ ^[0-9]+$ ]] && ((10#$list_whole >= list_remaining)); then
            list_timeout="$list_remaining"
        fi
    fi

    # `pkgutil --pkgs` is one cheap call; what costs seconds on an Xcode Mac is
    # the per-receipt `--files` walk below (#1383). So the receipt list is read
    # first and doubles as the UI cache key. A reinstall can change a receipt's
    # payload without changing its id; complete deletion evidence never reuses
    # this report-only cache.
    local pkgs_output=""
    local pkgs_rc=0
    if declare -f run_with_timeout > /dev/null 2>&1; then
        pkgs_output=$(run_with_timeout "$list_timeout" \
            pkgutil --pkgs 2> /dev/null) || pkgs_rc=$?
    else
        pkgs_output=$(pkgutil --pkgs 2> /dev/null) || pkgs_rc=$?
    fi
    if [[ $pkgs_rc -ne 0 ]]; then
        if [[ "$require_complete" == "1" ]]; then
            mole_rc_timeout_or_signal "$pkgs_rc" && return "$pkgs_rc"
            return 2
        fi
        return 0
    fi
    [[ -n "$pkgs_output" ]] || return 0

    # The list alone misses an upgrade or reinstall that keeps its package id,
    # which can still add an app at a new path. The installer rewrites that
    # receipt's plist every time, so its mtime joins the key. Only a key that
    # covers both may outlive the short TTL.
    local receipts_dir="${MOLE_PKG_RECEIPT_DB_DIR:-/var/db/receipts}"
    local receipt_stamps=""
    receipt_stamps=$(LC_ALL=C "$STAT_BSD" -f '%m %N' "$receipts_dir"/*.plist 2> /dev/null) || receipt_stamps=""
    if [[ -n "$receipt_stamps" ]]; then
        cache_ttl=604800
    fi

    local receipts_fingerprint=""
    receipts_fingerprint=$(printf '%s\n%s\n' "$pkgs_output" "$receipt_stamps" | LC_ALL=C cksum 2> /dev/null |
        LC_ALL=C tr -cd '0-9 ' | LC_ALL=C tr ' ' '-') || receipts_fingerprint=""
    receipts_fingerprint="${receipts_fingerprint%-}"

    # This cache is a listing hint only. Neither a TTL nor the receipt-id list
    # proves that payloads are unchanged, so --require-complete always scans.
    if [[ "$require_complete" != "1" && "${MOLE_PKG_RECEIPT_CACHE_DISABLE:-0}" != "1" &&
        -n "$receipts_fingerprint" && -r "$cache_file" ]]; then
        local cache_mtime=0
        if declare -f get_file_mtime > /dev/null 2>&1; then
            cache_mtime=$(get_file_mtime "$cache_file")
        else
            cache_mtime=$("$STAT_BSD" -f "%m" "$cache_file" 2> /dev/null || echo 0)
        fi
        if [[ "$cache_ttl" =~ ^[0-9]+$ && "$cache_mtime" =~ ^[0-9]+$ &&
            "$now_epoch" =~ ^[0-9]+$ && $cache_ttl -gt 0 &&
            $((now_epoch - cache_mtime)) -lt $cache_ttl ]]; then
            local cache_header=""
            IFS= read -r cache_header < "$cache_file" || cache_header=""
            if [[ "$cache_header" == "#receipts-v2:complete:$receipts_fingerprint" ]]; then
                local cache_line_no=0
                while IFS= read -r cached_app_path; do
                    cache_line_no=$((cache_line_no + 1))
                    [[ $cache_line_no -eq 1 ]] && continue
                    [[ -n "$cached_app_path" && -d "$cached_app_path" ]] && printf '%s\n' "$cached_app_path"
                done < "$cache_file"
                return 0
            fi
        fi
    fi

    local -a seen_apps=()
    local scan_complete=true
    local pkg_id
    while IFS= read -r pkg_id; do
        if [[ "$scan_timeout" =~ ^[0-9]+$ && $scan_timeout -gt 0 && $((SECONDS - scan_start)) -ge $scan_timeout ]]; then
            [[ "$require_complete" == "1" ]] && return 124
            scan_complete=false
            break
        fi

        [[ -n "$pkg_id" ]] || continue
        [[ "$pkg_id" =~ ^com\.apple\. ]] && continue

        local pkg_files=""
        local pkg_files_rc=0
        if [[ "$require_complete" == "1" ]]; then
            local remaining=$((scan_deadline - SECONDS))
            [[ $remaining -gt 0 ]] || return 124
            if declare -f run_with_timeout > /dev/null 2>&1; then
                pkg_files=$(run_with_timeout "$remaining" \
                    pkgutil --files "$pkg_id" 2> /dev/null) || pkg_files_rc=$?
            else
                pkg_files=$(pkgutil --files "$pkg_id" 2> /dev/null) || pkg_files_rc=$?
            fi
            if [[ $pkg_files_rc -ne 0 ]]; then
                mole_rc_timeout_or_signal "$pkg_files_rc" && return "$pkg_files_rc"
                return 2
            fi
        else
            if [[ $scan_deadline -gt 0 ]]; then
                local remaining=$((scan_deadline - SECONDS))
                if [[ $remaining -le 0 ]]; then
                    scan_complete=false
                    break
                fi
                if declare -f run_with_timeout > /dev/null 2>&1; then
                    pkg_files=$(run_with_timeout "$remaining" \
                        pkgutil --files "$pkg_id" 2> /dev/null) || pkg_files_rc=$?
                else
                    pkg_files=$(pkgutil --files "$pkg_id" 2> /dev/null) || pkg_files_rc=$?
                fi
            else
                pkg_files=$(pkgutil --files "$pkg_id" 2> /dev/null) || pkg_files_rc=$?
            fi
        fi
        if [[ $pkg_files_rc -ne 0 ]]; then
            [[ $pkg_files_rc -ge 128 ]] && return "$pkg_files_rc"
            scan_complete=false
            # A failed producer's partial prefix cannot enter even a UI cache.
            continue
        fi
        [[ -n "$pkg_files" ]] || continue

        local rel_path app_path duplicate
        while IFS= read -r rel_path; do
            if [[ "$scan_timeout" =~ ^[0-9]+$ && $scan_timeout -gt 0 && $((SECONDS - scan_start)) -ge $scan_timeout ]]; then
                [[ "$require_complete" == "1" ]] && return 124
                scan_complete=false
                break 2
            fi

            local stripped="${rel_path#/}"
            [[ -n "$stripped" ]] || continue
            local candidate="/$stripped"

            case "$candidate" in
                /usr/local/*.[aA][pP][pP]) app_path="$candidate" ;;
                /opt/*.[aA][pP][pP]) app_path="$candidate" ;;
                /usr/local/*.[aA][pP][pP]/* | /opt/*.[aA][pP][pP]/*)
                    local app_prefix app_suffix_and_rest app_suffix
                    app_prefix="${candidate%%.[aA][pP][pP]/*}"
                    app_suffix_and_rest="${candidate#"$app_prefix"}"
                    app_suffix="${app_suffix_and_rest%%/*}"
                    app_path="${app_prefix}${app_suffix}"
                    ;;
                *) continue ;;
            esac

            # Record the path whether or not it exists now: the cache can
            # outlive this scan, and an app that is briefly missing (in the
            # Trash, mid self-update) must not disappear from a complete
            # answer until its receipt changes. Existence is checked on output.
            [[ -n "$app_path" ]] || continue

            duplicate=false
            local seen
            # First candidate runs with seen_apps still empty, and bash 3.2
            # under set -u aborts on an empty-array expansion (#1354).
            for seen in ${seen_apps[@]+"${seen_apps[@]}"}; do
                if [[ "$seen" == "$app_path" ]]; then
                    duplicate=true
                    break
                fi
            done
            [[ "$duplicate" == "true" ]] && continue

            seen_apps+=("$app_path")
        done <<< "$pkg_files"
    done <<< "$pkgs_output"

    if [[ ${#seen_apps[@]} -gt 0 ]]; then
        local seen_app
        if ! for seen_app in "${seen_apps[@]}"; do
            if [[ -d "$seen_app" ]]; then
                printf '%s\n' "$seen_app"
            fi
        done | sort -u; then
            [[ "$require_complete" == "1" ]] && return 2
        fi
    fi

    # Publish only completed observations. A partial ordinary scan must not
    # poison a later listing, and strict callers never use the cache as proof.
    if [[ "$scan_complete" == "true" && "${MOLE_PKG_RECEIPT_CACHE_DISABLE:-0}" != "1" && -n "$cache_file" &&
        -n "$receipts_fingerprint" ]]; then
        local cache_dir="${cache_file%/*}"
        if [[ -n "$cache_dir" && "$cache_dir" != "$cache_file" ]]; then
            if declare -f ensure_user_dir > /dev/null 2>&1; then
                ensure_user_dir "$cache_dir"
            else
                mkdir -p "$cache_dir" 2> /dev/null || true
            fi
        fi
        local cache_tmp
        cache_tmp=$(mktemp "${TMPDIR:-/tmp}/mole.pkg_receipts.XXXXXX" 2> /dev/null || true)
        if [[ -n "$cache_tmp" ]]; then
            local cache_write_ok=true
            printf '#receipts-v2:complete:%s\n' "$receipts_fingerprint" > "$cache_tmp" || cache_write_ok=false
            if [[ ${#seen_apps[@]} -gt 0 ]]; then
                printf '%s\n' "${seen_apps[@]}" | sort -u >> "$cache_tmp" || cache_write_ok=false
            fi
            if [[ "$cache_write_ok" == "true" ]] && mv -f "$cache_tmp" "$cache_file" 2> /dev/null; then
                :
            else
                rm -f "$cache_tmp" 2> /dev/null || true # SAFE: exact mktemp-created cache staging file
            fi
        fi
    fi
}
