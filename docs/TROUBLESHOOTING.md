# CyberVPS Troubleshooting Guide

This guide covers common issues, debugging steps, and resolutions for CyberVPS.

---

## 1. Port Collisions / Port Already in Use

### Symptom
A service fails to start or outputs `Address already in use`.

### Resolution
1. Check allocated ports in `$HOME/.config/cybervps/ports.env`.
2. Inspect which process is occupying the port:
   ```bash
   ss -tlnp 2>/dev/null | grep ":<PORT>"
   ```
3. Remove the conflicting line from `ports.env` or run:
   ```bash
   bash ./verify.sh
   ```
   CyberVPS will detect the collision and auto-allocate an available unprivileged port.

---

## 2. Lock Acquisition Failures

### Symptom
Error message: `Another CyberVPS process is currently running (... locked).`

### Cause
A previous operation was abruptly interrupted (e.g., SSH disconnection) leaving a stale lock.

### Resolution
1. Verify no CyberVPS process is actively archiving or downloading:
   ```bash
   ps -u $(whoami) -o pid,stat,args | grep -E "backup|restore|tar"
   ```
2. If safe, remove the stale lock file:
   ```bash
   rm -rf ~/.config/cybervps/locks/*.lock
   ```

---

## 3. Secret Scanner Rejection

### Symptom
`scripts/secret-check.sh` fails with:
`[FAIL] Secret pattern matched in ... at line(s): ...`

### Resolution
1. Inspect the indicated file and line numbers.
2. Remove plaintext credentials, tokens, or private keys.
3. If the file is a template or example, replace the real credential with a placeholder like `your_token_here`.
4. If the file is an active credential file (e.g. `.env`), ensure it is added to `.gitignore`.

---

## 4. Unicode / Terminal Display Artifacts

### Symptom
Terminal menu shows strange character sequences like `\u2550` or broken frames.

### Resolution
Your terminal environment does not have a UTF-8 locale configured.
1. Set a UTF-8 locale:
   ```bash
   export LANG=C.UTF-8
   export LC_ALL=C.UTF-8
   ```
2. CyberVPS detects non-UTF-8 locales and automatically falls back to clean ASCII box-drawing characters.

---

## 5. Central Logs

All debug and operational logs are recorded in:
```
$HOME/.local/state/cybervps/logs/cybervps.log
```
Inspect recent log entries:
```bash
tail -n 50 ~/.local/state/cybervps/logs/cybervps.log
```
