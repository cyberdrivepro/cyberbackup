# CyberVPS Telegram Remote Administration & Heartbeat

CyberVPS features a native, zero-external-dependency Telegram administration agent (`agent/cybervps_telegram.py`) that operates 24/7 as a persistent background daemon.

---

## 1. Overview & Capabilities

The Telegram agent connects directly to the Telegram Bot API using HTTPS long-polling. It enables full VPS monitoring and administration from your phone or desktop Telegram app without requiring open inbound firewall ports.

### Key Capabilities
- **24/7 Persistent Daemon**: Supervised by the CyberVPS service manager as service `cybervps-telegram`.
- **Zero Third-Party Dependencies**: Written entirely using Python 3's built-in standard library (`urllib.request`, `json`, `subprocess`).
- **Strict Authorization**: Only configured `ADMIN_USER_IDS` can interact with the bot; unauthorized attempts are blocked and logged.
- **Automated Heartbeat**: Sends periodic liveness pings (default: every 7 minutes) with host metrics (RAM, Disk, CPU, active services).
- **Interactive UI**: Inline buttons to quickly start, stop, and inspect services without typing CLI commands.

---

## 2. Supported Telegram Commands

| Command | Description |
| :--- | :--- |
| `/start` | Welcome prompt and overview of capabilities. |
| `/help` | Comprehensive listing of commands and syntax. |
| `/status` | Hostname, architecture, uptime, CPU, RAM, disk usage, and active services. |
| `/services` | List all managed services with inline start/stop/restart action buttons. |
| `/sessions` | List active persistent terminal sessions. |
| `/webterm` | Inspect web terminal status or start/stop it. |
| `/tunnel` | Start/stop Cloudflare tunnel and retrieve live public HTTPS access URLs. |
| `/job` | List long-running background jobs and check progress. |
| `/logs <service>` | Fetch the last 25 lines of output logs from any service or job. |
| `/reboot` | Trigger persistence recovery engine without host reboot. |

---

## 3. Automated VPS Heartbeat Subsystem

The Telegram agent provides an automated heartbeat pulse to assure operators that the remote VPS is online and operational:

- **Interval**: Configurable between 5 and 60 minutes (default: 7 minutes).
- **Modes**:
  - `compact`: Single-line status update:  
    `💓 [VPS: SoloA] Status: OK | RAM: 34% | Disk: 48% | Uptime: 4d 12h | Active Svcs: 3`
  - `message`: Full multiline diagnostic summary.
- **Lifecycle Notices**: Automatic alerts sent immediately on bot startup and graceful shutdown.

---

## 4. Configuration & Security

### Bot Token Storage
The bot token is stored strictly outside the Git repository in:
`~/.config/cybervps/telegram/bot_token` (mode `0600`).

To store your token:
```bash
cybervps telegram set-token "<YOUR_TELEGRAM_BOT_TOKEN>"
```

### Authorizing Admin User IDs
To restrict bot access to your Telegram user ID:
```bash
cybervps telegram set-users 123456789
```

### Configuring Heartbeat Settings
```bash
# Enable heartbeat with 7-minute interval in compact mode
cybervps telegram configure-heartbeat true 7 compact

# Disable heartbeat notifications
cybervps telegram configure-heartbeat false
```

### Starting and Stopping the Bot Daemon
```bash
# Start bot as a persistent background daemon
cybervps telegram start

# Test API connectivity and verify bot username
cybervps telegram test

# View live daemon activity and audit logs
cybervps telegram logs 50

# Stop bot daemon
cybervps telegram stop
```
