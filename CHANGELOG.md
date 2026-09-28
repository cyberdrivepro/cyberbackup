# Changelog

All notable changes to the CyberVPS project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2026-09-28

### Added
- **CyberVPS Ultra Auto Zero-Touch Engine (`lib/auto.sh`):**
  - Fully automated system discovery: OS, kernel, cgroups v2/v1 CPU and RAM limits, privilege classification, container detection (Docker, LXC, Daytona, WSL).
  - Decision engine: Native Root vs PRoot Virtual Root vs CyberRoot userns vs Windows Userspace.
  - Zero-touch installation levels:
    - Level 1: Core System & Telemetry (git, curl, jq, tmux, nano, CyberAgent).
    - Level 2: Universal Hosting Stack (Nginx, PHP-FPM, Node.js, pnpm, Python 3, Redis, PM2).
    - Level 3: Developer Suite (C/C++ toolchain, GCC, Clang, CMake, Go, Rust).
    - Level 4: Ultra Full (Hosting + Developer + Cloudflare Tunnel + Web Terminal + Supervision).
- **PRoot Virtual Root Guest Runtime (`lib/proot.sh`):**
  - Portable static PRoot engine for unprivileged / rootless containers and sandboxes.
  - Virtual Debian/Ubuntu root environment (`root@cybervps:~#`) with full `apt-get` capabilities.
  - Automatic `/etc/resolv.conf`, `/etc/hosts`, and safe bind mounts (`/proc`, `/sys`, `/dev`, `/root/host`).
  - Shell integration hook for interactive SSH login auto-entry with escape hatch (`cybervps host` / `CYBERVPS_HOST_SHELL=1`).
- **Unified Privilege Matrix (`lib/privilege.sh`):**
  - Exact classification: `ROOT`, `CONTAINER_ROOT`, `SUDO_AUTHORIZED`, `ROOTLESS`, `CYBERROOT_GUEST`.
- **Cgroups Resource Awareness (`lib/resources.sh`):**
  - Accurate cgroup v2/v1 container quotas (`memory.max`, `cpu.max` quota/period) over host-visible hardware.
- **Resilient Multi-Mirror Download Engine (`lib/download.sh`):**
  - Multi-endpoint fallback, SHA256 integrity verification, atomic `.part` rename.
- **Process Supervision & Process Ownership (`scripts/runtime_control.py`, `scripts/process_identity.py`):**
  - Background session and job tracking with `/proc/<pid>/stat` ownership and automatic dead PID reaping.

### Fixed
- Fixed race conditions and directory caching in `lib/jobs.sh` with dynamic `XDG_STATE_HOME` resolution.
- Fixed `ttyd` web terminal launch race condition and mock integration tests.
- Fixed subshell variable scope shadowing in `lib/install.sh`.
- Fixed non-blocking UI pause (`ui_pause`) in headless test automation.

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
