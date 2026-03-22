# git-autopush

Automated git add, commit, and push for managed repositories — with automatic sub-repo discovery. Designed for backing up service configurations across servers.

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
sudo git-autopush list            # Show configured repos with parent/child relationships
sudo git-autopush discover        # Scan for sub-repos and add them
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
SCHEDULE="weekly"

# Log file path
LOG_FILE="/var/log/git-autopush/git-autopush.log"

# Commit message template — placeholders: {hostname}, {date}, {path}
COMMIT_MSG_TEMPLATE="auto-backup: {hostname} {date}"

# How to handle repos with uncommitted changes: commit | skip
DIRTY_POLICY="commit"

# Push retry settings
PUSH_RETRIES=3
PUSH_RETRY_DELAY=10

# SSH key for git push (leave empty to use default SSH config)
SSH_KEY="/home/loopey/.ssh/github_hw_raider"

# Auto-discover nested git repos under configured parent paths
AUTO_DISCOVER="true"

# Max directory depth to scan for nested repos
DISCOVER_DEPTH=3
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

# auto-discovered 2026-03-22
/opt/git-autopush | origin | main
```

The installer auto-detects `/opt/.git` on first run. Sub-repos are added automatically when `AUTO_DISCOVER="true"`.

## Sub-Repo Discovery

git-autopush automatically detects nested git repositories inside configured parent repos.

### How it works

1. On each run (or via `discover`), scans configured parent repo paths for nested `.git` directories
2. For each child repo found with a remote and branch:
   - Adds it to `repos.conf` (with `# auto-discovered` comment)
   - Updates the parent's `.gitignore` to exclude the child directory
3. Processing order is **children first, parents last** — child repos get committed/pushed before the parent sees them as clean

### Example

Given this structure:
```
/opt/                  ← parent repo (origin → HW-Raider_Opt)
├── git-autopush/      ← child repo (origin → HW-Git_Autopush)
├── jellyfin/
└── adguardhome/
```

Running `sudo git-autopush manual` will:
1. Discover `/opt/git-autopush` as a child of `/opt`
2. Add `git-autopush/` to `/opt/.gitignore`
3. Commit and push `/opt/git-autopush` first
4. Then commit and push `/opt` (which now only tracks its own files)

### Manual discovery

```bash
sudo git-autopush discover
```

Output:
```
=== Discovery scan ===
  DISCOVERED: /opt/git-autopush|origin|main (added to repos.conf, parent .gitignore updated)
  Discovery: 1 sub-repo(s) found, 1 new added

Current repos:
  /opt                            origin/main  [OK]
  /opt/git-autopush               origin/main  [OK] (child of /opt)
```

### Disabling

Set `AUTO_DISCOVER="false"` in `/etc/git-autopush/config` to manage repos manually.

## Dirty Repo Handling

| Policy | Behavior |
|--------|----------|
| `commit` | Stages all changes with `git add -A`, commits with the configured message template, then pushes. Default and safest for backups. |
| `skip` | Leaves the repo untouched if there are uncommitted changes. |

## Deploying to Another Server

1. Copy the installer: `scp /opt/git-autopush/install.sh user@server:/tmp/`
2. On the new server, set up your git repo(s) and SSH keys
3. Run: `sudo bash /tmp/install.sh`
4. Edit `/etc/git-autopush/repos.conf` to list the repos on that server
5. Update `SSH_KEY` in `/etc/git-autopush/config`
6. Any nested repos will be auto-discovered on the first run
