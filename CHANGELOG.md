# Changelog

All notable changes to the CyberVPS project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-09-27

### Added
- **Resilient Execution Engine (`lib/execution.sh`):**
  - Explicit internal Bash dispatch (`bash "$script" "$@"`) bypassing executable bit requirements (`chmod -x`).
  - Automatic `noexec` mountpoint detection across `/proc/mounts`.
  - Permission self-repair (`bash cybervps.sh --repair`).
  - Friendly exit code interpreter distinguishing between permissions, missing commands, and signals.
- **Terminal UI V3 (`lib/ui.sh`):**
  - Pure Bash and ANSI implementation with zero external TUI dependencies.
  - Responsive terminal width clamping with Unicode rounded boxes and ASCII fallback.
  - Rootless capability badges (`[✓ User-Space] [✓ Git] [✓ Net] [– Root] [– System Pkgs]`).
  - Interactive preflight environment check box displaying system state, writable HOME, architecture, and disk/RAM stats.
  - Failure card screen (error boundary) preventing menu crashes on child script non-zero exit.
- **Root Command Guard (`scripts/root-command-guard.sh`):**
  - High-performance repository scanner enforcing zero prohibited root commands (`sudo`, `su`, `apt install`).
- **Static Function Dependency Auditor (`scripts/audit-bash-dependencies.sh`, `scripts/audit_bash_dependencies.py`):**
  - Analyzes shell scripts and ensures every called function is properly defined.
- **Diagnostics Export (`scripts/cybervps-export-diagnostics.sh`):**
  - Generates sanitized host diagnostic report to `$HOME/cybervps-diagnostics-<TIMESTAMP>.txt`.
- **Interactive Rebuild Profiles:**
  - Interactive profile selection menu in `fresh-install.sh`: `minimal`, `hosting`, `developer`, `full`.
- **Non-Stacking SIGINT Trap:**
  - Prevents recursive stacked prompts on repeated Ctrl+C.

### Fixed
- Fixed missing `ensure_cybervps_profile` function call in `lib/install.sh`.
- Added missing `init_ports_config` definition in `lib/ports.sh`.
- Fixed EOF handling on interactive piped input in `cybervps.sh`.
- Fixed child process error boundaries to preserve main menu state on non-zero exit codes.

---

## [1.0.0] - 2026-09-27

### Added
- Archive security validation engine (`lib/archive.sh`) rejecting path traversals and malicious symlinks.
- User-space locking engine (`lib/lock.sh`) with stale PID recovery.
- Architecture and Libc compatibility validator (`lib/architecture.sh`).
- Modular standalone installers under `installers/`.
- Dynamic unprivileged port allocator (`lib/ports.sh`).
- Relative backup format (Format v2) in `lib/backup.sh` and `lib/restore.sh`.
- Multi-backend service manager (`lib/services.sh`).
