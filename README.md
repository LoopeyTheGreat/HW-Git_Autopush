# git-autopush

Automated git add, commit, and push for managed repositories — designed for backing up service configurations across servers.

## Install

```bash
sudo bash /opt/git-autopush/install.sh
```

Re-runnable — updates the script and systemd units without overwriting your config or repos list.

### Requirements

- Linux with systemd
- git
- SSH key with push access to your remotes

## What Gets Installed

| Component | Path |
|-----------|------|
| Execution script | `/usr/local/bin/git-autopush` |
| Script source | `/usr/local/lib/git-autopush/git-autopush.sh` |
| Config | `/etc/git-autopush/config` |
| Repos list | `/etc/git-autopush/repos.conf` |
| systemd service | `/etc/systemd/system/git-autopush.service` |
| systemd timer | `/etc/systemd/system/git-autopush.timer` |
| Log file | `/var/log/git-autopush/git-autopush.log` |
| Logrotate | `/etc/logrotate.d/git-autopush` |

## Usage

```bash
sudo git-autopush manual          # Run immediately
sudo git-autopush list            # Show configured repos and their status
sudo git-autopush auto            # What the timer calls (same as manual, different log label)
```

### Check the timer

```bash
systemctl status git-autopush.timer
systemctl list-timers git-autopush.timer
```

### View logs

```bash
# Application log
cat /var/log/git-autopush/git-autopush.log

# systemd journal
journalctl -u git-autopush.service
```

## Configuration

### `/etc/git-autopush/config`

```bash
# Schedule — systemd OnCalendar format
# Examples: weekly, daily, hourly, *-*-* 03:00, Mon *-*-* 02:00
SCHEDULE="weekly"

# Log file path
LOG_FILE="/var/log/git-autopush/git-autopush.log"

# Commit message template
# Placeholders: {hostname}, {date}, {path}
COMMIT_MSG_TEMPLATE="auto-backup: {hostname} {date}"

# How to handle repos with uncommitted changes:
#   commit — stage everything and commit (default, safest for backups)
#   skip   — leave dirty repos alone
DIRTY_POLICY="commit"

# Push retry settings
PUSH_RETRIES=3
PUSH_RETRY_DELAY=10

# SSH key for git push (leave empty to use default SSH config)
SSH_KEY="/home/loopey/.ssh/github_hw_raider"
```

After changing `SCHEDULE`, re-run the installer to update the systemd timer:

```bash
sudo bash /opt/git-autopush/install.sh
```

### `/etc/git-autopush/repos.conf`

One repo per line, pipe-delimited:

```
# path | remote | branch
/opt              | origin | main
/srv/another-app  | origin | master
/home/user/dotfiles | backup | main
```

The installer auto-detects `/opt/.git` and adds it on first run.

## Dirty Repo Handling

| Policy | Behavior |
|--------|----------|
| `commit` | Stages all changes with `git add -A`, commits with the configured message template, then pushes. This is the default and safest option for backup purposes. |
| `skip` | Leaves the repo untouched if there are uncommitted changes. Useful if you want manual control over commits. |

## How It Works

1. Acquires a lock file (`/run/git-autopush/git-autopush.lock`) to prevent overlapping runs
2. Reads repos from `/etc/git-autopush/repos.conf`
3. For each repo:
   - Validates it's a git repo with the expected remote
   - Checks for dirty working tree, applies `DIRTY_POLICY`
   - Counts commits ahead of remote
   - Pushes with retry logic
4. Logs everything to the log file and stdout/journal

## Log Rotation

Handled by logrotate — weekly rotation, 12 weeks retained, compressed with delayed compression.

## Deploying to Another Server

1. Copy the installer: `scp /opt/git-autopush/install.sh user@server:/tmp/`
2. On the new server, set up your git repo(s) and SSH keys
3. Run: `sudo bash /tmp/install.sh`
4. Edit `/etc/git-autopush/repos.conf` to list the repos on that server
5. Update `SSH_KEY` in `/etc/git-autopush/config` if needed
