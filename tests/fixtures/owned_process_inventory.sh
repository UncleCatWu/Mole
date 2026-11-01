#!/bin/bash
# A complete process inventory owned by the current private fixture shell.
# sandbox-exec denies native process-table access; do not turn that unknown
# result into an idle-owner assertion in tests of registry pruning.
# shellcheck disable=SC2329 # Called by production temp-root pruning.
ps() {
    case "$*" in
        '-axo pid=') printf '%s\n' "$$" "$PPID" ;;
        '-p '*) [[ "$2" == "$$" || "$2" == "$PPID" ]] ;;
        *)
            printf 'UNEXPECTED_PS:%s\n' "$*" >&2
            return 97
            ;;
    esac
}
