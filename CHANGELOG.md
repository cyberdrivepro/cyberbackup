# Changelog

All notable changes to the CyberVPS project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0-dev] - 2026-09-27

### Added
- Portable modular architecture under `lib/` directory:
  - `lib/logging.sh`: Centralized logging with severity levels (DEBUG, INFO, WARN, ERROR), persistent file logs, and output stream separation.
  - `lib/common.sh`: Common utility functions including flock and directory-based user-space locking, safe KEY=VALUE config parser without eval, download helper with SHA256 checksum validation, and idempotent marked-block manager for shell profiles.
  - `lib/detect.sh`: Environment and architecture detection with zero hardcoded identities. Dynamically discovers user, home, architecture (with x86_64, aarch64 normalization), kernel, OS/distro (/etc/os-release), libc (glibc/musl), and resource limits.
  - `lib/ports.sh`: Dynamic rootless TCP port allocator ensuring collision-free port assignments on multi-user VPS hosts, constrained to localhost (`127.0.0.1`).
  - `lib/install.sh`: User-space dependency installer engine supporting Micromamba, Python tools, Node/PM2, Go, Rust, and Cloudflared with architecture mapping and HTTPS downloads.
  - `lib/services.sh`: Process backend abstraction supporting systemd --user, tmux, screen, and nohup+PID tracking with unified commands (`cybervps-*`), login-triggered recovery manager, and provider restriction safety.
  - `lib/backup.sh`: Portable backup engine with format version 2, dynamic manifest capture, separate shared data archive handling, optional AES-256 encrypted secrets, integrity self-checks, and machine-readable `latest.json` generation.
  - `lib/restore.sh`: Safe restore engine with pre-restore safety snapshots, dry-run simulation, staging validation, selective path translation for managed configuration files, and automatic port conflict adaptation.
  - `lib/migration.sh`: Cross-host migration engine comparing source vs destination architecture, OS, libc, and user paths, rebuilding native environments when platform differences are detected.
  - `lib/verify.sh`: Comprehensive health verification engine inspecting environment, runtimes, persistence, ports, cache, and resources with colored terminal report and `--json` support.
  - `lib/remote.sh`: Remote storage abstraction supporting rclone, mounted filesystem paths, and HTTPS download sources, with upload validation and safe retention policies.
  - `migrate.sh`: CLI entry point for migrating backup archives across VPS instances.
  - `fresh-install.sh`: Rootless rebuild from zero orchestrating directory setup, Micromamba/hosting environment, Cloudflared, ports, CLI helpers, and login recovery.
  - `cybervps.sh`: Interactive terminal menu interface supporting 9 operations with Unicode frames and ASCII fallback.
- Automated test framework under `tests/` with `run-tests.sh` runner and unit tests:
  - `tests/test-detect.sh`: Validates identity and architecture detection logic.
  - `tests/test-ports.sh`: Tests port scanning, free port discovery, and reservation idempotency.
  - `tests/test-config.sh`: Tests safe config parsing, user-space locking, and marked-block manipulation.
  - `tests/test-idempotency.sh`: Verifies idempotency of login recovery blocks, CLI helper creation, and process backend detection.
  - `tests/test-backup-layout.sh`: Tests snapshot creation, JSON metadata generation, SHA256SUMS integrity, and cache/socket exclusion rules.
  - `tests/test-migration-paths.sh`: Tests safe path translation on managed configuration files while preserving unrelated contents.
  - `tests/test-menu.sh`: Validates non-interactive menu execution and options rendering.
  - `tests/test-secret-filter.sh`: Validates detection of sensitive pattern leaks.
- Security scanner:
  - `scripts/secret-check.sh`: Automated pre-commit/pre-push scanner checking for credentials, API tokens, private keys, and forbidden backup archives without leaking secret values.
- Continuous Integration:
  - `.github/workflows/validate.yml`: Lightweight GitHub Actions workflow validating bash syntax with `bash -n`, running secret detection, and executing unit tests.
- Comprehensive Documentation Suite:
  - `README.md`: Complete guide covering architecture, quickstart, menu options, CLI commands, security, and portability.
  - `docs/ARCHITECTURE.md`: Technical specification covering modular layers, lifecycle, and design principles.
  - `docs/BACKUP_FORMAT.md`: Format version 2 specification, JSON schema, and exclusions.
  - `docs/RESTORE.md`: Disaster recovery walkthrough, safety snapshots, and path translation.
  - `docs/MIGRATION.md`: Cross-VPS migration guide.
  - `docs/SERVICE_BACKENDS.md`: Process persistence and provider compliance details.
  - `docs/TROUBLESHOOTING.md`: Common operational issues and solutions.
  - `SECURITY.md`, `CONTRIBUTING.md`, `LICENSE` (MIT).
  - `docs/STATUS.md`: Live tracking of project milestones, test matrix, and limitations.

### Changed
- Standardized `.gitignore` to prevent any staging of backup archives, log files, sockets, PIDs, or environment secrets.
- Re-architected output streams in logging library to prevent log messages from interfering with shell function return values.

### Security
- Excluded plaintext secrets, private SSH keys, cloud credentials, and sensitive configurations from Git tracking and default backups.
- Config parser hardened to strictly reject arbitrary executable code and restrict imported variables to authorized namespaces.
