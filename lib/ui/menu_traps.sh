#!/bin/bash
# Restore the exact caller traps without replacing its cleanup functions.
if [[ -n "${MOLE_MENU_TRAPS_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_MENU_TRAPS_LOADED=1

mole_menu_restore_traps() {
    local saved_exit="${1:-}" saved_int="${2:-}" saved_term="${3:-}"
    if [[ -n "$saved_exit" ]]; then eval "$saved_exit"; else trap - EXIT; fi
    if [[ -n "$saved_int" ]]; then eval "$saved_int"; else trap - INT; fi
    if [[ -n "$saved_term" ]]; then eval "$saved_term"; else trap - TERM; fi
}
