# CyberVPS Persistent Terminal Sessions

The CyberVPS Persistent Session Manager provides interactive and long-running shell workspaces that persist across SSH client disconnections, network interruptions, and laptop closures.

---

## 1. Overview & Architecture

When an interactive SSH connection terminates, the kernel sends a `SIGHUP` (Hangup) signal to all processes attached to the controlling terminal session. Without terminal multiplexing, active tasks (builds, compilations, interactive shells, training scripts) are terminated immediately.

CyberVPS isolates interactive and background tasks inside isolated terminal multiplexer instances:
1. **Isolated Namespaces**: Multiplexer sessions are prefixed with `cybervps-` (e.g., `cybervps-build`, `cybervps-workspace`) to prevent collisions with user sessions.
2. **Backend Fallbacks**:
   - `tmux` (Primary): Full pane management, window detachment, history buffers, and ANSI color support.
   - `screen` (Secondary): Fallback multiplexer when tmux is absent.
   - `nohup` / `disown` (Tertiary): Fallback execution layer when no multiplexer binary is available.
3. **Session Metadata**: Active sessions record their creation time, PID, backend, and state in `$XDG_STATE_HOME/cybervps/sessions/<name>.json`.

---

## 2. CLI Usage

### Starting and Attaching to Sessions

```bash
# Launch a new persistent shell session
cybervps session new workspace

# Launch a new persistent session executing a specific command
cybervps session new build-job "cargo build --release"

# Attach to an existing session
cybervps session attach workspace

# Detach from a session without stopping it:
# Press: Ctrl+B then D (in tmux) or Ctrl+A then D (in screen)
```

### Inspecting and Managing Sessions

```bash
# List all active persistent sessions
cybervps session list

# View detailed status and metadata for a session
cybervps session info workspace

# Inspect the latest terminal output buffer of a session
cybervps session logs workspace 50

# Rename an existing session
cybervps session rename workspace old-workspace

# Stop / kill a persistent session
cybervps session stop old-workspace

# Clean dead or orphaned session state files
cybervps session clean
```

### Running Commands Inside Sessions

```bash
# Execute a shell command inside a named persistent session
cybervps session exec workspace "date && uptime"
```
