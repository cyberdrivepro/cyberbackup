# CyberVPS Architecture Specification

CyberVPS is engineered as a modular, rootless toolkit for Linux VPS management, disaster recovery, and cross-host migration. This document details its technical architecture, design patterns, and operational flow.

---

## 1. High-Level Architecture Overview

```
                      +-----------------------------+
                      |   cybervps.sh (Menu UI)     |
                      +--------------+--------------+
                                     |
    +---------------+----------------+----------------+---------------+
    |               |                |                |               |
[backup-now.sh] [restore.sh]    [migrate.sh]  [fresh-install.sh]  [verify.sh]
    |               |                |                |               |
    +---------------+----------------+----------------+---------------+
                                     |
                                 lib/ Layer
    +-----------------------------------------------------------------+
    | lib/common.sh   : Locking, constrained env parser, file helpers  |
    | lib/logging.sh  : Structured logging, levels, persistent logfile|
    | lib/detect.sh   : Identity, arch normalization, libc, hardware  |
    | lib/ports.sh    : Dynamic rootless port allocator (localhost)   |
    | lib/install.sh  : Priority-based user-space installer engine    |
    | lib/services.sh : Process backends (tmux, screen, nohup) & CLI  |
    | lib/backup.sh   : Format v2 backup engine & manifest generation |
    | lib/restore.sh  : Safe restore engine, rollback snapshots       |
    | lib/migration.sh: Cross-VPS comparison and path translation     |
    | lib/verify.sh   : Multi-category health verification engine     |
    | lib/remote.sh   : Rclone / mounted storage synchronization      |
    +-----------------------------------------------------------------+
```

---

## 2. Core Subsystems

### A. Environment & Architecture Detection (`lib/detect.sh`)
- Identifies runtime identity without static configuration:
  - `CYBER_USER="$(id -un)"`
  - `CYBER_HOME="${HOME}"`
  - `CYBER_HOSTNAME="$(hostname)"`
- Normalizes system architectures:
  - `x86_64` / `amd64` -> `linux-64` (Micromamba), `linux-amd64` (Go), `amd64` (Cloudflared)
  - `aarch64` / `arm64` -> `linux-aarch64` (Micromamba), `linux-arm64` (Go), `arm64` (Cloudflared)
- Identifies C library (`glibc` vs `musl`) and releases.

### B. Dynamic Port Allocator (`lib/ports.sh`)
- Multiple users on shared VPS hosts may occupy standard ports.
- Never binds privileged ports (< 1024).
- Tests port availability using `ss`, `netstat`, `/dev/tcp`, or Python socket probes.
- Defaults strictly to localhost `127.0.0.1`.
- Persists allocated ports idempotently in `$HOME/.config/cybervps/ports.env`.

### C. Service Backend Abstraction (`lib/services.sh`)
- Provides a unified interface: `start`, `stop`, `restart`, `status`, `logs`.
- Supports multiple persistence mechanisms based on availability:
  1. `systemd --user` (if user systemd socket is enabled by provider)
  2. `tmux` (preferred user-space terminal multiplexer)
  3. `screen` (alternative multiplexer)
  4. `nohup` + PID tracking in `$HOME/run/*.pid` (universal fallback)
- Implements login-triggered recovery using marked blocks in shell startup files (`~/.bashrc`, `~/.profile`).

### D. Backup & Manifest Generation (`lib/backup.sh`)
- Dynamic generation of system specifications and runtime manifests:
  - `system.json`: Machine-readable host profile
  - `micromamba-env.yml` / `micromamba-explicit.txt`: Exact Conda package locks
  - `python-version.txt`, `pip-freeze.txt`: Python package state
  - `node-version.txt`, `npm-global.json`: Node runtime state
  - `projects.json`: Metadata of user applications in `~/projects`
- File exclusion rules strictly eliminate non-portable caches (`node_modules`, `__pycache__`, `target/`), transient sockets, and secrets.

### E. Safe Restore & Migration (`lib/restore.sh`, `lib/migration.sh`)
- Pre-restore safety snapshot in `$HOME/backups/pre-restore-TIMESTAMP/`.
- Safe extraction into isolated staging sandbox.
- Targeted path translation: transforms `SOURCE_HOME` into `DEST_HOME` across managed configuration files, strictly avoiding global string replacement on user source code.
- Port reallocation: checks port availability on destination host and updates configurations dynamically.

---

## 3. Reliability & Idempotency Principles
- **Atomic File Writes:** Generated configs and metadata are written to temporary files before being moved into place.
- **Flock & Directory Locks:** Prevents concurrent backup, restore, or migration operations.
- **Marked Blocks:** Shell initialization modifications use unique delimiters `# >>> CYBERVPS <TAG> >>>` to ensure repeated invocations never generate duplicate entries.
