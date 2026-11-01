#!/bin/bash
# User state and installed tools must never run with inherited root privileges.
# Individual maintenance operations request administrator access themselves.
if [[ "$EUID" -eq 0 ]]; then
    printf '%s\n' 'Run Mole without sudo; it requests administrator access when needed.' >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/lib/core/common.sh"
source "$ROOT_DIR/lib/core/commands.sh"

command_names=()
for entry in "${MOLE_COMMANDS[@]}"; do
    command_names+=("${entry%%:*}")
done
command_words="${command_names[*]}"
clean_option_words="--dry-run -n --external --whitelist --debug --help -h"
analyze_option_words="--json --help -h"
history_option_words="--json --limit --help -h"
purge_option_words="--paths --dry-run -n --yes --include-empty --debug --help -h"

emit_zsh_subcommands() {
    for entry in "${MOLE_COMMANDS[@]}"; do
        printf "        '%s:%s'\n" "${entry%%:*}" "${entry#*:}"
    done
}

emit_fish_completions() {
    local cmd="$1"
    for entry in "${MOLE_COMMANDS[@]}"; do
        local name="${entry%%:*}"
        local desc="${entry#*:}"
        printf 'complete -f -c %s -n "__fish_mole_no_subcommand" -a %s -d "%s"\n' "$cmd" "$name" "$desc"
    done

    printf '\n'
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from clean" -l dry-run -s n -d "Preview cleanup without making changes"\n' "$cmd"
    printf 'complete -c %s -n "__fish_seen_subcommand_from clean" -l external -r -a "(__fish_complete_directories)" -d "Clean OS metadata from an external volume"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from clean" -l whitelist -d "Manage protected paths"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from clean" -l debug -d "Show detailed logs"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from clean" -l help -s h -d "Show help"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from analyze analyse" -l json -d "Output analysis as JSON"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from analyze analyse" -l help -s h -d "Show help"\n' "$cmd"
    printf 'complete -c %s -n "__fish_seen_subcommand_from analyze analyse; and not __fish_seen_argument -l json -l help -s h" -a "(__fish_complete_directories)" -d "Path to analyze"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from history" -l json -d "Output history as JSON"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from history" -l limit -r -d "Limit recent entries"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from history" -l help -s h -d "Show help"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from purge" -l paths -d "Edit custom scan directories"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from purge" -l dry-run -s n -d "Preview purge actions without making changes"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from purge" -l include-empty -d "Show zero-size project artifact directories"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from purge" -l yes -d "Confirm unattended cleanup of eligible artifacts"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from purge" -l debug -d "Show detailed logs"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from purge" -l help -s h -d "Show help"\n' "$cmd"
    printf '\n'
    printf 'complete -f -c %s -n "not __fish_mole_no_subcommand" -a bash -d "generate bash completion" -n "__fish_see_subcommand_path completion"\n' "$cmd"
    printf 'complete -f -c %s -n "not __fish_mole_no_subcommand" -a zsh -d "generate zsh completion" -n "__fish_see_subcommand_path completion"\n' "$cmd"
    printf 'complete -f -c %s -n "not __fish_mole_no_subcommand" -a fish -d "generate fish completion" -n "__fish_see_subcommand_path completion"\n' "$cmd"
}

# Only a terminal, recognisable Mole block is managed. User-authored multi-line
# conditions or functions containing completion commands are left intact.
completion_owned_tail_start() {
    local config_file="$1"
    [[ -f "$config_file" ]] || {
        printf '0\n'
        return 0
    }
    awk '
        function generated(line, c, s, q, cmd, shell) {
            q = sprintf("%c", 34)
            for (c = 1; c <= 2; c++) {
                cmd = (c == 1 ? "mole" : "mo")
                for (s = 1; s <= 3; s++) {
                    shell = (s == 1 ? "bash" : (s == 2 ? "zsh" : "fish"))
                    if (line == "eval " q "$(" cmd " completion " shell ")" q ||
                        line == "if output=" q "$(" cmd " completion " shell " 2>/dev/null)" q "; then eval " q "$output" q "; fi" ||
                        line == cmd " completion fish | source") return 1
                }
            }
            return 0
        }
        { lines[NR] = $0 }
        END {
            last = NR
            while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
            if (lines[last] == "# <<< Mole shell completion <<<") {
                if (last < 3 || lines[last-2] != "# >>> Mole shell completion >>>" || !generated(lines[last-1])) exit 2
                print last-2
            } else if (last > 1 && lines[last-1] == "# Mole shell completion" && generated(lines[last])) {
                print last-1
            } else {
                if (lines[last] == "# >>> Mole shell completion >>>") exit 2
                print 0
            }
        }
    ' "$config_file"
}

completion_check_syntax() {
    local shell_name="$1" config_file="$2"
    case "$shell_name" in
        bash) run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" /bin/bash --noprofile --norc -n "$config_file" ;;
        zsh) run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" /bin/zsh -f -n "$config_file" ;;
        fish)
            local fish_binary
            fish_binary=$(command -v fish) || {
                log_error "Fish is unavailable for config syntax validation"
                return 2
            }
            run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" "$fish_binary" --no-execute "$config_file"
            ;;
        *) return 2 ;;
    esac
}

completion_check_config() {
    local config_file="$1" shell_name="$2"
    [[ ! -L "$config_file" ]] || {
        log_error "Shell config is a symlink; edit its target explicitly: $config_file"
        return 2
    }
    [[ ! -e "$config_file" || -f "$config_file" ]] || return 2
    if [[ -f "$config_file" ]]; then
        local owner
        owner=$("$STAT_BSD" -f%u "$config_file" 2> /dev/null) || return 2
        [[ "$owner" == "$(id -u)" ]] || {
            log_error "Shell config is owned by another user: $config_file"
            return 2
        }
        completion_check_syntax "$shell_name" "$config_file" || {
            log_error "Existing shell config is invalid; left unchanged: $config_file"
            return 2
        }
    fi
}

completion_config_fingerprint() {
    local config_file="$1"
    if [[ ! -e "$config_file" ]]; then
        printf 'missing\n'
        return 0
    fi
    "$STAT_BSD" -f%d:%i:%Lp "$config_file" || return 1
    cksum "$config_file" || return 1
}

completion_write_block() {
    local config_file="$1" shell_name="$2" operation="$3" completion_line="${4:-}"
    completion_check_config "$config_file" "$shell_name" || return 2
    local tail_start
    tail_start=$(completion_owned_tail_start "$config_file") || {
        log_error "Unrecognisable completion block; left unchanged: $config_file"
        return 2
    }
    [[ "$operation" != remove || "$tail_start" -gt 0 ]] || return 1
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        printf '[DRY RUN] Would %s managed completion in %s\n' "$operation" "$config_file"
        return 0
    fi
    local expected_fingerprint current_fingerprint original_mode=""
    expected_fingerprint=$(completion_config_fingerprint "$config_file") || return 2
    if [[ -f "$config_file" ]]; then original_mode=$("$STAT_BSD" -f%Lp "$config_file") || return 2; fi
    local temp_file
    temp_file=$(mktemp "$(dirname "$config_file")/.mole-completion.XXXXXX") || return 2
    if [[ -f "$config_file" ]]; then
        if ! cp -p "$config_file" "$temp_file" || ! chmod u+w "$temp_file"; then
            rm -f "$temp_file" # SAFE: exact completion staging file created above
            return 2
        fi
        local keep_lines
        keep_lines=$(awk 'END { print NR }' "$config_file") || return 2
        [[ "$tail_start" -eq 0 ]] || keep_lines=$((tail_start - 1))
        if ! awk -v keep="$keep_lines" 'NR <= keep { print }' "$config_file" > "$temp_file"; then
            rm -f "$temp_file" # SAFE: exact completion staging file created above
            return 2
        fi
    fi
    if [[ "$operation" == install ]] &&
        ! printf '\n# >>> Mole shell completion >>>\n%s\n# <<< Mole shell completion <<<\n' "$completion_line" >> "$temp_file"; then
        rm -f "$temp_file" # SAFE: exact completion staging file created above
        return 2
    fi
    if ! completion_check_syntax "$shell_name" "$temp_file"; then
        log_error "Completion change did not pass full config syntax validation: $config_file"
        rm -f "$temp_file" # SAFE: exact completion staging file created above
        return 2
    fi
    if [[ -n "$original_mode" ]] && ! chmod "$original_mode" "$temp_file"; then
        rm -f "$temp_file" # SAFE: exact completion staging file created above
        return 2
    fi
    current_fingerprint=$(completion_config_fingerprint "$config_file") || return 2
    if [[ "$current_fingerprint" != "$expected_fingerprint" || -L "$config_file" ]]; then
        log_error "Shell config changed during completion preparation; left unchanged: $config_file"
        rm -f "$temp_file" # SAFE: exact completion staging file created above
        return 2
    fi
    if ! mv -f "$temp_file" "$config_file"; then
        rm -f "$temp_file" # SAFE: exact completion staging file created above
        return 2
    fi
    return 0
}

remove_stale_completion_entries() {
    local config_file="$1" success_message="$2"
    local shell_name="${3:-${current_shell:-bash}}" result=0
    completion_write_block "$config_file" "$shell_name" remove || result=$?
    [[ $result -eq 0 ]] || return "$result"
    [[ -z "$success_message" ]] || printf '%s\n' "$success_message"
}

if [[ $# -gt 0 ]]; then
    normalized_args=()
    for arg in "$@"; do
        case "$arg" in
            "--dry-run" | "-n")
                export MOLE_DRY_RUN=1
                ;;
            *)
                normalized_args+=("$arg")
                ;;
        esac
    done
    if [[ ${#normalized_args[@]} -gt 0 ]]; then
        set -- "${normalized_args[@]}"
    else
        set --
    fi
fi

# Auto-install mode when run without arguments
if [[ $# -eq 0 ]]; then
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        echo -e "${YELLOW}${ICON_DRY_RUN} DRY RUN MODE${NC}, shell config files will not be modified"
    fi
    current_shell="${SHELL##*/}"
    [[ -n "$current_shell" ]] || current_shell=$(ps -p "$PPID" -o comm= 2> /dev/null | awk '{print $1}')
    completion_name=""
    if command -v mole > /dev/null 2>&1; then
        completion_name=mole
    elif command -v mo > /dev/null 2>&1; then completion_name=mo; fi
    case "$current_shell" in
        bash)
            config_file="$HOME/.bashrc"
            [[ ! -f "$HOME/.bash_profile" ]] || config_file="$HOME/.bash_profile"
            ;;
        zsh) config_file="$HOME/.zshrc" ;;
        fish) config_file="$HOME/.config/fish/config.fish" ;;
        *)
            log_error "Unsupported shell: $current_shell"
            exit 1
            ;;
    esac
    completion_check_config "$config_file" "$current_shell" || exit 1
    if [[ -z "$completion_name" ]]; then
        removal_status=0
        remove_stale_completion_entries "$config_file" "Removed stale managed completion entries from $config_file" "$current_shell" || removal_status=$?
        [[ $removal_status -lt 2 ]] || exit 1
        log_error "mole not found in PATH, install Mole before enabling completion"
        exit 1
    fi
    if [[ "$current_shell" == fish ]]; then
        fish_dir="$HOME/.config/fish/completions"
        mole_file="$fish_dir/mole.fish"
        mo_file="$fish_dir/mo.fish"
        if [[ "${MOLE_DRY_RUN:-0}" == 1 ]]; then
            printf '[DRY RUN] Would write Fish completions to %s and %s\n' "$mole_file" "$mo_file"
            exit 0
        fi
        if [[ ! -f "$mole_file" ]]; then
            printf 'Enable completion for fish? Enter confirm / Q cancel: '
            if ! IFS= read -r -s -n1 key; then
                echo "Cancelled"
                exit 1
            fi
            case "$key" in "" | $'\n' | $'\r' | [Yy]) ;; *)
                echo "Cancelled"
                exit 0
                ;;
            esac
        fi
        mkdir -p "$fish_dir" || exit 1
        for fish_file in "$mole_file" "$mo_file"; do
            completion_check_config "$fish_file" fish || exit 1
            [[ ! -L "$fish_file" ]] || {
                log_error "Completion file is a symlink: $fish_file"
                exit 1
            }
            if [[ -e "$fish_file" ]] && ! head -n1 "$fish_file" |
                grep -Eq '^# (Completions for mole|Mole completions for mo \(alias\) -- auto-generated, do not edit)$'; then
                log_error "Completion file is not a managed Mole file: $fish_file"
                exit 1
            fi
        done
        fish_expected=$(completion_config_fingerprint "$mole_file") || exit 1
        mo_expected=$(completion_config_fingerprint "$mo_file") || exit 1
        fish_stage=$(mktemp "$fish_dir/.mole-fish.XXXXXX") || exit 1
        if ! "$completion_name" completion fish > "$fish_stage" ||
            ! completion_check_syntax fish "$fish_stage"; then
            rm -f "$fish_stage" # SAFE: exact Fish completion staging file
            exit 1
        fi
        if [[ -f "$mole_file" ]]; then
            fish_mode=$("$STAT_BSD" -f%Lp "$mole_file") || exit 1
            chmod "$fish_mode" "$fish_stage" || exit 1
        fi
        mo_stage=$(mktemp "$fish_dir/.mole-mo.XXXXXX") || exit 1
        fish_source_path=${mole_file//\\/\\\\}
        fish_source_path=${fish_source_path//\"/\\\"}
        fish_source_path=${fish_source_path//\$/\\\$}
        printf '# Mole completions for mo (alias) -- auto-generated, do not edit\nsource "%s"\n' "$fish_source_path" > "$mo_stage" || exit 1
        completion_check_syntax fish "$mo_stage" || exit 1
        if [[ -f "$mo_file" ]]; then
            fish_mode=$("$STAT_BSD" -f%Lp "$mo_file") || exit 1
            chmod "$fish_mode" "$mo_stage" || exit 1
        fi
        # Finish both stages before publishing, then bind them to the exact
        # generation inspected before calling the external generator.
        fish_current=$(completion_config_fingerprint "$mole_file") || exit 1
        mo_current=$(completion_config_fingerprint "$mo_file") || exit 1
        if [[ "$fish_current" != "$fish_expected" || "$mo_current" != "$mo_expected" ||
            -L "$mole_file" || -L "$mo_file" ]]; then
            log_error "Fish config changed during completion preparation; left unchanged: $fish_dir"
            rm -f "$fish_stage" "$mo_stage" # SAFE: exact Fish completion staging files created above
            exit 1
        fi
        removal_status=0
        remove_stale_completion_entries "$config_file" "Removed stale managed completion entries from config.fish" fish || removal_status=$?
        [[ $removal_status -lt 2 ]] || exit 1
        mv -f "$fish_stage" "$mole_file" || exit 1
        mv -f "$mo_stage" "$mo_file" || exit 1
        printf 'Fish completions written to %s\n' "$fish_dir"
        exit 0
    fi
    # shellcheck disable=SC2016
    completion_line='if output="$('"$completion_name"' completion '"$current_shell"' 2>/dev/null)"; then eval "$output"; fi'
    tail_start=$(completion_owned_tail_start "$config_file") || {
        log_error "Unrecognisable completion block: $config_file"
        exit 1
    }
    if [[ "$tail_start" -eq 0 && "${MOLE_DRY_RUN:-0}" != 1 ]]; then
        printf 'Will add to %s:\n  %s\nEnable completion? Enter confirm / Q cancel: ' "$config_file" "$completion_line"
        if ! IFS= read -r -s -n1 key; then
            echo "Cancelled"
            exit 1
        fi
        drain_pending_input
        case "$key" in "" | $'\n' | $'\r' | [Yy]) ;; *)
            echo "Cancelled"
            exit 0
            ;;
        esac
    fi
    completion_write_block "$config_file" "$current_shell" install "$completion_line" || exit 1
    if [[ "${MOLE_DRY_RUN:-0}" != 1 ]]; then
        if [[ "$tail_start" -gt 0 ]]; then
            echo "Shell completion updated in $config_file"
        else echo "Completion added to $config_file"; fi
    fi
    exit 0
fi

case "$1" in
    bash)
        cat << EOF
_mole_completions()
{
    local cur_word prev_word subcommand
    cur_word="\${COMP_WORDS[\$COMP_CWORD]}"
    prev_word="\${COMP_WORDS[\$COMP_CWORD-1]}"
    subcommand="\${COMP_WORDS[1]}"

    if [ "\$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=( \$(compgen -W "$command_words" -- "\$cur_word") )
    else
        case "\$subcommand" in
            clean)
                case "\$prev_word" in
                    --external)
                        COMPREPLY=( \$(compgen -d -- "\$cur_word") )
                        ;;
                    *)
                        COMPREPLY=( \$(compgen -W "$clean_option_words" -- "\$cur_word") )
                        ;;
                esac
                ;;
            analyze|analyse)
                if [[ "\$cur_word" == -* ]]; then
                    COMPREPLY=( \$(compgen -W "$analyze_option_words" -- "\$cur_word") )
                else
                    COMPREPLY=( \$(compgen -f -- "\$cur_word") )
                fi
                ;;
            history)
                COMPREPLY=( \$(compgen -W "$history_option_words" -- "\$cur_word") )
                ;;
            purge)
                COMPREPLY=( \$(compgen -W "$purge_option_words" -- "\$cur_word") )
                ;;
            completion)
                COMPREPLY=( \$(compgen -W "bash zsh fish" -- "\$cur_word") )
                ;;
            *)
                COMPREPLY=()
                ;;
        esac
    fi
}

complete -F _mole_completions mole mo
EOF
        ;;
    zsh)
        printf '#compdef mole mo\n\n'
        printf '_mole() {\n'
        printf '    local -a subcommands\n'
        printf '    subcommands=(\n'
        emit_zsh_subcommands
        printf '    )\n'
        printf '    if (( CURRENT == 2 )); then\n'
        printf "        _describe 'subcommand' subcommands\n"
        printf '        return\n'
        printf '    fi\n'
        printf "    case \"\$words[2]\" in\n"
        printf '        clean)\n'
        printf '            _arguments \\\n'
        printf "                '--dry-run[Preview cleanup without making changes]' \\\\\n"
        printf "                '-n[Preview cleanup without making changes]' \\\\\n"
        printf "                '--external[Clean OS metadata from an external volume]:path:_files -/' \\\\\n"
        printf "                '--whitelist[Manage protected paths]' \\\\\n"
        printf "                '--debug[Show detailed logs]' \\\\\n"
        printf "                '(-h --help)'{-h,--help}'[Show help]'\n"
        printf '            ;;\n'
        printf '        analyze|analyse)\n'
        printf '            _arguments \\\n'
        printf "                '--json[Output analysis as JSON]' \\\\\n"
        printf "                '(-h --help)'{-h,--help}'[Show help]' \\\\\n"
        printf "                '*:path:_files'\n"
        printf '            ;;\n'
        printf '        history)\n'
        printf '            _arguments \\\n'
        printf "                '--json[Output history as JSON]' \\\\\n"
        printf "                '--limit[Limit recent entries]:limit:' \\\\\n"
        printf "                '(-h --help)'{-h,--help}'[Show help]'\n"
        printf '            ;;\n'
        printf '        purge)\n'
        printf '            _arguments \\\n'
        printf "                '--paths[Edit custom scan directories]' \\\\\n"
        printf "                '--dry-run[Preview purge actions without making changes]' \\\\\n"
        printf "                '-n[Preview purge actions without making changes]' \\\\\n"
        printf "                '--include-empty[Show zero-size project artifact directories]' \\\\\n"
        printf "                '--yes[Confirm unattended cleanup of eligible artifacts]' \\\\\n"
        printf "                '--debug[Show detailed logs]' \\\\\n"
        printf "                '(-h --help)'{-h,--help}'[Show help]'\n"
        printf '            ;;\n'
        printf '        completion)\n'
        printf "            _arguments '1:shell:(bash zsh fish)'\n"
        printf '            ;;\n'
        printf '        *)\n'
        printf "            _describe 'subcommand' subcommands\n"
        printf '            ;;\n'
        printf '    esac\n'
        printf '}\n\n'
        printf 'compdef _mole mole mo\n'
        ;;
    fish)
        printf '# Completions for mole\n'
        emit_fish_completions mole
        printf '\n# Completions for mo (alias)\n'
        emit_fish_completions mo
        printf '\nfunction __fish_mole_no_subcommand\n'
        printf '    for i in (commandline -opc)\n'
        # shellcheck disable=SC2016
        printf '        if contains -- $i %s\n' "$command_words"
        printf '            return 1\n'
        printf '        end\n'
        printf '    end\n'
        printf '    return 0\n'
        printf 'end\n\n'
        printf 'function __fish_see_subcommand_path\n'
        printf '    string match -q -- "completion" (commandline -opc)[1]\n'
        printf 'end\n'
        ;;
    *)
        cat << 'EOF'
Usage: mole completion [bash|zsh|fish]

Setup shell tab completion for mole and mo commands.

Auto-install:
  mole completion              # Auto-detect shell and install
  mole completion --dry-run    # Preview config changes without writing files

Manual install:
  mole completion bash         # Generate bash completion script
  mole completion zsh          # Generate zsh completion script
  mole completion fish         # Generate fish completion script

Examples:
  # Auto-install (recommended)
  mole completion

  # Manual install - Bash
  eval "$(mole completion bash)"

  # Manual install - Zsh
  eval "$(mole completion zsh)"

  # Manual install - Fish
  mole completion fish | source
EOF
        [[ "$1" == "--help" || "$1" == "-h" ]] && exit 0
        exit 1
        ;;
esac
