# CyberVPS config

This directory holds configuration files used by the CyberVPS recovery system.

Configuration files:
- remote.conf: rclone remote configuration (NEVER commit with real credentials)
- micromamba-env.yml: micromamba environment manifest (may be committed if no secrets)
- micromamba-explicit.txt: explicit package list (may be committed)
- pip-freeze.txt: pip freeze (may be committed if no secrets)
- npm-global.txt: npm global packages (may be committed)
- node-version.txt: Node version manifest (may be committed)
- rust-version.txt: Rust version manifest (may be committed)
- cargo-installed.txt: cargo-installed tools (may be committed)
- go-version.txt: Go version manifest (may be committed)
- go-env.txt: Go environment variables (may be committed)
- ports.txt: ports manifest (may be committed)
- services.txt: services manifest (may be committed)
- system.txt: system manifest (may be committed if no secrets)
- files.txt: files manifest (may be committed)
- hosting24.conf: hosting flags (may be committed if generic)
- nginx.conf: nginx config (may be committed if no secrets)
- redis.conf: redis config (may be committed if no secrets)
- supervisor.conf: supervisor config (may be committed if no secrets)
- scheduler.conf: scheduler config (may be committed)
- cloudflare-quick-tunnel.sh: cloudflared helper (may be committed)
- .bashrc: shell config (may be committed if no secrets)
- .profile: profile (may be committed if no secrets)

Secrets (NEVER commit):
- .env files
- API tokens
- bot tokens
- SSH private keys
- Cloudflare credentials
- database passwords
- rclone credentials
- any encrypted secrets
