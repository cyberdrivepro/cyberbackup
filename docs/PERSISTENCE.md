# CyberVPS Multi-Tier Persistence Architecture

CyberVPS operates in non-root environments where privileged systemd root units, kernel modifications, and system-wide init configurations are strictly unavailable. To provide true 24/7 service and terminal durability across SSH disconnects and host reboots, CyberVPS implements a multi-tier persistence engine.

---

## 1. Multi-Tier Persistence Matrix

CyberVPS automatically evaluates host capabilities at runtime and selects the strongest available persistence tier:

| Tier | Mechanism | Trigger Event | Privileges Required | Survival Capability |
| :--- | :--- | :--- | :--- | :--- |
| **Tier 1: True Boot Autostart** | `systemd --user` with linger | System Boot / Restart | `loginctl enable-linger` (or pre-configured linger) | Services start immediately when the VPS powers on, before any SSH login. |
| **Tier 2: User Cron Autostart** | `cron @reboot` | System Boot | User crontab permissions | Starts service recovery wrapper on system boot. |
| **Tier 3: Login-Triggered Recovery** | `.bashrc` idempotent hook | User SSH / Shell Login | Standard non-root user permissions | Resumes services and recovers dead sessions upon interactive or non-interactive login. |
| **Tier 4: Process Detachment** | `tmux` / `screen` / `nohup` | SSH Disconnection | Pure user-space binaries | Prevents SIGHUP from terminating active long-running jobs when connection drops. |

---

## 2. Tier 1: True Boot Autostart (`systemd --user`)

When `systemd --user` is available and user linger is active:
1. CyberVPS generates user-level service units located in `~/.config/systemd/user/`.
2. Services are enabled using `systemctl --user enable <service>`.
3. The host systemd instance maintains the user manager even after SSH sessions disconnect.

To inspect whether linger is enabled on the host:
```bash
loginctl show-user $USER --property=Linger
```

---

## 3. Tier 3: Login-Triggered Recovery Engine

When linger and cron are restricted by cloud providers, CyberVPS automatically installs an idempotent hook into `$HOME/.bashrc`:

```bash
# >>> CYBERVPS LOGIN RECOVERY >>>
if [ -f "$HOME/cyberbackup/scripts/cybervps-persistence" ]; then
    bash "$HOME/cyberbackup/scripts/cybervps-persistence" recover >/dev/null 2>&1 &
fi
# <<< CYBERVPS LOGIN RECOVERY <<<
```

### Safety and Idempotency Guarantees
- The hook checks for duplicate entries and will never inject multiple copies into shell profiles.
- Execution is completely backgrounded (`&`) and silenced (`>/dev/null 2>&1`) to prevent delaying login or interfering with SCP/SFTP transfers.
- The recovery script inspects registered service state files in `~/.config/cybervps/services/` and starts only services marked as `enabled: true`.

---

## 4. CLI Commands

```bash
# Check current persistence tier and status
cybervps persistence status

# Install persistence recovery triggers (systemd linger check, cron @reboot, bashrc hook)
cybervps persistence install

# Trigger manual recovery of all enabled services
cybervps persistence recover

# Uninstall persistence triggers
cybervps persistence remove
```
