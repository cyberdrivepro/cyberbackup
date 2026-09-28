# CyberVPS Background Jobs & Service Watchdog

CyberVPS provides an asynchronous background job manager and an automated service watchdog to manage non-daemon batch tasks (backups, compilations, long downloads) and ensure high availability of active services.

---

## 1. Background Job Manager

Unlike persistent services (which run indefinitely as daemons), **Jobs** represent finite, long-running batch operations that must complete even if the user logs out or loses network connectivity.

### Features
- **Detached Execution**: Executed in detached subshells via `nohup`, completely immune to `SIGHUP`.
- **Structured Metadata**: State, start time, completion time, PID, and exit code saved to `~/.local/state/cybervps/jobs/<name>.json`.
- **Persistent Output Buffering**: Full stdout and stderr captured in `~/.local/state/cybervps/logs/jobs/<name>.log`.
- **Clean Signal Handling**: Clean cancellation via `cybervps job cancel <name>` (`SIGTERM` followed by `SIGKILL` fallback).

### CLI Usage
```bash
# Launch a persistent background task
cybervps job run big-backup "bash backup-now.sh"

# List all running and finished jobs
cybervps job list

# View detailed status and metadata
cybervps job status big-backup

# View job logs
cybervps job logs big-backup 50

# Cancel a running background job
cybervps job cancel big-backup
```

---

## 2. Service Watchdog

The CyberVPS Watchdog inspects registered services and automatically revives terminated or crashed processes.

### Watchdog Characteristics
- **State Audit**: Evaluates all services configured with `enabled: true` and restart policies `always` or `on-failure`.
- **Exponential Backoff**: Prevents CPU thrashing and cascade failures by pacing restart attempts according to historical crash counts:
  - 1st crash: 1s backoff
  - 2nd crash: 2s backoff
  - 3rd crash: 5s backoff
  - 4th crash: 10s backoff
  - 5th crash: 30s backoff
  - 6+ crashes: 60s backoff
- **Automated Check**:
  ```bash
  cybervps job watchdog
  ```
- **Scheduled Supervision**: Can be invoked periodically via user crontab or Telegram bot commands.
