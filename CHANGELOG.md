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
- Automated test framework under `tests/` with `run-tests.sh` runner and unit tests:
  - `tests/test-detect.sh`: Validates identity and architecture detection logic.
  - `tests/test-ports.sh`: Tests port scanning, free port discovery, and reservation idempotency.
  - `tests/test-config.sh`: Tests safe config parsing, user-space locking, and marked-block manipulation.
- Security scanner:
  - `scripts/secret-check.sh`: Automated pre-commit/pre-push scanner checking for credentials, API tokens, private keys, and forbidden backup archives without leaking secret values.
- Documentation tracking:
  - `docs/STATUS.md`: Live tracking of project milestones, test matrix, and limitations.

### Changed
- Standardized `.gitignore` to prevent any staging of backup archives, log files, sockets, PIDs, or environment secrets.
- Re-architected output streams in logging library to prevent log messages from interfering with shell function return values.

### Security
- Excluded plaintext secrets, private SSH keys, cloud credentials, and sensitive configurations from Git tracking and default backups.
- Config parser hardened to strictly reject arbitrary executable code and restrict imported variables to authorized namespaces.
