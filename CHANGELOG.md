# Changelog

All notable changes to the CyberVPS project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.1.0] - 2026-09-30

### Added
- **CyberVPS Transfer Cloud + CyberFleet Subsystem (`fleet/`, `lib/fleet.sh`, `lib/transfer.sh`):**
  - **CyberFleet Controller (`fleet/controller.py`, `fleet/database.py`):**
    - High-performance FastAPI ASGI application with thread-safe SQLite persistence (WAL mode, auto-migration, mode 0600).
    - Architecture designed for seamless future PostgreSQL adapter plug-in.
    - Automated background node watchdog tracking health (`ONLINE` <=15s, `DEGRADED` 15–45s, `OFFLINE` >45s).
    - Node state recovery (`NODE_LOST` job reassignment) and resilient crash recovery.
  - **VPS Agent (`fleet/agent.py`):**
    - Lightweight, outbound-only daemon (no inbound ports required on managed nodes).
    - Periodic 5-second heartbeats sending live telemetry and dynamic job poll/dispatch loop.
    - User-space execution with low memory footprint (<30MB RSS).
  - **Real Effective Resource Metrics (`fleet/metrics.py`):**
    - Accurate container-aware cgroup v2 (`cpu.max`, `cpuset.cpus`, `memory.max`, `memory.current`) and cgroup v1 fallback.
    - Live network traffic monitoring from `/proc/net/dev` with exponential moving average (EMA) for RX/TX MB/s.
    - Real-time disk utilization checks and safety headroom reserves (5–10%).
    - Distinct separation between live traffic metrics, benchmark capacity, and actual job download speeds.
  - **Intelligent Download-Node Scheduler (`fleet/scheduler.py`):**
    - Multi-dimensional scoring algorithm weighting available disk, active job concurrency, live network load, historical real download speeds, effective RAM, and reliability history.
    - Candidate exclusion on offline status or insufficient disk.
    - Human-readable selection reason logged and exposed via API/CLI.
  - **Strict SSRF Protection Engine (`fleet/ssrf.py`):**
    - Pre-connection and post-redirect DNS validation rejecting loopback (`127.0.0.0/8`, `::1`), private RFC 1918 networks, CGNAT, link-local, and cloud metadata endpoints (`169.254.169.254`, `fd00:ec2::254`, `100.100.100.200`).
    - Protocol enforcement: HTTP and HTTPS only. Dangerous schemes (`file://`, `gopher://`, `ftp://`, `data:`) strictly blocked.
    - Embedded authority credentials rejected.
  - **Safe URL Probe Engine (`fleet/probe.py`):**
    - Fast HTTP HEAD probe with `Range: bytes=0-0` GET fallback.
    - Extracts Content-Disposition filename, Content-Length, Content-Type, Accept-Ranges, and ETag.
    - Re-validates every redirect hop through the strict SSRF guard.
  - **Adaptive Download Engine (`fleet/downloader.py`):**
    - Multi-stream downloading via `aria2c` with adaptive connection scaling (1 for tiny, 2–4 small, 4–8 medium, 8–16 large files; 1 if Accept-Ranges unsupported).
    - Transparent fallback to `curl` with resume capability (`-C -`).
    - Atomic `.part` file renaming, SHA-256 integrity verification, and disk space pre-check.
  - **Real-Time Website Dashboard (`fleet/static/`):**
    - Pure ANSI/CSS CYBER DARK design system (zero external CDN or node_modules dependencies).
    - Live WebSocket stream (`/api/v1/ws/dashboard`) with automatic reconnection and aggregate telemetry.
    - Interactive node cards displaying status, live RX/TX, benchmark capacity, and real download speeds.
    - Download intake bar, active transfer center, progress bars, pause/cancel controls, and Cybershare modal.
  - **Cybershare Secure Public / Expiring Links (`fleet/delivery.py`):**
    - HMAC-SHA256 signed URL tokens with configurable expiration (default 24h).
    - High-efficiency HTTP Range 206 Partial Content chunked streaming (64KB chunks) with zero full-file RAM buffering.
    - Strict path traversal guard (`is_safe_path`).
  - **Telegram Bot Remote Control & Delivery (`fleet/telegram.py`):**
    - Multi-command bot daemon (`/start`, `/download`, `/jobs`, `/nodes`, `/status`, `/cancel`).
    - Admin user ID authorization checks rejecting unauthorized callers.
    - Rate-throttled live progress messages (max once every 3 seconds).
    - Direct document upload for files <=50MB; automatic fallback to signed Cybershare download link for larger files.
  - **CLI Integration & Executables (`fleet/cli.py`, `scripts/cybervps-fleet`, `scripts/cybervps-transfer`):**
    - Seamless `cybervps fleet` and `cybervps transfer` CLI command suites.
    - `cybervps fleet doctor` diagnostic command for instant readiness checks.

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
