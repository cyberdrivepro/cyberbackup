# CyberVPS

[![CyberVPS Validation CI](https://github.com/cyberdrivepro/cyberbackup/actions/workflows/validate.yml/badge.svg)](https://github.com/cyberdrivepro/cyberbackup/actions/workflows/validate.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Format: v2](https://img.shields.io/badge/Backup%20Format-v2-success.svg)](docs/BACKUP_FORMAT.md)

**Portable Non-Root Linux VPS 24/7 Hosting, Persistent Terminals, Web Terminal, Telegram Control, and Disaster Recovery Platform.**

CyberVPS empowers developers and sysadmins to operate, supervise, persist, backup, migrate, and rebuild complete user-space application environments on **ordinary, unprivileged non-root Linux VPS accounts** without requiring `sudo`, root privileges, Docker, or host package manager modifications.

---

## ⚡ Quick Start

```bash
git clone https://github.com/cyberdrivepro/cyberbackup.git
cd cyberbackup

# One-command Zero-Touch Setup (Interactive Level Selector: Core, Hosting, Dev, Ultra)
bash cybervps.sh auto

# Or enter the full Interactive Control Center:
bash cybervps.sh
```

Upon launch, CyberVPS inspects the host and renders the V4 interactive control center:

```
╭──────────────────────────────────────────────────────────────────────────────╮
│                   CYBERVPS • ROOTLESS CLOUD CONTROL CENTER                   │
├──────────────────────────────────────────────────────────────────────────────┤
│  Host: SoloA                          User: srhfqtos (Mode: ROOTLESS)        │
│  OS:   Debian GNU/Linux 12 (bookworm) Arch: x86_64 (glibc 2.36)              │
│  Home: /home/srhfqtos                                                        │
╰──────────────────────────────────────────────────────────────────────────────╯
  Capabilities: [✓ User-Space] [✓ Git] [✓ Net] [✓ Micromamba] [– Root] [– System Pkgs]

╭─ RECOVERY ───────────────────────────────────────────────────────────────────╮
│  [1] Restore Backup Snapshot                                                │
│  [2] Fresh Install / Rootless Rebuild                                       │
│  [3] Migrate Backup From Another VPS                                        │
╰──────────────────────────────────────────────────────────────────────────────╯
╭─ BACKUP & ARCHIVE ───────────────────────────────────────────────────────────╮
│  [4] Create Backup Snapshot                                                 │
│  [5] Upload Backup to Remote Storage                                        │
│  [6] Download Backup from Remote Storage                                    │
╰──────────────────────────────────────────────────────────────────────────────╯
╭─ HOSTING & RUNTIME ──────────────────────────────────────────────────────────╮
│  [7] Service Manager (Persistent 24/7 Daemons)                              │
│  [8] Persistent Terminals (Session Manager)                                 │
│  [9] Authenticated Web Terminal (Browser SSH)                               │
│  [A] CyberVPS Ultra Auto Provisioning (Zero-Touch)                          │
│  [S] Virtual Root Shell (root@cybervps:~#)                                  │
╰──────────────────────────────────────────────────────────────────────────────╯
╭─ REMOTE CONTROL & ACCESS ────────────────────────────────────────────────────╮
│  [10] Telegram Bot Remote Control & Heartbeat                               │
│  [11] Cloudflare Tunnels (Remote Access)                                    │
│  [12] Background Jobs & Service Watchdog                                    │
╰──────────────────────────────────────────────────────────────────────────────╯
╭─ SYSTEM & TOOLS ─────────────────────────────────────────────────────────────╮
│  [13] Run VPS Health Verification                                           │
│  [14] View CyberVPS Status & Services                                       │
│  [15] Configuration Manager                                                 │
│  [16] Diagnostics & System Inspector                                        │
│  [C]  CyberRoot Rootless Linux Runtime                                      │
│  [R]  Self-Repair & Permission Normalizer                                   │
╰──────────────────────────────────────────────────────────────────────────────╯
  [0] Exit CyberVPS
```

---

## 🌟 Key Capabilities

1. **CyberVPS Ultra Auto (Zero-Touch):** Autonomous discovery of CPU quota, cgroup RAM limits, network, platform, and privilege. One-click setup for 4 tiers: Core, Universal Hosting, Developer Suite, or Ultra Full.
2. **PRoot Virtual Root Runtime:** Seamless Debian/Ubuntu virtual root (`root@cybervps:~#`) for unprivileged containers and rootless accounts. Run `apt-get install` without root!
3. **Zero Root / Sudo Required:** Full user-space portability. Can run under root, container root, sudo, or completely rootless.
4. **Persistent 24/7 Hosting:** Operates daemons independently of interactive SSH sessions and laptop power state.
5. **Persistent Terminal Sessions:** Multiplexed tmux/screen workspaces that survive connection drops, disconnects, and terminal window closures.
6. **Authenticated Browser Web Terminal:** Powered by rootless `ttyd`, bound strictly to `127.0.0.1` with mandatory credentials and tunnel support.
7. **Telegram Remote Control & Heartbeat:** Pure Python 3 standard library daemon with interactive buttons, secret redaction, audit logging, and automated 7-minute liveness heartbeats.
8. **Encrypted Cloudflare Tunnels:** Quick and named tunnels via `cloudflared` to securely expose local web terminals without open firewall ports or public IPv4 addresses.
9. **Background Jobs & Service Watchdog:** Long-running task detachment via `nohup` with state tracking and an automated service watchdog with exponential crash backoff.
10. **Disaster Recovery & Migration:** Rebuilds entire runtime environments (Python, Node, Go, Rust, PM2, Cloudflared) and migrates setups across VPS providers.
11. **Dynamic Port Allocator:** Discovers free unprivileged localhost ports (`>= 1024`), ensuring zero collisions on multi-user VPS hosts.
12. **Strict Credential Security:** All tokens, keys, and passwords stored in `~/.config/cybervps/` (mode 0600) strictly outside Git, validated by an automated pre-commit secret scanner.

---

## 📁 Repository Architecture

```
cyberbackup/
├── cybervps.sh               # Master interactive terminal interface & CLI router
├── backup-now.sh             # Snapshot backup engine entry point
├── restore.sh                # Backup restoration engine entry point
├── migrate.sh                # Cross-host VPS migration entry point
├── fresh-install.sh          # Zero-state user-space rebuild entry point
├── verify.sh                 # VPS health & capability verifier
├── upload-backup.sh          # Remote storage upload helper
├── download-backup.sh        # Remote storage download helper
├── agent/
│   └── cybervps_telegram.py  # Telegram remote administration & heartbeat agent
├── installers/
│   └── ttyd.sh               # Rootless ttyd installer
├── lib/
│   ├── common.sh             # Core utilities, locks, and logging helpers
│   ├── detect.sh             # Identity, architecture, libc, and system detection
│   ├── ports.sh              # Rootless dynamic port allocator
│   ├── services.sh           # Persistent daemon supervisor & health checker
│   ├── sessions.sh           # Persistent terminal session manager
│   ├── persistence.sh        # Multi-tier boot autostart & login recovery engine
│   ├── webterm.sh            # Authenticated browser web terminal manager
│   ├── tunnel.sh             # Cloudflare tunnel manager
│   ├── telegram.sh           # Telegram bot CLI & configuration manager
│   ├── jobs.sh               # Background job executor & service watchdog
│   ├── cyberroot.sh          # Rootless container runtime integration
│   ├── execution.sh          # Centralized script runner & error boundary
│   └── ui.sh                 # ANSI box-drawing and dashboard rendering
├── scripts/                  # CLI command wrapper binaries
│   ├── cybervps-service
│   ├── cybervps-session
│   ├── cybervps-persistence
│   ├── cybervps-webterm
│   ├── cybervps-tunnel
│   ├── cybervps-telegram
│   ├── cybervps-job
│   ├── root-command-guard.sh
│   └── secret-check.sh
├── tests/                    # 20+ automated unit & integration test suites
│   ├── run-tests.sh          # Master test runner
│   ├── test-services.sh
│   ├── test-sessions.sh
│   ├── test-persistence.sh
│   ├── test-webterm.sh
│   ├── test-tunnel.sh
│   ├── test-telegram.sh
│   └── test-jobs.sh
└── docs/                     # Technical specifications & guides
    ├── PERSISTENCE.md        # Multi-tier boot and recovery engine
    ├── SERVICES.md           # Rootless persistent service manager
    ├── SESSIONS.md           # Persistent terminal session manager
    ├── WEB_TERMINAL.md       # Browser web terminal & auth
    ├── TELEGRAM.md           # Telegram remote control & heartbeat
    ├── TUNNELS.md            # Cloudflare remote tunnels
    ├── JOBS.md               # Asynchronous jobs & watchdog supervisor
    ├── SECURITY.md           # Security model & credential isolation
    ├── ARCHITECTURE.md       # Core subsystem architecture
    └── BACKUP_FORMAT.md      # Format v2 specification
```

---

## 💻 CLI Commands

All components support direct non-interactive CLI control:

### Persistent Terminals
```bash
cybervps session new workspace             # Launch persistent session
cybervps session list                      # List active sessions
cybervps session attach workspace          # Attach to session
cybervps session logs workspace 50         # View terminal buffer logs
cybervps session stop workspace            # Terminate session
```

### Persistent Services (24/7 Hosting)
```bash
cybervps service add web --cmd "python3 -m http.server 8080" --port 8080
cybervps service start web
cybervps service list
cybervps service status web
cybervps service logs web 50
cybervps service restart web
cybervps service stop web
```

### Authenticated Web Terminal
```bash
cybervps webterm set-password admin MyStrongPassword123!
cybervps webterm start                     # Runs on 127.0.0.1:7681
cybervps webterm status
cybervps webterm logs
cybervps webterm stop
```

### Cloudflare Tunnels
```bash
cybervps tunnel quick 7681                 # Quick HTTPS tunnel to web terminal
cybervps tunnel url                        # Display public HTTPS URL
cybervps tunnel status
cybervps tunnel stop
```

### Telegram Bot Remote Control & Heartbeat
```bash
cybervps telegram set-token "<YOUR_BOT_TOKEN>"
cybervps telegram set-users 123456789
cybervps telegram configure-heartbeat true 7 compact
cybervps telegram test                     # Verify API connectivity
cybervps telegram start                    # Run as persistent 24/7 service
cybervps telegram logs 50
cybervps telegram stop
```

### Background Jobs & Service Watchdog
```bash
cybervps job run backup-task "bash backup-now.sh"
cybervps job list
cybervps job logs backup-task 50
cybervps job cancel backup-task
cybervps job watchdog                      # Auto-recover failed services with backoff
```

### Persistence Engine
```bash
cybervps persistence status                # View current tier (linger, cron, bashrc)
cybervps persistence install               # Install recovery hooks
cybervps persistence recover               # Trigger immediate service recovery
```

### CyberFleet & CyberTransfer Cloud
```bash
# Fleet Controller
cybervps fleet controller --port 8000      # Run Controller foreground
cybervps fleet start-controller            # Run Controller 24/7 in persistent session
cybervps fleet stop-controller             # Stop Controller daemon
cybervps fleet status                      # View Controller health & aggregate stats
cybervps fleet nodes                       # List enrolled VPS nodes & live metrics
cybervps fleet doctor                      # Run fleet diagnostic checks

# VPS Agent (Runs on each managed VPS node)
cybervps fleet agent --controller http://IP:8000 --secret TOKEN  # Run Agent foreground
cybervps fleet start-agent                 # Run Agent 24/7 in persistent session
cybervps fleet stop-agent                  # Stop Agent daemon

# CyberTransfer Jobs
cybervps transfer add <URL>                # Submit new download job
cybervps transfer list                     # List recent download jobs
cybervps transfer probe <URL>              # Safely inspect remote headers with SSRF guard
cybervps transfer link <JOB_ID> [HOURS]    # Generate HMAC-SHA256 signed Cybershare URL
cybervps transfer cancel <JOB_ID>          # Cancel active transfer
cybervps transfer retry <JOB_ID>           # Retry failed or cancelled job
```

---

## 🌐 CyberVPS Transfer Cloud & CyberFleet (Phase 1 Production)

CyberFleet transforms distributed, rootless Linux VPS instances into a unified high-speed transfer grid coordinated by a central controller.

```
                        CYBERVPS TRANSFER CLOUD

                           WEB DASHBOARD
                                |
                         HTTPS / WebSocket
                                |
                    +-------------------------+
                    |  CYBERFLEET CONTROLLER  |
                    |                         |
                    | Node Registry           |
                    | Heartbeat Watchdog      |
                    | Multi-Factor Scheduler  |
                    | Strict SSRF Guard       |
                    | Safe URL Probe          |
                    | Telegram Dispatcher     |
                    | Signed File Delivery    |
                    +-----------+-------------+
                                |
                     outbound secure channel
                                |
          +---------------------+----------------------+
          |                     |                      |
     VPS AGENT 01          VPS AGENT 02           VPS AGENT N
          |                     |                      |
      aria2/curl             aria2/curl              aria2/curl
      metrics               metrics                 metrics
      storage               storage                 storage
```

### Core Components

1. **CyberFleet Controller (`fleet/controller.py`):**
   - High-throughput FastAPI ASGI application with thread-safe SQLite persistence (WAL mode, mode 0600) designed for PostgreSQL transition.
   - Node watchdog tracking real-time status: `ONLINE` (<=15s), `DEGRADED` (15–45s), `OFFLINE` (>45s).
   - Resilient crash recovery: inflight jobs on dead nodes transition safely to `NODE_LOST` and are automatically recovered.

2. **VPS Agent (`fleet/agent.py`):**
   - Outbound-only agent daemon requiring zero inbound open ports or public IPs on target nodes.
   - 5-second heartbeats broadcasting container cgroup limits, disk usage, and live moving-average bandwidth.

3. **Intelligent Node Selection (`fleet/scheduler.py`):**
   - Multi-dimensional scoring formula:
     $$\text{Score} = (\text{Disk Free} \times 0.25) + (\text{Avail Slots} \times 0.25) + (\text{Real Speed Hist} \times 0.20) + (\text{Live Net Headroom} \times 0.15) + (\text{Reliability} \times 0.15)$$
   - Disqualifies offline/degraded nodes and nodes below disk safety thresholds (5–10% reserve).

4. **Strict SSRF Protection Guard (`fleet/ssrf.py`):**
   - Pre-connection & post-redirect DNS validation.
   - Blocks cloud metadata endpoints (`169.254.169.254`, `fd00:ec2::254`, `100.100.100.200`), loopback (`127.0.0.0/8`, `::1`), private RFC 1918 addresses, and non-HTTP(S) schemes (`file://`, `gopher://`, `ftp://`).

5. **Adaptive Download Engine (`fleet/downloader.py`):**
   - Multi-connection scaling with `aria2c` (1 stream for tiny files, up to 16 streams for large files), with transparent fallback to `curl`.
   - Streaming SHA-256 integrity verification and atomic `.part` rename.

6. **Cybershare Signed Expiring Links (`fleet/delivery.py`):**
   - HMAC-SHA256 signed tokens with configurable TTL (default 24h).
   - HTTP Range 206 Partial Content streaming using fixed 64KB buffers (zero full-file RAM buffering).

7. **Telegram Bot Integration (`fleet/telegram.py`):**
   - Dedicated bot interface supporting `/download`, `/jobs`, `/nodes`, `/status`, `/cancel`.
   - Direct Telegram document delivery for files <= 50MB; automatic fallback to signed Cybershare links for larger files.
   - Rate-throttled progress updates (max once per 3s).


---

## 🧪 Automated Testing

CyberVPS includes an automated, non-destructive test suite that executes in isolated temporary sandboxes:

```bash
bash tests/run-tests.sh
```

---

## 🔒 Security Principles

- **Zero Root Privilege Escalation:** CyberVPS never runs `sudo` or modifies system directories.
- **Strict Credential Isolation:** Credentials and tokens stored at mode `0600` strictly outside Git.
- **Loopback Default:** Web terminal and private daemons bind strictly to `127.0.0.1`.
- **Pre-Commit Secret Scanner:** Statically scans candidate commits to ensure zero credential leaks (`bash scripts/secret-check.sh`).

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
