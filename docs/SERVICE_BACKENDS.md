# CyberVPS Service Persistence & Backend Architecture

In rootless Linux VPS environments, traditional system-level process management (`sudo systemctl start ...`) is unavailable. CyberVPS provides an abstraction layer that selects the most capable persistence backend available to the non-root user.

---

## 1. Supported Backends

| Backend | Priority | Description | Ideal For |
|---|---|---|---|
| **`systemd --user`** | 1 (Preferred) | User-scoped systemd daemon managed by host `systemd` instance. | Providers that enable systemd user sockets and lingering. |
| **`tmux`** | 2 | Session-based detached multiplexer. Processes run inside dedicated sessions. | Interactive multi-window debugging and monitoring. |
| **`screen`** | 3 | Detached GNU screen sessions. | Environments with screen pre-installed. |
| **`nohup`** | 4 (Universal) | Disowned background processes with PID tracking in `$HOME/run/*.pid`. | Minimal container and restricted shell environments. |

---

## 2. Selection & Configuration

By default, `CYBERVPS_PROCESS_BACKEND=auto` automatically tests each backend in priority order and selects the best working option.

To force a specific backend, set it in `$HOME/.config/cybervps/config.env`:
```bash
CYBERVPS_PROCESS_BACKEND=tmux
# Options: auto, systemd-user, tmux, screen, nohup
```

---

## 3. Login-Triggered Recovery vs. Boot Autostart

### Important Technical Distinction
- **True Boot Autostart:** Requires either `loginctl enable-linger $USER` (which typically requires root intervention) or provider-level boot hooks.
- **Login-Triggered Recovery:** Automatically executes when the user logs in via SSH or console by evaluating a managed block inside `~/.bashrc` or `~/.profile`.

CyberVPS implements **login-triggered recovery** using managed, idempotent marked blocks:
```bash
# >>> CYBERVPS LOGIN RECOVERY >>>
if [ -x "$HOME/bin/cybervps-start" ]; then
    "$HOME/bin/cybervps-start" --background >/dev/null 2>&1 || true
fi
# <<< CYBERVPS LOGIN RECOVERY <<<
```
This guarantees that if the VPS restarts and the user reconnects, all services automatically resume without duplicate instances.

---

## 4. Provider Policy Compliance

Certain VPS providers monitor process names, memory thresholds, or socket listeners:
- CyberVPS **never** uses disguised process names to bypass detection.
- If a provider terminates a process or blocks raw socket creation, CyberVPS detects the stoppage, reports `PROVIDER RESTRICTION`, and gracefully falls back or continues without blocking other services.
