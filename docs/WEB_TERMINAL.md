# CyberVPS Authenticated Web Terminal

CyberVPS includes an authenticated, high-performance browser terminal powered by `ttyd`. It allows full interactive terminal administration directly from any web browser without needing local SSH clients installed on the connecting device.

---

## 1. Security Architecture

Exposing an unauthenticated shell to the internet creates an immediate security vulnerability. CyberVPS enforces strict defense-in-depth measures:

1. **Loopback Binding Only**: The web terminal process is strictly bound to `127.0.0.1:<PORT>` (default: `7681`). It is never exposed directly on public network interfaces (`0.0.0.0`).
2. **Mandatory Authentication**: `ttyd` runs with `--credential <username>:<password>`. Unauthenticated requests receive HTTP 401 Unauthorized responses.
3. **Protected Credential Storage**: Web terminal credentials are stored in `~/.config/cybervps/webterm/auth.env` with strict file permissions (`0600`).
4. **Encrypted Transport**: Remote browser connections must traverse an encrypted tunnel (Cloudflare Tunnel with HTTPS) or an encrypted SSH local port forward (`ssh -L 7681:127.0.0.1:7681`).

---

## 2. Installation & Prerequisites

CyberVPS includes a rootless installer for `ttyd`:

```bash
# Automated user-space installer for ttyd
bash installers/ttyd.sh
```

The installer downloads the statically-linked `ttyd` binary directly into `$HOME/.local/bin/ttyd` without requiring `apt` or `sudo`.

---

## 3. CLI Usage

```bash
# Set or update the web terminal login credentials
cybervps webterm set-password admin MySecretPassword123!

# Start the web terminal service (bound to 127.0.0.1:7681)
cybervps webterm start

# Check web terminal status, listening port, and connection details
cybervps webterm status

# View web terminal daemon logs
cybervps webterm logs 50

# Stop the web terminal
cybervps webterm stop
```

---

## 4. Remote Browser Access

### Option A: Via Cloudflare Tunnel (Recommended)
Launch a quick encrypted HTTPS tunnel to expose the web terminal securely:
```bash
cybervps tunnel quick 7681
cybervps tunnel url
```
Open the returned HTTPS URL in any web browser and log in with your configured credentials.

### Option B: Via SSH Port Forwarding
From your client laptop or machine:
```bash
ssh -L 7681:127.0.0.1:7681 user@vps-host
```
Then navigate to `http://localhost:7681` in your browser.
