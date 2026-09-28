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
