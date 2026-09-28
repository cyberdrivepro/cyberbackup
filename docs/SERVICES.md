# CyberVPS Rootless Service Manager

The CyberVPS Service Manager allows non-root Linux users to define, supervise, and operate 24/7 background daemons without root or sudo permissions.

---

## 1. Overview & Architecture

Traditional service managers (`systemd` system units, `init.d`, `upstart`) require root access to manage daemon units in `/etc/systemd/system/`. In restricted environments, users are unable to create or start system units.

CyberVPS solves this by introducing a user-space daemon supervisor that supports:
- Automatic backend selection: `systemd --user` $\rightarrow$ `tmux` $\rightarrow$ `screen` $\rightarrow$ `nohup`
- Structured JSON definitions stored in `~/.config/cybervps/services/<service-name>.json`
- State tracking and PID management in `~/.local/state/cybervps/services/`
- Standardized logging to `~/.local/state/cybervps/logs/services/<service-name>.log`
- Configurable health checks (`process`, `tcp`, `http`, `command`)
- Automatic crash detection and restart with exponential backoff (1s, 2s, 5s, 10s, 30s, 60s)

---

## 2. Service Definition Schema

Each service definition is a JSON document located at `~/.config/cybervps/services/<name>.json`:

```json
{
  "name": "my-app",
  "command": "python3 server.py",
  "cwd": "/home/user/apps/myapp",
  "env": {
    "PORT": "8080",
    "ENV": "production"
  },
  "port": 8080,
  "enabled": true,
  "restart": "always",
  "crash_count": 0,
  "health_check": {
    "type": "http",
    "target": "http://127.0.0.1:8080/health",
    "interval": 30,
    "timeout": 5
  }
}
```

### Configuration Fields

| Field | Type | Description |
| :--- | :--- | :--- |
| `name` | string | Unique service identifier (alphanumeric, hyphens, underscores). |
| `command` | string | Complete execution command line. |
| `cwd` | string | Working directory for the daemon. Defaults to `$HOME`. |
| `env` | object | Key-value environment variables exported before starting. |
| `port` | number/null | Network port bound by the service (checked for collisions prior to start). |
| `enabled` | boolean | Whether the service should automatically launch during recovery/reboot. |
| `restart` | string | Restart policy: `always`, `on-failure`, or `never`. |
| `crash_count` | number | Accumulated unexpected crash count (used for backoff calculation). |
| `health_check` | object | Health check configuration (`process`, `tcp`, `http`, `command`). |

---

## 3. Health Check Types

1. **`process`**: Verifies that the recorded PID is actively executing in the user's process table (`kill -0 <pid>`).
2. **`tcp`**: Probes whether a specific local TCP port is accepting connections (`nc -z` or `/dev/tcp`).
3. **`http`**: Issues an HTTP request to an endpoint and expects a 2xx or 3xx HTTP response.
4. **`command`**: Runs a custom user-defined validation shell script; exit code 0 indicates healthy.

---

## 4. CLI Usage

```bash
# Register a new service
cybervps service add my-web --cmd "python3 -m http.server 8080" --port 8080 --cwd "$HOME/www"

# List all registered services and live statuses
cybervps service list

# Start, stop, or restart a service
cybervps service start my-web
cybervps service stop my-web
cybervps service restart my-web

# Inspect status and metadata
cybervps service status my-web

# Stream or view service output logs
cybervps service logs my-web 50

# Enable or disable recovery autostart
cybervps service enable my-web
cybervps service disable my-web

# Remove a registered service
cybervps service remove my-web
```
