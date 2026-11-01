#!/usr/bin/env bats
# Fixture-only install stages; never dispatch install.sh or contact a provider.
setup() {
    export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export INSTALL_FIXTURE="$(mktemp -d "$BATS_TEST_TMPDIR/install-hardening.XXXXXX")"
    export HOME="$INSTALL_FIXTURE/home" TMPDIR="$INSTALL_FIXTURE/tmp"
    mkdir -p "$HOME" "$TMPDIR"
    export MOLE_RESOLVED_TMPDIR="$TMPDIR" MOLE_TEST_NO_AUTH=1 MOLE_TEST_MODE=1
    unset SUDO_USER SUDO_UID SUDO_GID MOLE_TEMP_REGISTRY_FILE
}

@test "module copy failure stops an if-guarded install before publishing the entry" {
    run /bin/bash <<'SCRIPT'
set -euo pipefail
eval "$(sed -n '/^install_files() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
INSTALL_DIR="$HOME/prefix" CONFIG_DIR="$HOME/config" SOURCE_DIR="$HOME/source"
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR/bin" "$CONFIG_DIR/lib/core" "$SOURCE_DIR/bin" "$SOURCE_DIR/lib/core"
printf old-entry > "$INSTALL_DIR/mole"
printf '#!/bin/bash\nVERSION="1.2.3"\nSCRIPT_DIR=source\n' > "$SOURCE_DIR/mole"
printf module > "$SOURCE_DIR/bin/clean.sh"
printf library > "$SOURCE_DIR/lib/core/common.sh"
printf user-whitelist > "$CONFIG_DIR/whitelist"
printf user-purge-paths > "$CONFIG_DIR/purge_paths"
resolve_source_dir() { :; }; needs_sudo() { return 1; }
maybe_sudo() { "$@"; }
log_error() { printf 'ERROR:%s\n' "$*"; }
log_admin() { :; }; log_success() { printf 'UNEXPECTED_INSTALL_SUCCESS\n'; }
download_binary() { printf 'UNEXPECTED_HELPER_DOWNLOAD\n'; return 0; }
cp() { if [[ "$*" == *"$CONFIG_DIR/bin/"* ]]; then return 1; fi; command cp "$@"; }
rc=0
install_files || rc=$?
[[ $rc -ne 0 ]] || exit 1
[[ $(cat "$INSTALL_DIR/mole") == old-entry ]] || exit 2
[[ -f "$CONFIG_DIR/.helper_install_incomplete" ]] || exit 3
[[ $(cat "$CONFIG_DIR/whitelist") == user-whitelist && $(cat "$CONFIG_DIR/purge_paths") == user-purge-paths ]] || exit 4
printf 'MODULE_IO_FAILED_CLOSED\n'
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"MODULE_IO_FAILED_CLOSED"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_INSTALL_SUCCESS"* && "$output" != *"UNEXPECTED_HELPER_DOWNLOAD"* ]]
}

@test "repair marker symlink cannot truncate another file during install" {
    run /bin/bash <<'SCRIPT'
set -euo pipefail
eval "$(sed -n '/^install_files() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
INSTALL_DIR="$HOME/prefix" CONFIG_DIR="$HOME/config" SOURCE_DIR="$HOME/source"
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR/bin" "$CONFIG_DIR/lib" "$SOURCE_DIR"
printf '#!/bin/bash\nSCRIPT_DIR=source\n' > "$SOURCE_DIR/mole"
printf fixture-secret > "$HOME/sentinel"
ln -s "$HOME/sentinel" "$CONFIG_DIR/.helper_install_incomplete"
resolve_source_dir() { :; }; needs_sudo() { return 1; }; maybe_sudo() { "$@"; }
log_error() { printf 'ERROR:%s\n' "$*"; }; log_admin() { :; }; log_success() { :; }
download_binary() { printf 'UNEXPECTED_DOWNLOAD\n'; return 0; }
rc=0
install_files || rc=$?
[[ $rc -ne 0 && -L "$CONFIG_DIR/.helper_install_incomplete" ]] || exit 1
[[ $(cat "$HOME/sentinel") == fixture-secret ]] || exit 2
printf 'MARKER_SYMLINK_PRESERVED\n'
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"MARKER_SYMLINK_PRESERVED"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_DOWNLOAD"* ]]
}

@test "marker removal failure cannot print installed success" {
    run /bin/bash <<'SCRIPT'
set -euo pipefail
eval "$(sed -n '/^install_files() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
INSTALL_DIR="$HOME/prefix" CONFIG_DIR="$HOME/config" SOURCE_DIR="$HOME/source"
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR/bin" "$CONFIG_DIR/lib" "$SOURCE_DIR"
printf '#!/bin/bash\nSCRIPT_DIR=source\n' > "$SOURCE_DIR/mole"
resolve_source_dir() { :; }; needs_sudo() { return 1; }; maybe_sudo() { "$@"; }
log_error() { printf 'ERROR:%s\n' "$*"; }; log_admin() { :; }
log_success() { printf 'UNEXPECTED_INSTALL_SUCCESS\n'; : > "$HOME/install-success.trace"; }
download_binary() { printf 'HELPER_STAGE:%s\n' "$1"; return 0; }
rm() { [[ "$*" != *".helper_install_incomplete"* ]] || return 1; command rm "$@"; }
rc=0
install_files || rc=$?
[[ $rc -ne 0 && -f "$CONFIG_DIR/.helper_install_incomplete" ]] || exit 1
[[ ! -e "$HOME/install-success.trace" ]] || exit 2
printf 'MARKER_CLEAR_FAILED_CLOSED\n'
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"HELPER_STAGE:analyze"* && "$output" == *"HELPER_STAGE:status"* ]] || return 1
    [[ "$output" == *"MARKER_CLEAR_FAILED_CLOSED"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_INSTALL_SUCCESS"* ]]
}

@test "verification refuses incomplete or nonresponsive generations" {
    run /bin/bash <<'SCRIPT'
set -euo pipefail
eval "$(sed -n '/^verify_installation() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
INSTALL_DIR="$HOME/prefix" CONFIG_DIR="$HOME/config"
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR/lib/core"
printf '#!/bin/bash\nif [[ "$1" == --version ]]; then printf "Mole version 1.2.3\\n"; fi\nexit 0\n' > "$INSTALL_DIR/mole"
chmod +x "$INSTALL_DIR/mole"
: > "$CONFIG_DIR/lib/core/common.sh"
get_source_version() { printf '1.2.3\n'; }; get_installed_version() { printf '1.2.3\n'; }
run_install_probe_with_timeout() { shift; "$@"; }
log_error() { printf 'ERROR:%s\n' "$*"; }
verify_installation || exit 1
: > "$CONFIG_DIR/.helper_install_incomplete"
if verify_installation; then exit 2; fi
rm "$CONFIG_DIR/.helper_install_incomplete" # SAFE: exact fixture-created repair marker
run_install_probe_with_timeout() { return 124; }
if verify_installation; then exit 3; fi
printf 'RESPONSIVE_CONTROL_PASSED; INCOMPLETE_AND_TIMEOUT_REFUSED\n'
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RESPONSIVE_CONTROL_PASSED; INCOMPLETE_AND_TIMEOUT_REFUSED"* ]]
}

@test "env main helper build uses the selected source rather than an unrelated local binary" {
    run /bin/bash <<'SCRIPT'
set -euo pipefail
eval "$(sed -n '/^download_binary() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
SOURCE_DIR="$HOME/source" CONFIG_DIR="$HOME/config"
mkdir -p "$SOURCE_DIR/bin" "$CONFIG_DIR/bin"
printf unrelated-release > "$SOURCE_DIR/bin/analyze-go"
MOLE_VERSION=main
unset MOLE_EDGE_INSTALL
build_binary_from_source() { printf 'SOURCE_BUILD:%s\n' "$1"; printf selected-source > "$2"; }
install_staged_binary() { cp "$1" "$2"; }
log_success() { :; }; log_error() { printf 'ERROR:%s\n' "$*"; }
download_binary analyze
[[ $(cat "$CONFIG_DIR/bin/analyze-go") == selected-source ]] || exit 1
printf 'SOURCE_GENERATION_BOUND\n'
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"SOURCE_BUILD:analyze"* ]] || return 1
    [[ "$output" == *"SOURCE_GENERATION_BOUND"* ]]
}

@test "one config claim rejects another prefix but accepts a physical alias" {
    run /bin/bash <<'SCRIPT'
set -euo pipefail
eval "$(sed -n '/^claim_install_config_prefix() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
CONFIG_DIR="$HOME/config" INSTALL_DIR="$HOME/first"
mkdir -p "$CONFIG_DIR" "$INSTALL_DIR" "$HOME/second"
log_error() { printf 'ERROR:%s\n' "$*"; }
claim_install_config_prefix
first_claim=$(cat "$CONFIG_DIR/.install_prefix")
ln -s "$INSTALL_DIR" "$HOME/alias"
INSTALL_DIR="$HOME/alias"
claim_install_config_prefix
[[ "$INSTALL_DIR" != "$HOME/alias" ]] || exit 1
INSTALL_DIR="$HOME/second"
if claim_install_config_prefix; then exit 2; fi
[[ $(cat "$CONFIG_DIR/.install_prefix") == "$first_claim" ]] || exit 3
printf 'PHYSICAL_ALIAS_ACCEPTED; DIFFERENT_PREFIX_REFUSED\n'
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"PHYSICAL_ALIAS_ACCEPTED; DIFFERENT_PREFIX_REFUSED"* ]]
}

@test "empty in-flight config claim is preserved and refuses managed installation" {
    run /bin/bash <<'SCRIPT'
set -euo pipefail
eval "$(sed -n '/^claim_install_config_prefix() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
CONFIG_DIR="$HOME/config" INSTALL_DIR="$HOME/prefix"
mkdir -p "$CONFIG_DIR" "$INSTALL_DIR"
: > "$CONFIG_DIR/.install_prefix"
log_error() { printf 'ERROR:%s\n' "$*"; }
if claim_install_config_prefix; then exit 1; fi
[[ -f "$CONFIG_DIR/.install_prefix" && ! -s "$CONFIG_DIR/.install_prefix" ]] || exit 2
printf 'UNKNOWN_CLAIM_NEVER_RECLAIMED\n'
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"UNKNOWN_CLAIM_NEVER_RECLAIMED"* ]]
}

@test "root config policy rejects a user-mutable ancestor before any executor action" {
    run /bin/bash <<'SCRIPT'
set -euo pipefail
eval "$(sed -n '/^install_lock_has_unsafe_ancestor() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
eval "$(sed -n '/^install_config_has_unsafe_ancestor() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
CONFIG_DIR="$HOME/user-owned/config"
mkdir -p "$CONFIG_DIR"
# Passing true checks the privileged policy without running as root or sudo.
if ! install_config_has_unsafe_ancestor true; then exit 1; fi
[[ "$INSTALL_LOCK_UNSAFE_ANCESTOR_REASON" == not_root_owned ]] || exit 2
printf 'PRIVILEGED_CONFIG_MUTABLE_ANCESTOR_REFUSED\n'
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"PRIVILEGED_CONFIG_MUTABLE_ANCESTOR_REFUSED"* ]]
}

@test "published SCRIPT_DIR treats shell metacharacters and command substitutions as path data" {
    run /bin/bash <<'SCRIPT'
set -euo pipefail
eval "$(sed -n '/^install_files() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
INSTALL_DIR="$HOME/prefix" SOURCE_DIR="$HOME/source"
CONFIG_DIR="$HOME/"'config &| \ $(touch injected-one) `touch injected-two`'
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR/bin" "$CONFIG_DIR/lib" "$SOURCE_DIR"
cat > "$SOURCE_DIR/mole" <<'ENTRY'
#!/bin/bash
VERSION="1.2.3"
SCRIPT_DIR=source
printf '%s\n' "$SCRIPT_DIR" > "$HOME/observed-config"
if [[ "$1" == --version ]]; then printf 'Mole version 1.2.3\n'; fi
exit 0
ENTRY
resolve_source_dir() { :; }; needs_sudo() { return 1; }; maybe_sudo() { "$@"; }
log_error() { printf 'ERROR:%s\n' "$*"; }; log_admin() { :; }; log_success() { :; }
download_binary() { return 0; }
install_files || exit 1
cd "$HOME"
"$INSTALL_DIR/mole" --version
"$INSTALL_DIR/mole" --help
[[ $(cat "$HOME/observed-config") == "$CONFIG_DIR" ]] || exit 2
[[ ! -e "$HOME/injected-one" && ! -e "$HOME/injected-two" ]] || exit 3
printf 'SCRIPT_DIR_IS_LITERAL_DATA\n'
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"SCRIPT_DIR_IS_LITERAL_DATA"* ]]
}
