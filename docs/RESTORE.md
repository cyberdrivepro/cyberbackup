# CyberVPS Restore & Disaster Recovery Guide

This guide details how to restore a CyberVPS backup on an existing or newly provisioned non-root Linux VPS.

---

## 1. Quick Disaster Recovery Flow

After acquiring access to a fresh VPS account:
```bash
git clone https://github.com/cyberdrivepro/cyberbackup.git
cd cyberbackup
bash cybervps.sh
```
Select **[1] Restore Backup to This VPS** or run CLI directly:
```bash
bash ./restore.sh --archive downloads/cybervps-backup-YYYYMMDD-HHMMSS.tar.zst
```

---

## 2. Restore Lifecycle Phases

```
[Archive Discovery]
        |
[SHA256 & Tar Integrity Verification]
        |
[Pre-Restore Safety Snapshot] -> ($HOME/backups/pre-restore-TIMESTAMP/)
        |
[Extraction to Staging Sandbox] -> ($HOME/cyberbackup/payload/staging-PID/)
        |
[Metadata & Platform Compatibility Comparison]
        |
[Restore Portable Configs, Services & Projects]
        |
[Managed Path Translation (SOURCE_HOME -> DEST_HOME)]
        |
[Dynamic Port Allocation & Reservation Update]
        |
[Install CLI Helpers & Configure Login Recovery]
        |
[Run Verification Suite]
```

---

## 3. Rollback & Pre-Restore Snapshot

Before modifying any existing files, `restore.sh` automatically copies existing configurations and user scripts into:
```
$HOME/backups/pre-restore-YYYYMMDD-HHMMSS/
```
If an unexpected error occurs during restore:
- The failure log is preserved in `$HOME/.local/state/cybervps/logs/cybervps.log`.
- Pre-restore configurations remain intact in the safety snapshot directory and can be manually inspected or restored.

---

## 4. Path Translation Mechanics

When restoring onto a host with a different username or home directory (e.g. source was `/home/alice` and destination is `/home/bob`):
- CyberVPS inspects extracted manifests to identify `SOURCE_HOME`.
- Path translation is performed **strictly** on known managed configuration files:
  - `$HOME/config/nginx/*.conf`
  - `$HOME/config/redis.conf`
  - `$HOME/config/svcd-h24.conf`
  - `$HOME/services/*.sh`
- User project source code is **never subjected to naive global string substitution**, ensuring that variable names, comments, and application code are never corrupted.

---

## 5. Port Collision Handling

If a requested port (e.g. Nginx on `8080` or Redis on `6380`) is already bound by another user or system service on the destination machine:
- The dynamic port manager scans for the next available unprivileged localhost port (>= 1024).
- The newly allocated port is updated in `$HOME/.config/cybervps/ports.env` and referenced in service configurations.
