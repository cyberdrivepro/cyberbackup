# Security Policy

CyberVPS is designed with a strict **least-privilege, rootless, non-escalation** security philosophy. It is engineered to run securely in ordinary, unprivileged non-root user accounts on shared Linux VPS environments.

---

## 1. Core Security Guarantees

### Localhost-Only Service Binding
- **Strict Default:** All managed network listeners (Nginx, Redis, Supervisor, development application servers) bind exclusively to `127.0.0.1`.
- **No Unintentional Public Exposure:** CyberVPS never binds to `0.0.0.0` or exposes services to the public Internet unless an operator explicitly configures a public tunnel (such as Cloudflare Quick Tunnel) or configures a public reverse proxy with explicit intent.

### Zero Root / Sudo Escalation
- CyberVPS **never** runs `sudo`, `su`, or attempts privilege escalation.
- It **never** modifies system-wide configuration files (e.g. `/etc`, `/var`, `/usr`).
- It **never** requires or alters root-owned packages. All software and runtime dependencies are isolated within the user's `$HOME`.

### Provider Policy Compliance
- **No Process Disguises:** CyberVPS does not rename or disguise process binaries to evade provider restrictions.
- **No Watchdog Bypasses:** If a hosting provider enforces memory, process name, or execution limits, CyberVPS detects the restriction, logs the limitation, and disables or falls back gracefully without evasive behavior.

---

## 2. Secrets Management & Public Git Safety

### What Must NEVER Be Committed
This repository is public. The following files and patterns are strictly barred from version control:
- Plaintext `.env` and `.env.*` files
- Private SSH keys (`id_rsa`, `id_ed25519`, `*.key`)
- TLS/SSL private certificates (`*.pem`, `*.key`)
- Cloudflare API tokens and tunnel credential JSON files
- Rclone configurations containing access keys (`rclone.conf`)
- Database passwords and session authentication cookies
- API tokens (Slack, Telegram, GitHub, AWS, Google, etc.)
- Backup archive files (`*.tar.zst`, `*.tar.gz`, `*.zip`)

### Automated Secret Scanning
CyberVPS includes an automated scanner in `scripts/secret-check.sh`.
- Scans all tracked, staged, and candidate files before every Git commit and push.
- Verifies forbidden filenames and matching high-entropy token patterns.
- Reports matching line numbers **without printing sensitive secret values** into terminal output or logs.
- Commits are rejected if the scanner encounters candidate credentials.

### Encrypted Secrets Backup Model
For disaster recovery of sensitive configuration, CyberVPS offers an **optional encrypted secrets snapshot** (`--encrypt-secrets`):
- Uses OpenSSL AES-256-CBC with PBKDF2 key derivation (`openssl enc -aes-256-cbc -pbkdf2 -salt`).
- Prompts for a passphrase interactively via terminal stdin.
- The passphrase is **never stored, never cached, and never echoed into log files**.
- Encrypted secret archives are created with restrictive permissions (`chmod 0600`).

---

## 3. Integrity vs. Authenticity

### Understanding Checksums
- **Integrity:** CyberVPS computes SHA256 checksums for all backup archives and records them in `SHA256SUMS` and `latest.json`. SHA256 verification guarantees that an archive was not corrupted during transit, download, or storage.
- **Authenticity Disclaimer:** A SHA256 checksum detects bitrot and transfer errors, but is **not** cryptographic proof of origin or authenticity against a man-in-the-middle attacker if the checksum file itself is downloaded over an untrusted channel. Operators restoring backups from untrusted remotes should verify signatures using trusted keys (e.g., GPG or Minisign) where authenticity verification is required.

---

## 4. Reporting Security Vulnerabilities

If you discover a security issue or credential leak in CyberVPS, please report it privately:
- Email: **dev@cyberdrive.pro**
- Do **not** open a public GitHub issue for sensitive vulnerabilities.
- We will acknowledge receipt within 48 hours and work with you on a coordinated fix.
