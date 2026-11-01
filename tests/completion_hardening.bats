#!/usr/bin/env bats
setup() {
    export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export COMPLETION_FIXTURE="$(mktemp -d "$BATS_TEST_TMPDIR/completion-hardening.XXXXXX")"
    export HOME="$COMPLETION_FIXTURE/home" TMPDIR="$COMPLETION_FIXTURE/tmp"
    mkdir -p "$HOME" "$TMPDIR" "$COMPLETION_FIXTURE/stubs"
    export MOLE_RESOLVED_TMPDIR="$TMPDIR" MOLE_TEST_NO_AUTH=1 MOLE_TEST_MODE=1
    unset SUDO_USER SUDO_UID SUDO_GID MOLE_TEMP_REGISTRY_FILE BASH_ENV ENV
    printf '#!/bin/sh\nprintf ":\\n"\n' > "$COMPLETION_FIXTURE/stubs/mole"
    chmod +x "$COMPLETION_FIXTURE/stubs/mole"
    export PATH="$COMPLETION_FIXTURE/stubs:/usr/bin:/bin" SHELL=/bin/bash
}

@test "completion stale cleanup preserves user multi-line conditions byte for byte" {
    run /bin/bash <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
eval "$(sed -n '/^completion_owned_tail_start() {/,/^if \[\[ \$# -gt 0 \]\]; then/p' "$PROJECT_ROOT/bin/completion.sh" | sed '$d')"
# Baseline lacks the new helper header, so also extract its legacy entry point.
if ! declare -f remove_stale_completion_entries >/dev/null; then
    eval "$(sed -n '/^remove_stale_completion_entries() {/,/^}/p' "$PROJECT_ROOT/bin/completion.sh")"
fi
cat > "$HOME/.bashrc" <<'CONFIG'
if true; then
    eval "$(mole completion bash)"
    printf 'user body\n'
fi
CONFIG
before=$(cksum "$HOME/.bashrc")
rc=0
remove_stale_completion_entries "$HOME/.bashrc" "" bash || rc=$?
[[ $rc -eq 1 && $(cksum "$HOME/.bashrc") == "$before" ]] || exit 1
/bin/bash --noprofile --norc -n "$HOME/.bashrc"
printf 'CUSTOM_CONDITION_PRESERVED\n'
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"CUSTOM_CONDITION_PRESERVED"* ]]
}

@test "completion refuses invalid existing config without changing it" {
    # shellcheck disable=SC2016  # Write literal shell initialization text.
    printf 'if true; then\neval "$(mole completion bash)"\n' > "$HOME/.bashrc"
    before=$(cksum "$HOME/.bashrc")
    run "$PROJECT_ROOT/bin/completion.sh" </dev/null
    [ "$status" -ne 0 ] || return 1
    [[ $(cksum "$HOME/.bashrc") == "$before" ]] || return 1
    [[ "$output" == *"invalid; left unchanged"* ]]
}

@test "completion refuses a config symlink rather than replacing it" {
    # shellcheck disable=SC2016  # Write literal shell initialization text.
    printf '# Mole shell completion\neval "$(mole completion bash)"\n' > "$HOME/real-config"
    ln -s "$HOME/real-config" "$HOME/.bashrc"
    before=$(cksum "$HOME/real-config")
    run "$PROJECT_ROOT/bin/completion.sh" </dev/null
    [ "$status" -ne 0 ] || return 1
    [ -L "$HOME/.bashrc" ] || return 1
    [[ $(cksum "$HOME/real-config") == "$before" ]] || return 1
    [[ "$output" == *"symlink"* ]]
}

@test "completion migrates only its terminal legacy block and preserves mode and user code" {
    cat > "$HOME/.bashrc" <<'CONFIG'
if true; then
    eval "$(mole completion bash)"
    printf 'manual user body\n'
fi
# Mole shell completion
eval "$(mo completion bash)"
CONFIG
    chmod 640 "$HOME/.bashrc"
    run "$PROJECT_ROOT/bin/completion.sh" </dev/null
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"updated"* ]] || return 1
    [[ $(stat -f%Lp "$HOME/.bashrc") == 640 ]] || return 1
    run /bin/bash --noprofile --norc -n "$HOME/.bashrc"
    [ "$status" -eq 0 ] || return 1
    [ "$(grep -c 'manual user body' "$HOME/.bashrc")" -eq 1 ] || return 1
    [ "$(grep -c '^    eval ' "$HOME/.bashrc")" -eq 1 ] || return 1
    [ "$(grep -c '^# >>> Mole shell completion >>>' "$HOME/.bashrc")" -eq 1 ]
}

@test "completion dry-run leaves managed config and permissions unchanged" {
    # shellcheck disable=SC2016  # Write literal shell initialization text.
    printf '# Mole shell completion\neval "$(mo completion bash)"\n' > "$HOME/.bashrc"
    chmod 640 "$HOME/.bashrc"
    before=$(cksum "$HOME/.bashrc")
    run "$PROJECT_ROOT/bin/completion.sh" --dry-run </dev/null
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DRY RUN MODE"* ]] || return 1
    [[ $(cksum "$HOME/.bashrc") == "$before" && $(stat -f%Lp "$HOME/.bashrc") == 640 ]]
}

@test "Fish completion refuses a peer generation change before publishing either file" {
    export SHELL=fish
    mkdir -p "$HOME/.config/fish/completions"
    printf '# Completions for mole\n# original generation\n' > "$HOME/.config/fish/completions/mole.fish"
    printf '# Mole completions for mo (alias) -- auto-generated, do not edit\n# original alias\n' > "$HOME/.config/fish/completions/mo.fish"
    before=$(cksum "$HOME/.config/fish/completions/mole.fish")
    # This provider only validates the control flow; it never runs Fish or
    # changes a system shell. The generator owns the simulated peer write.
    printf '#!/bin/sh\nexit 0\n' > "$COMPLETION_FIXTURE/stubs/fish"
    cat > "$COMPLETION_FIXTURE/stubs/mole" <<'PROVIDER'
#!/bin/sh
printf '# Completions for mole\n# new generation\n'
printf '# peer-authored generation\n' > "$HOME/.config/fish/completions/mo.fish"
PROVIDER
    chmod +x "$COMPLETION_FIXTURE/stubs/fish" "$COMPLETION_FIXTURE/stubs/mole"
    run "$PROJECT_ROOT/bin/completion.sh" </dev/null
    [ "$status" -ne 0 ] || return 1
    [[ $(cksum "$HOME/.config/fish/completions/mole.fish") == "$before" ]] || return 1
    [[ $(cat "$HOME/.config/fish/completions/mo.fish") == '# peer-authored generation' ]] || return 1
    [[ "$output" == *"changed during completion preparation"* ]]
}
