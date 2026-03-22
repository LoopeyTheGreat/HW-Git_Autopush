#!/usr/bin/env bash
# ============================================================================
# git-autopush installer
# Deploys: execution script, config, systemd service+timer, logrotate
# Re-runnable: safe to run again to update components
# ============================================================================
set -euo pipefail

INSTALL_DIR="/usr/local/lib/git-autopush"
BIN_LINK="/usr/local/bin/git-autopush"
CONF_DIR="/etc/git-autopush"
SYSTEMD_DIR="/etc/systemd/system"
LOGROTATE_DIR="/etc/logrotate.d"
LOG_DIR="/var/log/git-autopush"
RUN_USER=$(stat -c '%U' /opt 2>/dev/null || echo "root")
RUN_HOME=$(eval echo "~${RUN_USER}")

# --- Colors ---------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
fail()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# --- Pre-flight checks -----------------------------------------------------
[[ $EUID -eq 0 ]] || fail "Run as root:  sudo bash $0"
command -v git   >/dev/null || fail "git is not installed"
command -v systemctl >/dev/null || fail "systemd is required"

# --- Auto-detect first repo ------------------------------------------------
detect_first_repo() {
    if [[ -d /opt/.git ]]; then
        local remote branch
        remote=$(git -C /opt remote 2>/dev/null | head -1)
        branch=$(git -C /opt branch --show-current 2>/dev/null)
        [[ -n "$remote" && -n "$branch" ]] && echo "/opt|${remote}|${branch}"
    fi
}

# ============================================================================
# 1. Main execution script
# ============================================================================
install_script() {
    info "Installing execution script → ${INSTALL_DIR}/git-autopush.sh"
    mkdir -p "$INSTALL_DIR"
    cat > "${INSTALL_DIR}/git-autopush.sh" << 'EXECSCRIPT'
#!/usr/bin/env bash
# ============================================================================
# git-autopush — automated git add / commit / push for managed repos
# ============================================================================
set -uo pipefail

CONF_DIR="/etc/git-autopush"
CONF_FILE="${CONF_DIR}/config"
REPOS_FILE="${CONF_DIR}/repos.conf"
LOCK_FILE="/run/git-autopush/git-autopush.lock"

# --- Defaults (overridden by config) ----------------------------------------
LOG_FILE="/var/log/git-autopush/git-autopush.log"
COMMIT_MSG_TEMPLATE="auto-backup: {hostname} {date}"
DIRTY_POLICY="commit"    # commit | skip
PUSH_RETRIES=3
PUSH_RETRY_DELAY=10
SSH_KEY=""                # set in config or GIT_SSH_COMMAND env

# --- Helpers ----------------------------------------------------------------
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()  { echo "[$(ts)] $*" >> "$LOG_FILE" 2>/dev/null; echo "[$(ts)] $*"; }
logn() { echo "[$(ts)] $*" >> "$LOG_FILE"; }   # log only (no stdout)

cleanup() { rm -f "$LOCK_FILE"; }
trap cleanup EXIT

# --- Load config ------------------------------------------------------------
load_config() {
    [[ -f "$CONF_FILE" ]] || { log "ERROR: config not found: $CONF_FILE"; exit 1; }
    # shellcheck source=/dev/null
    source "$CONF_FILE"
    mkdir -p "$(dirname "$LOG_FILE")"

    # Set up SSH key if configured and GIT_SSH_COMMAND isn't already set
    if [[ -n "${SSH_KEY:-}" && -z "${GIT_SSH_COMMAND:-}" ]]; then
        export GIT_SSH_COMMAND="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=accept-new"
    fi
}

# --- Lock (prevent overlapping runs) ----------------------------------------
acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
    if [[ -e "$LOCK_FILE" ]]; then
        local pid
        pid=$(<"$LOCK_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log "SKIP: another instance running (PID $pid)"
            exit 0
        fi
        log "WARN: stale lock for PID $pid — removing"
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
}

# --- Build commit message ---------------------------------------------------
build_msg() {
    local repo_path="$1"
    local msg="$COMMIT_MSG_TEMPLATE"
    msg="${msg//\{hostname\}/$(hostname)}"
    msg="${msg//\{date\}/$(date '+%Y-%m-%d %H:%M')}"
    msg="${msg//\{path\}/$repo_path}"
    echo "$msg"
}

# --- Push with retries ------------------------------------------------------
try_push() {
    local repo_path="$1" remote="$2" branch="$3"
    local attempt=0 rc
    while (( attempt < PUSH_RETRIES )); do
        (( attempt++ ))
        local output
        output=$(git -C "$repo_path" push "$remote" "$branch" 2>&1) && rc=0 || rc=$?
        echo "$output" >> "$LOG_FILE" 2>/dev/null
        echo "$output"
        if [[ $rc -eq 0 ]]; then
            return 0
        fi
        log "  WARN: push attempt ${attempt}/${PUSH_RETRIES} failed"
        (( attempt < PUSH_RETRIES )) && sleep "$PUSH_RETRY_DELAY"
    done
    return 1
}

# --- Process a single repo --------------------------------------------------
process_repo() {
    local repo_path="$1" remote="$2" branch="$3"
    local status_count

    log "--- Processing: ${repo_path} (${remote}/${branch})"

    # Validate
    if [[ ! -d "${repo_path}/.git" ]]; then
        log "  ERROR: not a git repo — skipping"
        return 1
    fi

    # Check remote exists
    if ! git -C "$repo_path" remote | grep -qx "$remote"; then
        log "  ERROR: remote '${remote}' not found — skipping"
        return 1
    fi

    # Handle dirty working tree
    status_count=$(git -C "$repo_path" status --porcelain 2>/dev/null | wc -l)
    if (( status_count > 0 )); then
        log "  Found ${status_count} changed/untracked files"
        case "$DIRTY_POLICY" in
            commit)
                log "  Policy: commit — staging all changes"
                git -C "$repo_path" add -A >> "$LOG_FILE" 2>&1
                local msg commit_output commit_rc
                msg=$(build_msg "$repo_path")
                commit_output=$(git -C "$repo_path" commit -m "$msg" 2>&1) && commit_rc=0 || commit_rc=$?
                echo "$commit_output" >> "$LOG_FILE" 2>/dev/null
                echo "$commit_output"
                if [[ $commit_rc -ne 0 ]]; then
                    log "  WARN: commit exited $commit_rc (may be nothing to commit after .gitignore)"
                fi
                ;;
            skip)
                log "  Policy: skip — repo is dirty, skipping"
                return 0
                ;;
            *)
                log "  ERROR: unknown DIRTY_POLICY '${DIRTY_POLICY}'"
                return 1
                ;;
        esac
    else
        log "  Working tree clean — nothing to commit"
    fi

    # Check if there are commits to push
    local ahead
    ahead=$(git -C "$repo_path" rev-list --count "${remote}/${branch}..HEAD" 2>/dev/null || echo "0")
    if (( ahead == 0 )); then
        log "  Already up-to-date with ${remote}/${branch}"
        return 0
    fi

    log "  Pushing ${ahead} commit(s) to ${remote}/${branch}"
    if try_push "$repo_path" "$remote" "$branch"; then
        log "  Push successful"
    else
        log "  ERROR: push failed after ${PUSH_RETRIES} attempts"
        return 1
    fi
}

# --- Main -------------------------------------------------------------------
main() {
    local mode="${1:-auto}"   # auto (from timer) | manual | list
    load_config

    case "$mode" in
        list)
            echo "Configured repos (${REPOS_FILE}):"
            echo "---"
            grep -v '^\s*#' "$REPOS_FILE" | grep -v '^\s*$' | while IFS='|' read -r path remote branch _; do
                path=$(echo "$path" | xargs)
                remote=$(echo "$remote" | xargs)
                branch=$(echo "$branch" | xargs)
                local status="OK"
                [[ -d "${path}/.git" ]] || status="NOT A GIT REPO"
                printf "  %-30s  %s/%s  [%s]\n" "$path" "$remote" "$branch" "$status"
            done
            return 0
            ;;
        manual)
            log "=== Manual run triggered ==="
            ;;
        auto|"")
            log "=== Scheduled run ==="
            ;;
    esac

    acquire_lock

    [[ -f "$REPOS_FILE" ]] || { log "ERROR: repos file not found: $REPOS_FILE"; exit 1; }

    local total=0 ok=0 fail=0
    while IFS='|' read -r path remote branch _; do
        # Skip comments and blank lines
        path=$(echo "$path" | xargs)
        [[ -z "$path" || "$path" == \#* ]] && continue
        remote=$(echo "$remote" | xargs)
        branch=$(echo "$branch" | xargs)

        (( total++ ))
        if process_repo "$path" "$remote" "$branch"; then
            (( ok++ ))
        else
            (( fail++ ))
        fi
    done < "$REPOS_FILE"

    log "=== Done: ${total} repos processed — ${ok} ok, ${fail} failed ==="
}

main "$@"
EXECSCRIPT
    chmod 755 "${INSTALL_DIR}/git-autopush.sh"

    # Symlink to PATH
    ln -sf "${INSTALL_DIR}/git-autopush.sh" "$BIN_LINK"
    info "Symlinked → ${BIN_LINK}"
}

# ============================================================================
# 2. Configuration files
# ============================================================================
install_config() {
    mkdir -p "$CONF_DIR"

    # --- Main config ---
    if [[ -f "${CONF_DIR}/config" ]]; then
        warn "Config exists — not overwriting: ${CONF_DIR}/config"
    else
        info "Creating config → ${CONF_DIR}/config"
        cat > "${CONF_DIR}/config" << 'CONF'
# ==========================================================================
# git-autopush configuration
# ==========================================================================

# Schedule — systemd OnCalendar format
# Examples: weekly, daily, hourly, *-*-* 03:00, Mon *-*-* 02:00
SCHEDULE="weekly"

# Log file path
LOG_FILE="/var/log/git-autopush/git-autopush.log"

# Commit message template
# Placeholders: {hostname}, {date}, {path}
COMMIT_MSG_TEMPLATE="auto-backup: {hostname} {date}"

# How to handle repos with uncommitted changes:
#   commit  — stage everything and commit (default, safest for backups)
#   skip    — leave dirty repos alone
DIRTY_POLICY="commit"

# Push retry settings
PUSH_RETRIES=3
PUSH_RETRY_DELAY=10

# SSH key for git push (leave empty to use default SSH config)
SSH_KEY=""
CONF
    fi

    # --- Repos list ---
    if [[ -f "${CONF_DIR}/repos.conf" ]]; then
        warn "Repos list exists — not overwriting: ${CONF_DIR}/repos.conf"
    else
        info "Creating repos list → ${CONF_DIR}/repos.conf"
        local first_repo
        first_repo=$(detect_first_repo)
        cat > "${CONF_DIR}/repos.conf" << REPOS
# ==========================================================================
# git-autopush — repository list
# ==========================================================================
# Format:  path | remote | branch
# Lines starting with # are ignored. Whitespace around | is trimmed.
#
# Examples:
#   /opt              | origin | main
#   /home/user/code   | origin | master
#   /srv/myapp        | backup | main
# --------------------------------------------------------------------------
REPOS
        if [[ -n "$first_repo" ]]; then
            echo "$first_repo" >> "${CONF_DIR}/repos.conf"
            info "Auto-detected repo: ${first_repo}"
        else
            echo "# /opt | origin | main" >> "${CONF_DIR}/repos.conf"
            warn "No repo detected at /opt — add repos to ${CONF_DIR}/repos.conf"
        fi
    fi
}

# ============================================================================
# 3. systemd service + timer
# ============================================================================
install_systemd() {
    info "Installing systemd units"

    # Read schedule from config if it exists, otherwise default
    local schedule="weekly"
    local SSH_KEY="${RUN_HOME}/.ssh/github_hw_raider"
    if [[ -f "${CONF_DIR}/config" ]]; then
        schedule=$(grep -oP '^\s*SCHEDULE\s*=\s*"\K[^"]+' "${CONF_DIR}/config" || echo "weekly")
    fi

    # --- Service ---
    cat > "${SYSTEMD_DIR}/git-autopush.service" << EOF
[Unit]
Description=git-autopush — automated git backup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/git-autopush.sh auto
User=${RUN_USER}
Group=${RUN_USER}
Nice=10
IOSchedulingClass=idle
# Give pushes time to complete
TimeoutStartSec=600
# Environment
Environment=HOME=${RUN_HOME}
Environment=GIT_TERMINAL_PROMPT=0
Environment="GIT_SSH_COMMAND=ssh -i ${SSH_KEY} -o StrictHostKeyChecking=accept-new"
RuntimeDirectory=git-autopush

[Install]
WantedBy=multi-user.target
EOF

    # --- Timer ---
    cat > "${SYSTEMD_DIR}/git-autopush.timer" << EOF
[Unit]
Description=git-autopush — scheduled backup timer

[Timer]
OnCalendar=${schedule}
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now git-autopush.timer 2>/dev/null
    info "Timer enabled: schedule=${schedule}"
}

# ============================================================================
# 4. Log directory + logrotate
# ============================================================================
install_logging() {
    mkdir -p "$LOG_DIR"
    chown "${RUN_USER}:${RUN_USER}" "$LOG_DIR" 2>/dev/null || true
    info "Log directory → ${LOG_DIR}"

    cat > "${LOGROTATE_DIR}/git-autopush" << 'LOGROTATE'
/var/log/git-autopush/*.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
LOGROTATE
    info "Logrotate config → ${LOGROTATE_DIR}/git-autopush"
}

# ============================================================================
# 5. Summary
# ============================================================================
show_summary() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  git-autopush installed successfully${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  Config:      ${CONF_DIR}/config"
    echo "  Repos:       ${CONF_DIR}/repos.conf"
    echo "  Script:      ${BIN_LINK}"
    echo "  Service:     ${SYSTEMD_DIR}/git-autopush.service"
    echo "  Timer:       ${SYSTEMD_DIR}/git-autopush.timer"
    echo "  Logs:        ${LOG_DIR}/git-autopush.log"
    echo "  Logrotate:   ${LOGROTATE_DIR}/git-autopush"
    echo ""
    echo "  Commands:"
    echo "    sudo git-autopush manual    Run now (interactive)"
    echo "    sudo git-autopush list      Show configured repos"
    echo "    systemctl status git-autopush.timer   Check schedule"
    echo "    journalctl -u git-autopush.service    View systemd logs"
    echo ""
    systemctl list-timers git-autopush.timer --no-pager 2>/dev/null || true
    echo ""
}

# ============================================================================
# Main
# ============================================================================
info "git-autopush installer starting on $(hostname)"
install_script
install_config
install_systemd
install_logging
show_summary
