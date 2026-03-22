#!/usr/bin/env bash
# ============================================================================
# git-autopush discover — scan for git repos and add them to repos.conf
# ============================================================================
set -euo pipefail

CONF_DIR="/etc/git-autopush"
CONF_FILE="${CONF_DIR}/config"
REPOS_FILE="${CONF_DIR}/repos.conf"

# --- Colors ---------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
fail()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# --- Usage ----------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [DIRECTORY]

Recursively scan for git repos and add them to git-autopush.

Options:
  -d DIR    Directory to scan (overrides interactive prompt)
  -q        Quiet mode — skip interactive directory prompt, scan current dir
  -k KEY    SSH key path to use for added repos
  -y        Skip confirmation, add all discovered repos
  -h        Show this help

By default, prompts interactively for a directory to scan.

Examples:
  $(basename "$0")                  # Interactive prompt for directory
  $(basename "$0") -d /home/user    # Scan specific directory (no prompt)
  $(basename "$0") -q               # Scan current directory (no prompt)
  $(basename "$0") /srv             # Scan /srv (no prompt)
EOF
    exit 0
}

# --- Detect SSH key -------------------------------------------------------
detect_ssh_key() {
    # 1. Check existing git-autopush config
    if [[ -f "$CONF_FILE" ]]; then
        local conf_key
        conf_key=$(grep -oP '^\s*SSH_KEY\s*=\s*"\K[^"]+' "$CONF_FILE" 2>/dev/null || true)
        if [[ -n "$conf_key" && -f "$conf_key" ]]; then
            echo "$conf_key"
            return 0
        fi
    fi

    # 2. Check GIT_SSH_COMMAND env
    if [[ -n "${GIT_SSH_COMMAND:-}" ]]; then
        local env_key
        env_key=$(echo "$GIT_SSH_COMMAND" | grep -oP '(?<=-i\s)\S+' || true)
        if [[ -n "$env_key" && -f "$env_key" ]]; then
            echo "$env_key"
            return 0
        fi
    fi

    # 3. Check ssh-agent loaded keys
    local agent_key
    agent_key=$(ssh-add -L 2>/dev/null | head -1 | awk '{print $NF}' || true)
    if [[ -n "$agent_key" && -f "$agent_key" ]]; then
        echo "$agent_key"
        return 0
    fi

    # 4. Scan ~/.ssh for private keys (common naming patterns)
    local ssh_dir="${HOME}/.ssh"
    if [[ -d "$ssh_dir" ]]; then
        local key_names=("id_ed25519" "id_rsa" "id_ecdsa" "id_ed25519_sk")
        # Also look for github-specific keys
        local github_keys
        github_keys=$(find "$ssh_dir" -maxdepth 1 -type f -name '*github*' ! -name '*.pub' 2>/dev/null || true)
        if [[ -n "$github_keys" ]]; then
            echo "$github_keys" | head -1
            return 0
        fi
        for name in "${key_names[@]}"; do
            if [[ -f "${ssh_dir}/${name}" ]]; then
                echo "${ssh_dir}/${name}"
                return 0
            fi
        done
    fi

    return 1
}

# --- Scan for git repos ---------------------------------------------------
scan_repos() {
    local scan_dir="$1"
    local repos=()

    # info message to stderr so it doesn't pollute captured stdout
    info "Scanning ${scan_dir} for git repositories..." >&2

    # Find all .git directories, then get parent paths
    # -prune nested .git dirs (submodules, worktrees inside repos)
    while IFS= read -r gitdir; do
        local repo_path
        repo_path=$(dirname "$gitdir")
        repo_path=$(cd "$repo_path" && pwd)  # resolve to absolute path
        repos+=("$repo_path")
    done < <(find "$scan_dir" -name .git -type d 2>/dev/null | sort)

    if [[ ${#repos[@]} -eq 0 ]]; then
        warn "No git repositories found in ${scan_dir}" >&2
        exit 0
    fi

    printf '%s\n' "${repos[@]}"
}

# --- Get existing repos from conf -----------------------------------------
get_existing_repos() {
    if [[ ! -f "$REPOS_FILE" ]]; then
        return
    fi
    grep -v '^\s*#' "$REPOS_FILE" | grep -v '^\s*$' | while IFS='|' read -r path _ _; do
        echo "$path" | xargs
    done || true
}

# --- Multi-select menu ----------------------------------------------------
# Interactive terminal menu: arrow keys to navigate, space to toggle, enter to confirm
multi_select() {
    local -n _items=$1
    local -n _selected=$2
    local count=${#_items[@]}
    local cursor=0

    # Save terminal state
    local saved_stty
    saved_stty=$(stty -g)
    stty -echo -icanon

    # Hide cursor
    printf '\e[?25l'

    # Cleanup on exit
    local cleanup_done=0
    cleanup_menu() {
        if [[ $cleanup_done -eq 0 ]]; then
            cleanup_done=1
            printf '\e[?25h'  # Show cursor
            stty "$saved_stty"
        fi
    }
    trap cleanup_menu EXIT INT TERM

    draw_menu() {
        # Move cursor to start of menu area
        if [[ $count -gt 0 ]]; then
            printf '\e[%dA' "$((count + 2))" 2>/dev/null || true
        fi

        echo -e "${BOLD}  Select repos to add ${DIM}(↑/↓ navigate, SPACE toggle, A=all, N=none, ENTER confirm)${NC}"
        echo ""
        for i in $(seq 0 $((count - 1))); do
            local marker=" "
            [[ "${_selected[$i]}" == "1" ]] && marker="✓"
            local prefix="  "
            [[ $i -eq $cursor ]] && prefix="▸ "
            if [[ $i -eq $cursor ]]; then
                printf '\e[K'  # Clear line
                echo -e "${CYAN}${prefix}[${marker}] ${_items[$i]}${NC}"
            else
                printf '\e[K'
                echo -e "  ${prefix}[${marker}] ${_items[$i]}"
            fi
        done
    }

    # Print initial blank lines for menu area
    for _ in $(seq 0 $((count + 1))); do echo; done

    draw_menu

    while true; do
        local key
        key=$(dd bs=1 count=1 2>/dev/null) || true
        if [[ "$key" == $'\x1b' ]]; then
            local seq1 seq2
            seq1=$(dd bs=1 count=1 2>/dev/null) || true
            seq2=$(dd bs=1 count=1 2>/dev/null) || true
            case "${seq1}${seq2}" in
                '[A') # Up arrow
                    (( cursor > 0 )) && (( cursor-- ))
                    ;;
                '[B') # Down arrow
                    (( cursor < count - 1 )) && (( cursor++ ))
                    ;;
            esac
        elif [[ "$key" == " " ]]; then
            # Toggle selection
            if [[ "${_selected[$cursor]}" == "1" ]]; then
                _selected[$cursor]=0
            else
                _selected[$cursor]=1
            fi
        elif [[ "$key" == "a" || "$key" == "A" ]]; then
            for i in $(seq 0 $((count - 1))); do _selected[$i]=1; done
        elif [[ "$key" == "n" || "$key" == "N" ]]; then
            for i in $(seq 0 $((count - 1))); do _selected[$i]=0; done
        elif [[ "$key" == "" ]]; then
            # Enter key
            break
        fi
        draw_menu
    done

    cleanup_menu
    trap - EXIT INT TERM
    echo ""
}

# --- Fallback simple menu (non-interactive terminal) -----------------------
simple_select() {
    local -n _items=$1
    local -n _selected=$2
    local count=${#_items[@]}

    echo -e "${BOLD}Discovered repos:${NC}"
    echo ""
    for i in $(seq 0 $((count - 1))); do
        local marker="*"
        printf "  %3d) [%s] %s\n" "$((i + 1))" "$marker" "${_items[$i]}"
    done
    echo ""
    echo "Enter selections (e.g., '1 3 5', 'all', or 'none')."
    echo -n "Default=all > "
    read -r input

    case "${input,,}" in
        ""|all)
            for i in $(seq 0 $((count - 1))); do _selected[$i]=1; done
            ;;
        none)
            for i in $(seq 0 $((count - 1))); do _selected[$i]=0; done
            ;;
        *)
            for i in $(seq 0 $((count - 1))); do _selected[$i]=0; done
            for num in $input; do
                if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= count )); then
                    _selected[$((num - 1))]=1
                else
                    warn "Ignoring invalid selection: $num"
                fi
            done
            ;;
    esac
}

# --- Get repo metadata (remote, branch) ------------------------------------
get_repo_info() {
    local repo_path="$1"
    local remote branch

    # Get first remote (prefer 'origin')
    if git -C "$repo_path" remote | grep -qx origin 2>/dev/null; then
        remote="origin"
    else
        remote=$(git -C "$repo_path" remote 2>/dev/null | head -1)
    fi

    # Get current branch
    branch=$(git -C "$repo_path" branch --show-current 2>/dev/null)

    # Fallback for detached HEAD
    if [[ -z "$branch" ]]; then
        branch=$(git -C "$repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    fi

    if [[ -z "$remote" ]]; then remote="origin"; fi
    if [[ -z "$branch" ]]; then branch="main"; fi

    echo "${remote}|${branch}"
}

# --- Main -----------------------------------------------------------------
main() {
    local scan_dir=""
    local quiet=0
    local ssh_key=""
    local auto_yes=0

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d)
                [[ -n "${2:-}" ]] || fail "-d requires a directory argument"
                scan_dir="$2"
                shift 2
                ;;
            -q)
                quiet=1
                shift
                ;;
            -k)
                [[ -n "${2:-}" ]] || fail "-k requires an SSH key path"
                ssh_key="$2"
                shift 2
                ;;
            -y)
                auto_yes=1
                shift
                ;;
            -h|--help)
                usage
                ;;
            -*)
                fail "Unknown option: $1 (see -h for help)"
                ;;
            *)
                scan_dir="$1"
                shift
                ;;
        esac
    done

    # Interactive directory prompt (default unless -d, -q, -y, or positional arg given)
    if [[ -z "$scan_dir" && $quiet -eq 0 && $auto_yes -eq 0 && -t 0 && -t 1 ]]; then
        echo -n "Directory to scan [$(pwd)]: "
        read -r scan_dir
    fi

    # Default to current directory
    if [[ -z "$scan_dir" ]]; then scan_dir="$(pwd)"; fi

    # Resolve to absolute path
    scan_dir=$(cd "$scan_dir" 2>/dev/null && pwd) || fail "Directory not found: $scan_dir"

    [[ -d "$scan_dir" ]] || fail "Not a directory: ${scan_dir}"

    # --- Check config exists -----------------------------------------------
    if [[ ! -f "$REPOS_FILE" ]]; then
        fail "repos.conf not found at ${REPOS_FILE} — run install.sh first"
    fi

    # --- SSH key detection -------------------------------------------------
    if [[ -z "$ssh_key" ]]; then
        ssh_key=$(detect_ssh_key || true)
    fi
    if [[ -n "$ssh_key" ]]; then
        info "Detected SSH key: ${ssh_key}"
    else
        warn "No SSH key detected — repos will use default SSH config"
    fi

    # --- Scan for repos ----------------------------------------------------
    local discovered=()
    while IFS= read -r repo; do
        discovered+=("$repo")
    done < <(scan_repos "$scan_dir")

    if [[ ${#discovered[@]} -eq 0 ]]; then
        exit 0
    fi

    info "Found ${#discovered[@]} git repo(s)"

    # --- Filter out already-configured repos --------------------------------
    local existing_list
    existing_list=$(get_existing_repos)
    local new_repos=()
    local skipped=0
    for repo in "${discovered[@]}"; do
        if echo "$existing_list" | grep -qxF "$repo" 2>/dev/null; then
            (( skipped++ )) || true
        else
            new_repos+=("$repo")
        fi
    done

    if [[ $skipped -gt 0 ]]; then
        warn "Skipped ${skipped} repo(s) already in repos.conf"
    fi

    if [[ ${#new_repos[@]} -eq 0 ]]; then
        info "All discovered repos are already configured — nothing to add"
        exit 0
    fi

    # --- Selection ---------------------------------------------------------
    local count=${#new_repos[@]}
    local selected=()
    for i in $(seq 0 $((count - 1))); do selected+=("1"); done   # default all selected

    if [[ $auto_yes -eq 0 ]]; then
        # Check if terminal is interactive
        if [[ -t 0 && -t 1 ]]; then
            multi_select new_repos selected
        else
            simple_select new_repos selected
        fi
    fi

    # --- Gather selected repos and metadata --------------------------------
    local to_add=()
    for i in $(seq 0 $((count - 1))); do
        if [[ "${selected[$i]}" == "1" ]]; then
            to_add+=("${new_repos[$i]}")
        fi
    done

    if [[ ${#to_add[@]} -eq 0 ]]; then
        warn "No repos selected — nothing to add"
        exit 0
    fi

    # --- Confirm addition --------------------------------------------------
    echo ""
    echo -e "${BOLD}Repos to add to git-autopush:${NC}"
    local entries=()
    for repo in "${to_add[@]}"; do
        local meta remote branch
        meta=$(get_repo_info "$repo")
        remote="${meta%%|*}"
        branch="${meta##*|}"
        entries+=("${repo} | ${remote} | ${branch}")
        echo -e "  ${GREEN}+${NC} ${repo}  ${DIM}(${remote}/${branch})${NC}"
    done

    if [[ $auto_yes -eq 0 ]]; then
        echo ""
        echo -n "Add these ${#to_add[@]} repo(s) to ${REPOS_FILE}? [Y/n] "
        read -r confirm
        case "${confirm,,}" in
            n|no)
                warn "Aborted"
                exit 0
                ;;
        esac
    fi

    # --- Write to repos.conf -----------------------------------------------
    # Check write permission (may need sudo)
    if [[ ! -w "$REPOS_FILE" ]]; then
        warn "No write permission to ${REPOS_FILE} — trying with sudo"
        for entry in "${entries[@]}"; do
            echo "$entry" | sudo tee -a "$REPOS_FILE" > /dev/null
        done
    else
        for entry in "${entries[@]}"; do
            echo "$entry" >> "$REPOS_FILE"
        done
    fi

    info "Added ${#to_add[@]} repo(s) to ${REPOS_FILE}"

    # --- Update SSH_KEY in config if empty and we detected one --------------
    if [[ -n "$ssh_key" && -f "$CONF_FILE" ]]; then
        local current_key
        current_key=$(grep -oP '^\s*SSH_KEY\s*=\s*"\K[^"]*' "$CONF_FILE" 2>/dev/null || true)
        if [[ -z "$current_key" ]]; then
            echo ""
            echo -n "Set SSH_KEY=\"${ssh_key}\" in config? [Y/n] "
            if [[ $auto_yes -eq 1 ]]; then
                echo "y (auto)"
                confirm="y"
            else
                read -r confirm
            fi
            case "${confirm,,}" in
                n|no) ;;
                *)
                    if [[ -w "$CONF_FILE" ]]; then
                        sed -i "s|^SSH_KEY=\"\"|SSH_KEY=\"${ssh_key}\"|" "$CONF_FILE"
                    else
                        sudo sed -i "s|^SSH_KEY=\"\"|SSH_KEY=\"${ssh_key}\"|" "$CONF_FILE"
                    fi
                    info "Updated SSH_KEY in ${CONF_FILE}"
                    ;;
            esac
        fi
    fi

    echo ""
    info "Done! Run 'sudo git-autopush list' to verify."
}

main "$@"
