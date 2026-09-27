# CyberVPS

[![CyberVPS Validation CI](https://github.com/cyberdrivepro/cyberbackup/actions/workflows/validate.yml/badge.svg)](https://github.com/cyberdrivepro/cyberbackup/actions/workflows/validate.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Format: v2](https://img.shields.io/badge/Backup%20Format-v2-success.svg)](docs/BACKUP_FORMAT.md)

**Portable Non-Root Linux VPS Hosting, Backup, Migration, Disaster Recovery, and Fresh Rebuild Toolkit.**

CyberVPS empowers developers and sysadmins to deploy, persist, backup, migrate, and rebuild complete user-space application environments on **ordinary, unprivileged non-root Linux VPS accounts** without requiring `sudo`, root privileges, Docker, or host package manager modifications.

---

## ⚡ Quick Start

```bash
git clone https://github.com/cyberdrivepro/cyberbackup.git
cd cyberbackup
bash cybervps.sh
```

Upon launch, CyberVPS inspects the host and renders a polished interactive menu:

```
╔══════════════════════════════════════════════════════╗
║                       CyberVPS                       ║
║        Portable Non-Root Linux Recovery Toolkit      ║
╚══════════════════════════════════════════════════════╝
Detected Profile:
  Host: vps-01 | User: alice | Arch: x86_64
  Home: /home/alice
  OS:   Debian GNU/Linux 12 (bookworm) (glibc 2.36)
--------------------------------------------------------
  [1] Restore Backup to This VPS
  [2] Fresh Install / Rebuild
  [3] Migrate Backup From Another VPS
  [4] Create Backup
  [5] Upload Backup
  [6] Download Backup
  [7] Verify Current VPS
  [8] CyberVPS Status
  [9] Configuration
  [0] Exit
--------------------------------------------------------
```

---

## 🌟 Key Capabilities

1. **Zero Root / Sudo Required:** Runs completely inside user-space. Zero `sudo`, `su`, `apt`, `dnf`, or root daemon modifications.
2. **Disaster Recovery:** Rebuilds entire runtime environments (Python, Node, Go, Rust, PM2, Cloudflared) after near-total `$HOME` loss.
3. **Cross-VPS Migration:** Intelligently migrates configurations across VPS providers, translating paths (`/home/userA` to `/home/userB`) and reallocating conflicting ports.
4. **Dynamic Port Allocator:** Discovers free unprivileged localhost ports (`>= 1024`), ensuring zero collisions on multi-user VPS hosts.
5. **Localhost-Only Security:** All internal listeners (Redis, Nginx, APIs, supervisor) bind strictly to `127.0.0.1` by default.
6. **Multi-Backend Process Persistence:** Automatically selects the best persistence backend available (`systemd --user`, `tmux`, `screen`, or `nohup` + PID tracking).
7. **Login-Triggered Recovery:** Idempotent shell startup integration restores services automatically upon SSH login without claiming true boot autostart.
8. **Automated Secret Filtering:** Automated scanner verifies that no credentials, tokens, or private keys are committed or exported in plaintext.
9. **Optional Encrypted Secrets:** Encrypts sensitive credentials via OpenSSL AES-256 with PBKDF2 using an interactive passphrase.

---

## 📁 Repository Architecture

```
cyberbackup/
├── cybervps.sh           # Master interactive terminal interface
├── backup-now.sh         # CLI entry point for creating snapshots
├── restore.sh            # CLI entry point for restoring backups
├── migrate.sh            # CLI entry point for cross-host migration
├── fresh-install.sh      # CLI entry point for zero-state rebuilds
├── verify.sh             # System health & compatibility verifier
├── upload-backup.sh      # Remote storage upload helper
├── download-backup.sh    # Remote storage download helper
├── VERSION               # Current CyberVPS version
├── LICENSE               # MIT License
├── README.md             # Project documentation
├── CHANGELOG.md          # Release history
├── SECURITY.md           # Security policy and credential handling
├── CONTRIBUTING.md       # Development and contribution guide
├── remote.example.conf   # Template for remote storage providers
├── lib/
│   ├── common.sh         # Locks, constrained env parser, download helpers
│   ├── logging.sh        # Structured logging with severity levels
│   ├── detect.sh         # Identity, architecture, libc, and hardware detection
│   ├── ports.sh          # Dynamic rootless port allocator
│   ├── install.sh        # User-space dependency installer engine
│   ├── services.sh       # Process backend abstraction & CLI helpers
│   ├── backup.sh         # Format v2 backup engine & manifest generation
│   ├── restore.sh        # Safe restore engine & rollback management
│   ├── migration.sh      # Cross-VPS comparison and path translation
│   ├── verify.sh         # Categorized verification engine (supports --json)
│   └── remote.sh         # Rclone and remote storage synchronization
├── tests/                # Automated test suite
│   ├── test-detect.sh
│   ├── test-ports.sh
│   ├── test-config.sh
│   ├── test-idempotency.sh
│   ├── test-backup-layout.sh
│   ├── test-migration-paths.sh
│   ├── test-menu.sh
│   ├── test-secret-filter.sh
│   └── run-tests.sh      # Test suite runner
└── docs/                 # Detailed technical specifications
    ├── STATUS.md
    ├── ARCHITECTURE.md
    ├── BACKUP_FORMAT.md
    ├── RESTORE.md
    ├── MIGRATION.md
    ├── SERVICE_BACKENDS.md
    └── TROUBLESHOOTING.md
```

---

## 💻 CLI Usage

All tasks can be executed non-interactively or in automated scripts:

### Create a Portable Backup
```bash
bash ./backup-now.sh [options]

# Options:
#   --include-shared     Include ~/shared in a separate archive
#   --encrypt-secrets    Create an encrypted archive of secrets using OpenSSL
#   --dry-run            Simulate backup without creating archive
#   --verbose            Enable debug logging
```

### Restore a Backup
```bash
bash ./restore.sh --archive downloads/cybervps-backup-YYYYMMDD-HHMMSS.tar.zst
# Supports --dry-run and --force-rebuild
```

### Migrate Backup From Another VPS
```bash
bash ./migrate.sh --archive downloads/cybervps-backup-YYYYMMDD-HHMMSS.tar.zst
```

### Fresh Rebuild from Zero
```bash
bash ./fresh-install.sh
```

### Health Verification
```bash
bash ./verify.sh
# Machine-readable JSON output:
bash ./verify.sh --json
```

---

## 🔒 Security Principles

- **Zero Root Privilege Escalation:** CyberVPS never runs `sudo` or modifies system directories.
- **Provider Compliance:** CyberVPS does **not** disguise process names or implement watchdog bypasses. If a provider policy prohibits a component, it disables it and logs a clear notice.
- **Localhost Default:** Network services bind strictly to `127.0.0.1`.
- **Integrity Verification:** Every snapshot generates SHA256 checksums in `SHA256SUMS` and `latest.json`.
- **Secret Scanning:** Run `bash ./scripts/secret-check.sh` at any time to verify repository safety.

---

## 🧪 Testing

CyberVPS includes an automated, non-destructive test suite that runs in temporary sandboxes:

```bash
bash ./tests/run-tests.sh
```

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
