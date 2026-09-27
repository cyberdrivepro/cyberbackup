# CyberVPS Backup & Recovery

A portable disaster-recovery kit for a restricted user-space hosting VPS environment.
Designed to survive a home-directory wipe: clone the repo, run `bash cybervps.sh`,
and choose restore or fresh rebuild.

This repository intentionally contains **no secrets** and **no large backup archives**.
Secrets and large snapshots belong in external storage (rclone remote, Drive, object storage, etc.).

## Quick reference

### Normal backup

```bash
cd ~/cyberbackup
./backup-now.sh
```

This creates a versioned backup archive, `latest.json`, and `SHA256SUMS`.

### Upload backup to remote storage

```bash
./upload-backup.sh
```

`upload-backup.sh` uses `rclone` and the configured remote in `remote.conf`.
It uploads the latest snapshot, `latest.json`, and `SHA256SUMS`.

### Complete disaster recovery

```bash
git clone <YOUR_RECOVERY_REPO> cyberbackup
cd cyberbackup
bash cybervps.sh
```

Then choose:

1. **Restore from CyberBackup** — download/verify/extract a backup archive and
   restore the user-space hosting environment.
2. **Fresh Install / Rebuild** — rebuild the user-space hosting environment from
   manifests and templates, starting from nearly nothing.

After either option, confirm with:

```bash
hosting-status
vps-status
~/services/healthcheck.sh
```

## Design principles

- **Snapshot + manifests.** Backups contain a fast-restore snapshot and reproducible
  manifests. If a copied environment is incompatible on another host, `Option 2`
  can rebuild from manifests.
- **User-space only.** No `sudo`, no `apt install`, no `PRoot`, no Docker/Podman,
  no systemd, no GUI.
- **Secrets never in Git.** `.env`, tokens, SSH private keys, Cloudflare credentials,
  database passwords, and rclone credentials are excluded by default.
- **Large archives live externally.** Backup archives are stored in rclone remotes
  or similar external storage, not in Git history.
- **Idempotent.** Every script can be run multiple times safely.
- **Safe restore.** Before overwriting, existing important config is backed up into
  a timestamped `pre-restore-*` directory.
- **Integrity first.** Restore verifies SHA256 before extracting and stops if the
  checksum fails.

## Directory layout

```
cyberbackup/
├── cybervps.sh          # main entry script (menu)
├── backup-now.sh        # create a versioned backup
├── restore.sh           # restore from backup archive
├── fresh-install.sh     # fresh user-space rebuild
├── verify.sh            # verify current environment health
├── upload-backup.sh     # upload latest backup to remote
├── download-backup.sh   # download backup from remote
├── VERSION              # backup format version
├── remote.example.conf  # example rclone remote config template
├── .gitignore
├── README.md
├── manifests/
│   ├── system.txt
│   ├── files.txt
│   ├── sha256sums.txt
│   ├── micromamba-env.yml
│   ├── micromamba-explicit.txt
│   ├── micromamba-list.txt
│   ├── pip-freeze.txt
│   ├── npm-global.txt
│   ├── node-version.txt
│   ├── rust-version.txt
│   ├── cargo-installed.txt
│   ├── go-version.txt
│   ├── go-env.txt
│   ├── ports.txt
│   └── services.txt
├── config/
├── scripts/
├── templates/
├── payload/
├── downloads/
└── logs/
```

## Remote configuration

Copy `remote.example.conf` to `remote.conf` and fill in your real values.
**Do not commit `remote.conf` if it contains real credentials.**

Example:

```ini
CYBERBACKUP_REMOTE="myremote:CyberVPSBackup"
# CYBERBACKUP_URL=""
# CYBERBACKUP_LOCAL=""
```

## Secrets

The system can optionally encrypt secrets using `openssl` AES-256 with PBKDF2.
Encryption password is prompted interactively and never echoed.

Secrets are excluded from the normal backup by default. Use the optional encrypted
secrets backup path for sensitive material.

## Shared storage

`$HOME/shared` can be large. It is **not** included in the main system backup by
default. Use `--include-shared` or `CYBERBACKUP_INCLUDE_SHARED=1` to include it as
a separate archive.

## Supported recovery sources

- Local file
- Mounted/shared directory
- rclone remote
- HTTPS download URL

## Current environment assumptions

- Linux x86_64
- User: `srhfqtos`
- Home: `/home/srhfqtos`
- Micromamba root: `$HOME/apps/micromamba`
- Hosting environment name: `hosting`
- Python 3.12
- Node.js 22
- Redis user instance on 127.0.0.1:6380
- nginx on 127.0.0.1:8080
- Supervisor via `svcd-h24` / `h24ctl`
- PM2 home: `$HOME/.pm2`
- tmux session: `hosting24`
- Cloudflared helper: `cloudflare-quick-tunnel.sh PORT`

## Verification

Run `verify.sh` after restore or rebuild to check the health of the environment:

- micromamba
- hosting environment
- Python
- pip
- Node/npm/pnpm/PM2
- Rust/Cargo
- Go
- Git
- SQLite
- Redis user service
- nginx
- Supervisor
- cloudflared
- tmux hosting24
- scheduler
- healthcheck

## Disaster simulation (safe)

Do not delete your real setup to test. Instead use the validation path that checks
whether the backup contains enough information for restoration and verifies every
critical file referenced by `restore.sh` exists.

## Recovery flow reminder

```bash
git clone <repo> cyberbackup
cd cyberbackup
bash cybervps.sh
```

Option 1: **RESTORE EXISTING CYBERBACKUP**

Option 2: **FRESH USER-SPACE REBUILD**
