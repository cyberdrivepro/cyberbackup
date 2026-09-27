# CyberVPS Backup Format Specification (Version 2)

This document describes the structure, metadata schema, and exclusion rules of CyberVPS backup archives.

---

## 1. Archive Naming & Compression

### Archive File Format
```
cybervps-backup-YYYYMMDD-HHMMSS.tar.zst
```
- **Primary Compression:** Tar with Zstandard (`zstd -3 -T0`) for high compression ratios and rapid extraction.
- **Fallback Compression:** Tar with Gzip (`.tar.gz`) if `zstd` is unavailable on the host.

### Separate Artifacts
- **Shared Data Archive (Optional):** `cybervps-shared-YYYYMMDD-HHMMSS.tar.zst`
- **Encrypted Secrets Archive (Optional):** `cybervps-secrets-YYYYMMDD-HHMMSS.enc`
- **Metadata Descriptor:** `latest.json`
- **Checksum Manifest:** `SHA256SUMS`

---

## 2. Metadata Schema (`latest.json`)

Each backup archive is accompanied by a machine-readable JSON descriptor:

```json
{
  "backup_file": "cybervps-backup-20260927-180000.tar.zst",
  "archive_path": "/home/alice/cyberbackup/downloads/cybervps-backup-20260927-180000.tar.zst",
  "creation_timestamp": "2026-09-27T18:00:00+00:00",
  "backup_format_version": 2,
  "cybervps_version": "1.0.0",
  "sha256": "4648bf2d16e6fafe27d3d4feee2104c32e934f0af73ac4f9db22d33b1c9dbff0",
  "size_bytes": 1048576,
  "source_user": "alice",
  "source_home": "/home/alice",
  "source_hostname": "vps-01",
  "architecture": "x86_64",
  "kernel": "Linux",
  "distro_id": "debian",
  "distro_pretty": "Debian GNU/Linux 12 (bookworm)",
  "libc": "glibc",
  "shared_included": 0,
  "secrets_encrypted": 0
}
```

---

## 3. Inclusion & Exclusion Rules

### Included in Primary Snapshot
- `$HOME/bin`: User-space scripts and custom wrappers
- `$HOME/config`: Application and service configurations (Nginx, Redis, Supervisor, shell profiles)
- `$HOME/services`: Service lifecycle management scripts
- `$HOME/projects`: User application source code and manifest definitions
- `$HOME/examples`: Example and reference projects
- `$HOME/.pm2/dump.pm2`: PM2 saved process ecosystem state
- `$HOME/.config/cybervps`: Port reservations and settings
- Backup staging manifests (`system.json`, `micromamba-env.yml`, `pip-freeze.txt`, etc.)

### Strictly Excluded Patterns
To maintain portability, efficiency, and security, the following patterns are excluded:
- **Reproducible Build & Package Caches:** `node_modules`, `.cache`, `.npm`, `.pnpm-store`, `__pycache__`, `*.pyc`, `dist`, `build`, `target/`, `pkgs/`
- **Transient State & Sockets:** `*.pid`, `*.sock`, `*.lock`, `pm2.pid`, `rpc.sock`, `pub.sock`, `daemon.json`, `dump.rdb`, `appendonly.aof`, `client_body_temp/`, `logs/*`
- **Plaintext Secrets & Keys:** `.env`, `.env.*`, `remote.conf`, `rclone.conf`, `id_rsa*`, `id_ed25519*`, `*.key`, `*.pem`, `credentials*`
- **Large External Volumes:** `~/shared` (handled via separate dedicated archive upon request)
