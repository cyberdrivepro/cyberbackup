#!/usr/bin/env python3
"""
CyberVPS Telegram Remote Administration & Heartbeat Daemon
Pure Python 3 standard library implementation:
- Telegram Bot API long-polling (/getUpdates)
- Strict ADMIN_USER_IDS allowlist & authorization
- Automated VPS Heartbeat (5-10 min, compact & status modes)
- Service & Session Lifecycle Management
- Web Terminal & Cloudflare Tunnel Remote Controls
- Audit logging with secret redaction
- Graceful SIGTERM/SIGINT shutdown notification
"""

import sys
import os
import json
import time
import signal
import urllib.request
import urllib.parse
import urllib.error
import subprocess
import threading
from datetime import datetime, timezone

# Base directories
HOME = os.path.expanduser("~")
CONFIG_DIR = os.environ.get("XDG_CONFIG_HOME", os.path.join(HOME, ".config"))
STATE_DIR = os.environ.get("XDG_STATE_HOME", os.path.join(HOME, ".local/state"))

TG_CONFIG_DIR = os.path.join(CONFIG_DIR, "cybervps", "telegram")
TG_STATE_DIR = os.path.join(STATE_DIR, "cybervps", "telegram")
TG_LOG_DIR = os.path.join(STATE_DIR, "cybervps", "logs")

TOKEN_FILE = os.path.join(TG_CONFIG_DIR, "bot_token")
CONFIG_FILE = os.path.join(TG_CONFIG_DIR, "config.json")
STATE_FILE = os.path.join(TG_STATE_DIR, "state.json")
AUDIT_FILE = os.path.join(TG_STATE_DIR, "audit.log")

REPO_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CYBERVPS_BIN = os.path.join(REPO_DIR, "cybervps.sh")

# Ensure required directories exist with private permissions
os.makedirs(TG_CONFIG_DIR, mode=0o700, exist_ok=True)
os.makedirs(TG_STATE_DIR, mode=0o700, exist_ok=True)
os.makedirs(TG_LOG_DIR, mode=0o755, exist_ok=True)

# Global runtime flags
RUNNING = True
LAST_UPDATE_ID = 0
HEARTBEAT_THREAD = None


def redact_secrets(text: str) -> str:
    """Redacts bot tokens and keys from log strings."""
    import re
    text = re.sub(r'[0-9]{8,10}:AA[a-zA-Z0-9_-]{33,35}', '[REDACTED_BOT_TOKEN]', text)
    text = re.sub(r'password["\']?\s*[:=]\s*["\'][^"\']+["\']', 'password=[REDACTED]', text, flags=re.I)
    text = re.sub(r'token["\']?\s*[:=]\s*["\'][^"\']+["\']', 'token=[REDACTED]', text, flags=re.I)
    return text


def audit_log(user_id: int, action: str, target: str, result: str):
    """Appends an entry to the audit log."""
    ts = datetime.now(timezone.utc).isoformat()
    entry = json.dumps({"timestamp": ts, "actor": user_id, "action": action,
                        "target": redact_secrets(target), "result": redact_secrets(result)}) + "\n"
    try:
        if os.path.exists(AUDIT_FILE) and os.path.getsize(AUDIT_FILE) > 1048576:
            os.replace(AUDIT_FILE, AUDIT_FILE + ".1")
        with open(AUDIT_FILE, "a", encoding="utf-8") as f:
            f.write(entry)
    except Exception:
        pass


def get_token() -> str:
    """Reads bot token from 0600 file outside Git."""
    if not os.path.isfile(TOKEN_FILE):
        return ""
    try:
        with open(TOKEN_FILE, "r", encoding="utf-8") as f:
            return f.read().strip()
    except Exception:
        return ""


def load_config() -> dict:
    """Loads configuration with safe defaults."""
    default_cfg = {
        "admin_user_ids": [],
        "admin_chat_ids": [],
        "heartbeat_enabled": True,
        "heartbeat_interval_minutes": 7,
        "heartbeat_mode": "compact",  # "compact" or "message"
        "expert_mode": False
    }
    if not os.path.isfile(CONFIG_FILE):
        save_config(default_cfg)
        return default_cfg
    try:
        with open(CONFIG_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
            default_cfg.update(data)
            return default_cfg
    except Exception:
        return default_cfg


def save_config(cfg: dict):
    """Saves configuration atomically."""
    tmp = CONFIG_FILE + f".tmp.{os.getpid()}"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2)
        os.replace(tmp, CONFIG_FILE)
        os.chmod(CONFIG_FILE, 0o600)
    except Exception as e:
        print(f"Error saving config: {e}", file=sys.stderr)


def load_state() -> dict:
    """Loads heartbeat state."""
    if not os.path.isfile(STATE_FILE):
        return {}
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_state(state: dict):
    """Saves state atomically."""
    tmp = STATE_FILE + f".tmp.{os.getpid()}"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(state, f, indent=2)
        os.replace(tmp, STATE_FILE)
        os.chmod(STATE_FILE, 0o600)
    except Exception:
        pass


def telegram_api(method: str, params: dict = None) -> dict:
    """Executes a Telegram Bot API request with bounded retry."""
    token = get_token()
    if not token:
        return {"ok": False, "description": "Token not configured"}

    url = f"https://api.telegram.org/bot{token}/{method}"
    data = None
    headers = {"User-Agent": "CyberVPS-Bot/1.0"}

    if params:
        data = json.dumps(params).encode("utf-8")
        headers["Content-Type"] = "application/json"

    backoffs = [2, 5, 10]
    for attempt in range(len(backoffs) + 1):
        try:
            req = urllib.request.Request(url, data=data, headers=headers)
            with urllib.request.urlopen(req, timeout=35) as resp:
                raw = resp.read().decode("utf-8")
                return json.loads(raw)
        except urllib.error.HTTPError as e:
            err_body = e.read().decode("utf-8", errors="ignore")
            # 401 or 404: immediate return
            if e.code in (401, 404):
                return {"ok": False, "error_code": e.code, "description": err_body}
            if attempt < len(backoffs):
                time.sleep(backoffs[attempt])
        except Exception as e:
            if attempt < len(backoffs):
                time.sleep(backoffs[attempt])

    return {"ok": False, "description": "Network timeout or connection failed"}


def send_message(chat_id: int, text: str, reply_markup: dict = None) -> bool:
    """Sends a Telegram message, truncating safely if too large."""
    text = redact_secrets(text)
    if len(text) > 4000:
        text = text[:3950] + "\n... [Truncated for size]"
    params = {"chat_id": chat_id, "text": text, "parse_mode": "HTML"}
    if reply_markup:
        params["reply_markup"] = reply_markup
    res = telegram_api("sendMessage", params)
    return res.get("ok", False)


def run_cybervps_cmd(args: list) -> tuple:
    """Runs a cybervps subcommand and returns (returncode, stdout, stderr)."""
    env = os.environ.copy()
    env["PATH"] = f"{HOME}/.local/bin:{HOME}/bin:{HOME}/apps/micromamba/envs/hosting/bin:" + env.get("PATH", "")
    cmd = ["bash", CYBERVPS_BIN] + args
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=30, env=env)
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "Command timed out after 30 seconds"
    except Exception as e:
        return 1, "", str(e)


# ==============================================================
# HEARTBEAT ENGINE
# ==============================================================

def get_system_summary() -> dict:
    """Extracts VPS runtime status for heartbeat."""
    hostname = os.uname().nodename if hasattr(os, "uname") else "linux-vps"

    # Uptime
    uptime_str = "unknown"
    try:
        with open("/proc/uptime", "r") as f:
            total_sec = float(f.readline().split()[0])
            days = int(total_sec // 86400)
            hours = int((total_sec % 86400) // 3600)
            mins = int((total_sec % 3600) // 60)
            uptime_str = f"{days}d {hours}h {mins}m"
    except Exception:
        pass

    # Services
    rc, out, _ = run_cybervps_cmd(["service", "list"])
    running_svc = out.count("RUNNING")
    total_svc = max(0, len([l for l in out.splitlines() if l.strip() and not l.startswith("-") and not l.startswith("NAME")]))

    # Sessions
    rc2, out2, _ = run_cybervps_cmd(["session", "list"])
    active_sessions = out2.count("RUNNING")

    return {
        "hostname": hostname,
        "uptime": uptime_str,
        "services_running": running_svc,
        "services_total": total_svc,
        "sessions_active": active_sessions
    }


def send_heartbeat():
    """Generates and sends the heartbeat to all registered admin chats."""
    cfg = load_config()
    if not cfg.get("heartbeat_enabled", True):
        return

    admin_chats = cfg.get("admin_chat_ids", [])
    if not admin_chats:
        return

    now_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    mode = cfg.get("heartbeat_mode", "compact")
    interval = max(5, min(10, cfg.get("heartbeat_interval_minutes", 7)))

    if mode == "compact":
        msg = f"🟢 CyberVPS is online and active — {now_str}"
    else:
        info = get_system_summary()
        msg = (
            f"<b>🟢 CyberVPS ONLINE</b>\n\n"
            f"<b>Status:</b> Active\n"
            f"<b>Host:</b> {info['hostname']}\n"
            f"<b>Uptime:</b> {info['uptime']}\n"
            f"<b>CyberVPS Agent:</b> Running\n"
            f"<b>Services:</b> {info['services_running']}/{info['services_total']}\n"
            f"<b>Sessions:</b> {info['sessions_active']}\n"
            f"<b>Time:</b> {now_str}\n\n"
            f"<i>Next check: ~{interval} min</i>"
        )

    state = load_state()
    state["last_heartbeat_attempt"] = now_str
    success = False

    for chat_id in admin_chats:
        if send_message(chat_id, msg):
            success = True

    if success:
        state["last_heartbeat_success"] = now_str
        audit_log(0, "heartbeat_sent", mode, "PASS")
    else:
        audit_log(0, "heartbeat_failed", mode, "FAIL")

    save_state(state)


def heartbeat_worker():
    """Background scheduler for periodic heartbeat."""
    global RUNNING
    while RUNNING:
        cfg = load_config()
        interval_min = max(5, min(10, cfg.get("heartbeat_interval_minutes", 7)))
        sleep_sec = interval_min * 60

        # Sleep in small increments for quick shutdown response
        for _ in range(sleep_sec):
            if not RUNNING:
                break
            time.sleep(1)

        if RUNNING:
            try:
                send_heartbeat()
            except Exception as e:
                audit_log(0, "heartbeat_error", str(e), "ERROR")


# ==============================================================
# COMMAND HANDLERS
# ==============================================================

def main_keyboard():
    return {
        "inline_keyboard": [
            [{"text": "⚡ Services", "callback_data": "cmd_services"},
             {"text": "💻 Sessions", "callback_data": "cmd_sessions"}],
            [{"text": "🌐 Web Terminal", "callback_data": "cmd_webterm"},
             {"text": "🩺 Health", "callback_data": "cmd_health"}],
            [{"text": "💓 Heartbeat", "callback_data": "cmd_heartbeat"},
             {"text": "📊 Status", "callback_data": "cmd_status"}]
        ]
    }


def handle_update(update: dict):
    """Processes incoming Telegram updates."""
    global RUNNING
    msg = update.get("message")
    cb = update.get("callback_query")

    if cb:
        user_id = cb["from"]["id"]
        chat_id = cb["message"]["chat"]["id"]
        data = cb.get("data", "")
        handle_action(user_id, chat_id, data)
        # Acknowledge callback
        telegram_api("answerCallbackQuery", {"callback_query_id": cb["id"]})
        return

    if not msg:
        return

    user_id = msg["from"]["id"]
    chat_id = msg["chat"]["id"]
    text = msg.get("text", "").strip()

    cfg = load_config()
    admin_ids = cfg.get("admin_user_ids", [])
    admin_chats = cfg.get("admin_chat_ids", [])

    # Only locally allowlisted users can register a private chat.
    if text.startswith("/start"):
        if user_id in admin_ids and chat_id == user_id:
            if chat_id not in admin_chats:
                admin_chats.append(chat_id)
                cfg["admin_chat_ids"] = admin_chats
                save_config(cfg)
            send_message(chat_id, "<b>CyberVPS Control Center</b>\nChoose an action below:", main_keyboard())
            return
        else:
            send_message(chat_id, "<b>Access Denied.</b>\nYour user ID is not authorized to control this VPS.")
            audit_log(user_id, "unauthorized_access", text, "DENIED")
            return

    # Check authorization for all other commands
    if user_id not in admin_ids or chat_id != user_id:
        send_message(chat_id, "<b>Access Denied.</b>")
        audit_log(user_id, "unauthorized_command", text, "DENIED")
        return

    # Authorized commands dispatch
    parts = text.split()
    cmd = parts[0].lower() if parts else ""
    args = parts[1:]

    if cmd == "/help":
        help_text = (
            "<b>CyberVPS Commands:</b>\n"
            "/status — System & runtime status\n"
            "/health — Run system verification\n"
            "/services — List managed services\n"
            "/service &lt;name&gt; — Inspect service\n"
            "/startservice &lt;name&gt; — Start service\n"
            "/stopservice &lt;name&gt; — Stop service\n"
            "/restartservice &lt;name&gt; — Restart service\n"
            "/logs &lt;name&gt; — View service logs\n"
            "/sessions — List persistent terminals\n"
            "/session &lt;name&gt; — Inspect session\n"
            "/newterminal &lt;name&gt; — Create persistent terminal\n"
            "/stopterminal &lt;name&gt; — Stop terminal session\n"
            "/webterminal — Web terminal info & link\n"
            "/heartbeat — View/toggle heartbeat settings\n"
            "/heartbeat_on / /heartbeat_off\n"
            "/heartbeat_5 / /heartbeat_7 / /heartbeat_10\n"
            "/heartbeat_mode_compact / /heartbeat_mode_status"
        )
        send_message(chat_id, help_text)

    elif cmd == "/status":
        info = get_system_summary()
        res_text = (
            f"<b>📊 CyberVPS Status</b>\n"
            f"Host: <code>{info['hostname']}</code>\n"
            f"Uptime: <code>{info['uptime']}</code>\n"
            f"Services: <code>{info['services_running']}/{info['services_total']}</code>\n"
            f"Terminals: <code>{info['sessions_active']}</code>"
        )
        send_message(chat_id, res_text, main_keyboard())

    elif cmd == "/health":
        rc, out, _ = run_cybervps_cmd(["doctor"])
        send_message(chat_id, f"<b>🩺 Health Check:</b>\n<pre>{out[:3500]}</pre>")

    elif cmd == "/services":
        rc, out, _ = run_cybervps_cmd(["service", "list"])
        send_message(chat_id, f"<b>⚡ Services:</b>\n<pre>{out}</pre>")

    elif cmd in ("/startservice", "/stopservice", "/restartservice"):
        if not args:
            send_message(chat_id, f"Usage: {cmd} &lt;service_name&gt;")
            return
        action = cmd.replace("service", "").replace("/", "")
        rc, out, err = run_cybervps_cmd(["service", action, args[0]])
        audit_log(user_id, f"service_{action}", args[0], "PASS" if rc == 0 else "FAIL")
        send_message(chat_id, f"<b>Service {action} {args[0]}:</b>\n<pre>{out or err}</pre>")

    elif cmd == "/logs":
        if not args:
            send_message(chat_id, "Usage: /logs &lt;name&gt;")
            return
        rc, out, _ = run_cybervps_cmd(["service", "logs", args[0], "--lines", "30"])
        send_message(chat_id, f"<b>Logs for {args[0]}:</b>\n<pre>{out or 'No logs available'}</pre>")

    elif cmd == "/sessions":
        rc, out, _ = run_cybervps_cmd(["session", "list"])
        send_message(chat_id, f"<b>💻 Sessions:</b>\n<pre>{out}</pre>")

    elif cmd == "/newterminal":
        if not args:
            send_message(chat_id, "Usage: /newterminal &lt;name&gt;")
            return
        rc, out, err = run_cybervps_cmd(["session", "new", args[0]])
        audit_log(user_id, "session_new", args[0], "PASS" if rc == 0 else "FAIL")
        send_message(chat_id, f"<b>New Terminal {args[0]}:</b>\n<pre>{out or err}</pre>")

    elif cmd == "/stopterminal":
        if not args:
            send_message(chat_id, "Usage: /stopterminal &lt;name&gt;")
            return
        rc, out, err = run_cybervps_cmd(["session", "stop", args[0]])
        audit_log(user_id, "session_stop", args[0], "PASS" if rc == 0 else "FAIL")
        send_message(chat_id, f"<b>Stop Terminal {args[0]}:</b>\n<pre>{out or err}</pre>")

    elif cmd == "/webterminal":
        rc, out, _ = run_cybervps_cmd(["webterm", "status"])
        send_message(chat_id, f"<b>🌐 Web Terminal:</b>\n<pre>{out}</pre>")

    elif cmd == "/heartbeat":
        hb_on = "ENABLED" if cfg.get("heartbeat_enabled", True) else "DISABLED"
        interval = cfg.get("heartbeat_interval_minutes", 7)
        mode = cfg.get("heartbeat_mode", "compact")
        state = load_state()
        last_s = state.get("last_heartbeat_success", "Never")
        msg = (
            f"<b>💓 CyberVPS Heartbeat Status</b>\n\n"
            f"State: <b>{hb_on}</b>\n"
            f"Interval: <b>{interval} minutes</b>\n"
            f"Mode: <b>{mode}</b>\n"
            f"Last Sent: <code>{last_s}</code>\n\n"
            f"Commands to configure:\n"
            f"/heartbeat_on — /heartbeat_off\n"
            f"/heartbeat_5 — /heartbeat_7 — /heartbeat_10\n"
            f"/heartbeat_mode_compact — /heartbeat_mode_status"
        )
        send_message(chat_id, msg)

    elif cmd == "/heartbeat_on":
        cfg["heartbeat_enabled"] = True
        save_config(cfg)
        audit_log(user_id, "heartbeat_toggle", "enabled", "PASS")
        send_message(chat_id, "✅ Heartbeat <b>ENABLED</b>.")

    elif cmd == "/heartbeat_off":
        cfg["heartbeat_enabled"] = False
        save_config(cfg)
        audit_log(user_id, "heartbeat_toggle", "disabled", "PASS")
        send_message(chat_id, "⏸ Heartbeat <b>DISABLED</b>.")

    elif cmd in ("/heartbeat_5", "/heartbeat_7", "/heartbeat_10"):
        mins = int(cmd.split("_")[1])
        cfg["heartbeat_interval_minutes"] = mins
        save_config(cfg)
        audit_log(user_id, "heartbeat_interval", str(mins), "PASS")
        send_message(chat_id, f"⏱ Heartbeat interval set to <b>{mins} minutes</b>.")

    elif cmd == "/heartbeat_mode_compact":
        cfg["heartbeat_mode"] = "compact"
        save_config(cfg)
        audit_log(user_id, "heartbeat_mode", "compact", "PASS")
        send_message(chat_id, "📝 Heartbeat mode set to <b>compact</b>.")

    elif cmd == "/heartbeat_mode_status":
        cfg["heartbeat_mode"] = "message"
        save_config(cfg)
        audit_log(user_id, "heartbeat_mode", "status", "PASS")
        send_message(chat_id, "📊 Heartbeat mode set to <b>detailed status</b>.")


def handle_action(user_id: int, chat_id: int, action: str):
    """Handles inline button callbacks."""
    cfg = load_config()
    if user_id not in cfg.get("admin_user_ids", []):
        return

    if action == "cmd_services":
        rc, out, _ = run_cybervps_cmd(["service", "list"])
        send_message(chat_id, f"<b>⚡ Services:</b>\n<pre>{out}</pre>", main_keyboard())
    elif action == "cmd_sessions":
        rc, out, _ = run_cybervps_cmd(["session", "list"])
        send_message(chat_id, f"<b>💻 Sessions:</b>\n<pre>{out}</pre>", main_keyboard())
    elif action == "cmd_webterm":
        rc, out, _ = run_cybervps_cmd(["webterm", "status"])
        send_message(chat_id, f"<b>🌐 Web Terminal:</b>\n<pre>{out}</pre>", main_keyboard())
    elif action == "cmd_health":
        rc, out, _ = run_cybervps_cmd(["verify.sh"])
        send_message(chat_id, f"<b>🩺 Health:</b>\n<pre>{out[:3500]}</pre>", main_keyboard())
    elif action == "cmd_status":
        info = get_system_summary()
        res_text = (
            f"<b>📊 Status</b>\n"
            f"Host: <code>{info['hostname']}</code>\n"
            f"Uptime: <code>{info['uptime']}</code>\n"
            f"Services: <code>{info['services_running']}/{info['services_total']}</code>\n"
            f"Sessions: <code>{info['sessions_active']}</code>"
        )
        send_message(chat_id, res_text, main_keyboard())
    elif action == "cmd_heartbeat":
        send_heartbeat()
        send_message(chat_id, "💓 Test heartbeat dispatched.", main_keyboard())


def send_startup_notice():
    """Sends start notice once."""
    cfg = load_config()
    for chat_id in cfg.get("admin_chat_ids", []):
        hostname = os.uname().nodename if hasattr(os, "uname") else "linux-vps"
        interval = cfg.get("heartbeat_interval_minutes", 7)
        now_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        msg = (
            f"🟢 <b>CyberVPS Telegram Agent Started</b>\n\n"
            f"Host: <code>{hostname}</code>\n"
            f"Time: <code>{now_str}</code>\n"
            f"Heartbeat: every {interval} minutes"
        )
        send_message(chat_id, msg)


def send_shutdown_notice():
    """Best-effort graceful shutdown notification."""
    cfg = load_config()
    for chat_id in cfg.get("admin_chat_ids", []):
        hostname = os.uname().nodename if hasattr(os, "uname") else "linux-vps"
        msg = f"🔴 <b>CyberVPS Telegram Agent Stopping</b> on <code>{hostname}</code>"
        send_message(chat_id, msg)


def sig_handler(signum, frame):
    """Handles termination signals gracefully."""
    global RUNNING
    RUNNING = False
    try:
        send_shutdown_notice()
    except Exception:
        pass
    sys.exit(0)


def main():
    global RUNNING, LAST_UPDATE_ID, HEARTBEAT_THREAD

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    token = get_token()
    if not token:
        print(f"Error: Telegram bot token not found at {TOKEN_FILE}", file=sys.stderr)
        sys.exit(1)

    print("CyberVPS Telegram Agent starting...")
    send_startup_notice()

    # Start persistent heartbeat scheduler
    HEARTBEAT_THREAD = threading.Thread(target=heartbeat_worker, daemon=True)
    HEARTBEAT_THREAD.start()

    # Polling loop
    while RUNNING:
        try:
            params = {"timeout": 20, "offset": LAST_UPDATE_ID + 1}
            res = telegram_api("getUpdates", params)
            if res.get("ok"):
                for upd in res.get("result", []):
                    LAST_UPDATE_ID = max(LAST_UPDATE_ID, upd["update_id"])
                    handle_update(upd)
            else:
                time.sleep(3)
        except Exception as e:
            time.sleep(3)


if __name__ == "__main__":
    main()
