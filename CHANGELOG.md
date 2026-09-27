# Changelog

All notable changes to the CyberVPS project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-09-27

### Added
- **Archive Security Validation Engine (`lib/archive.sh`):**
  - Scans archive table of contents prior to extraction.
  - Rejects path traversal (`..`), leading slashes (`/`), absolute paths, and character/block device nodes.
  - Validates symlink targets to prevent escaping extraction sandboxes or pointing to system roots.
  - Safe extraction with `--no-same-owner` and `--delay-directory-restore`.
- **Dedicated User-Space Locking Engine (`lib/lock.sh`):**
  - Portable flock locking with atomic directory fallback.
  - Stale PID detection to automatically clear locks held by defunct processes.
  - Safe command execution wrapper (`with_lock`).
- **Architecture and Libc Compatibility Validator (`lib/architecture.sh`):**
  - Machine architecture normalization (`x86_64`, `aarch64`, `armv7l`, `x86`, `riscv64`, `s390x`, `ppc64le`).
  - C standard library implementation and version detection (`glibc` vs `musl`).
  - Binary compatibility validator flagging rebuild requirements on cross-architecture or cross-libc restores.
- **Modular Standalone Installers (`installers/`):**
  - `installers/micromamba.sh`: Standalone Micromamba installer.
  - `installers/python.sh`: User-space Python environment and pip setup.
  - `installers/node.sh`: Official Node.js binary installer with user-space PM2.
  - `installers/rust.sh`: Rootless Rustup and Cargo installer.
  - `installers/go.sh`: Official Go toolchain installer.
  - `installers/redis.sh`: Rootless Redis configurator binding strictly `127.0.0.1`.
  - `installers/nginx.sh`: Rootless Nginx configurator with user-space temp directories and non-privileged ports.
  - `installers/cloudflared.sh`: Official Cloudflared tunnel installer.
- **Stack Installation Profiles:**
  - Added support for `minimal`, `hosting`, `developer`, and `full` profiles in `lib/install.sh` and `fresh-install.sh --profile <name>`.
- **System Diagnostics TUI:**
  - Added Option `[10] Diagnostics & System Inspector` to interactive menu `cybervps.sh` displaying host profile, candidate process backends, allocated ports, and recent operational logs.
- **Expanded Test Suite (11/11 Passing):**
  - `tests/test-archive-security.sh`: 11-point security assertion verifying path traversal, absolute path, and malicious symlink rejection.
  - `tests/test-relative-backup.sh`: Verifies archive contains strictly relative paths without absolute home directories.
  - `tests/test-restore-e2e.sh`: End-to-end backup, archive security check, staging extraction, and configuration path translation cycle.

### Changed
- **Relative Archive Layout:**
  - Refactored `lib/backup.sh` to package files relative to `$HOME` using multiple `-C` tar directives, completely removing `--absolute-names`.
  - Updated `lib/restore.sh` to seamlessly unpack and map relative archive contents into destination home directories, while maintaining backward compatibility with legacy snapshots.
- Hardened exit handlers in `lib/restore.sh` to clean staging sandboxes explicitly without overriding parent process traps under `set -u`.

### Security
- Added active pre-extraction archive verification to protect rootless VPS accounts from malicious or corrupted archive extraction exploits.
- Ensured zero credentials, private keys, or API tokens committed to repository or stored in unencrypted archives.
