# Startup and recovery

CyberVPS distinguishes process detachment, login recovery, boot autostart, and provider lifecycle. None of these can keep a workload running after the provider stops or deletes its node.

| Mechanism | What is established | Remaining conditions |
|---|---|---|
| tmux / screen / nohup | Detached processes can continue after SSH disconnect | The node and process must remain running; nohup has no interactive attach |
| Managed shell profile hook | Login can trigger enabled service recovery | The relevant profile must be sourced; recovery can fail and reports a nonzero result |
| User systemd with linger | A user manager is operational and linger is enabled | Services must be enabled; host/provider boot behavior still applies |
| User crontab | The current account can read or create its crontab | A cron daemon, @reboot support, and provider boot semantics must be verified |
| System systemd | PID 1 and an operational system manager are detected | Boot autostart requires enabled system units and legitimate administration privileges |

`cybervps persistence status` reports capabilities, not a guarantee that hooks have been installed. A crontab binary alone is never proof of boot autostart. Provider persistence remains UNKNOWN unless authoritative provider configuration is available.

Commands:

```bash
cybervps persistence status
cybervps persistence setup
cybervps persistence recover
cybervps persistence disable
```

`setup` installs login recovery and, when permitted, a marked cron recovery hook. It does not enable linger or change host lifecycle settings. Cron writes propagate errors. `disable` removes the managed login blocks and marked cron hook; unrelated crontab entries remain untouched. Legacy unmarked cron entries from older versions are left for explicit review.

`recover` starts enabled services that are not running and returns failure if any service fails. Logs are stored in `${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/logs/recovery.log`.
