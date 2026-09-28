# CyberVPS Security Architecture

CyberVPS is engineered from the ground up for zero-privilege, rootless Linux hosting and remote operations. It provides robust operational capabilities without violating host isolation policies or escalating privileges.

---

## 1. Zero-Privilege Foundation

- **Zero Root / Sudo**: CyberVPS never requests `sudo`, never executes `su`, and never alters system directories (`/etc`, `/usr`, `/var`, `/lib`).
- **No Privilege Escalation**: CyberVPS does not attempt kernel exploits, namespace escapes, or system daemon tampering.
- **Provider Compliance**: Fully compliant with restricted cloud environments, shared VPS hosts, containerized workspaces (Kasm, Docker rootless), and educational servers.

---

## 2. Credential Isolation & Access Control

1. **Storage Outside Git**:
   - All sensitive credentials (bot tokens, tunnel configs, web terminal credentials) are stored exclusively in `$HOME/.config/cybervps/` (or `$XDG_CONFIG_HOME/cybervps/`).
   - All sensitive files are set to mode `0600` (readable and writable only by the owning user).
   - `.gitignore` explicitly excludes all configuration files, tokens, and archive payloads.
2. **Automated Secret Scanner**:
   - `scripts/secret-check.sh` scans staged and tracked files for private keys, cloud tokens, API keys, and passwords before every commit.
3. **Log Sanitization**:
   - Service commands, background jobs, and Telegram handlers sanitize authentication tokens and credentials from log buffers before emitting output.

---

## 3. Network & Transport Security

- **Loopback Binding**: Services intended for private or authenticated access (such as `ttyd`) bind strictly to `127.0.0.1` rather than public interfaces (`0.0.0.0`).
- **Encrypted Remote Tunnels**: External connections utilize end-to-end TLS tunnels (Cloudflare Tunnel) or SSH port forwards. No unauthenticated plaintext ports are exposed to public networks.
- **Strict Telegram Authorization**: The Telegram remote administration agent filters all incoming messages against the configured `ADMIN_USER_IDS` whitelist. Commands from unauthorized users are immediately rejected and logged.
