# CyberVPS Remote Tunnels

CyberVPS includes native integration with Cloudflare Tunnels (`cloudflared`) to expose local web terminals and applications to the internet without requiring public IPv4 addresses, router port-forwarding, or open inbound firewall ports.

---

## 1. Overview & Architecture

Many cloud hosts and restricted environments sit behind carrier-grade NAT (CGNAT), strict ingress firewall rules, or container isolation boundaries (e.g., Kasm workspaces) where inbound traffic is blocked.

Cloudflare Tunnels resolve this by initiating an *outbound* encrypted connection to Cloudflare edge networks:
- **No Inbound Ports**: The VPS never listens on external network interfaces.
- **TLS Termination**: Cloudflare automatically terminates SSL/TLS with valid certificates.
- **DDoS Protection**: Edge-layer DDoS mitigation and authentication policies can be applied.

---

## 2. Modes of Operation

### Quick Tunnel Mode (`trycloudflare.com`)
- **No account required**: Instantly generates an ephemeral `*.trycloudflare.com` HTTPS URL.
- **Ideal for**: Rapid remote terminal access, temporary demos, and quick debugging sessions.

### Named Tunnel Mode (Cloudflare Zero Trust)
- **Persistent Domain**: Maps a permanent custom domain (e.g., `term.mycompany.com`) to the local port.
- **Enterprise Security**: Integrate with Cloudflare Access (SSO, Google OAuth, GitHub login).
- **Configuration**: Uses a tunnel token stored in `~/.config/cybervps/tunnel/token.env`.

---

## 3. CLI Usage

```bash
# Start a quick tunnel forwarding to local web terminal (default port 7681)
cybervps tunnel quick 7681

# Retrieve the assigned public HTTPS tunnel URL
cybervps tunnel url

# Inspect tunnel status and process metrics
cybervps tunnel status

# View cloudflared daemon logs
cybervps tunnel logs 50

# Stop the active tunnel
cybervps tunnel stop
```

---

## 4. Rootless Installation of `cloudflared`

If `cloudflared` is not pre-installed on the host, install the standalone binary directly into user space:

```bash
mkdir -p "$HOME/.local/bin"
curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o "$HOME/.local/bin/cloudflared"
chmod +x "$HOME/.local/bin/cloudflared"
```
