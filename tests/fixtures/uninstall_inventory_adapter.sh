#!/bin/bash
# Compatibility adapter for local orchestration cases. The common fixture
# owns metadata preparation and owner identity for old and upstream tests.
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$HOME/Applications" "$HOME/OtherApps")
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/Volumes"
# Generic local cases have no Homebrew owner; cask-specific cases mock it.
is_homebrew_available() { return 1; }
