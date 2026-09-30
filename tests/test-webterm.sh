#!/usr/bin/env bash
# tests/test-webterm.sh — Automated tests for CyberVPS authenticated web terminal
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

ORIG_PATH="$PATH"
MOCK_ROOT="$(mktemp -d /tmp/cybervps-test-webterm-XXXXXX)"
export HOME="$MOCK_ROOT"
export XDG_CONFIG_HOME="$MOCK_ROOT/.config"
export XDG_STATE_HOME="$MOCK_ROOT/.local/state"
export PATH="$MOCK_ROOT/.local/bin:$ORIG_PATH"

mkdir -p "$MOCK_ROOT/.local/bin"
if ! command -v ttyd >/dev/null 2>&1; then
    cat > "$MOCK_ROOT/.local/bin/ttyd" << 'EOF'
#!/usr/bin/env python3
import base64, http.server, socketserver, sys
bind = "127.0.0.1"
port = 7681
cred = ""
args = sys.argv[1:]
i = 0
while i < len(args):
    if args[i] == '-i' and i + 1 < len(args):
        bind = args[i+1]; i += 2
    elif args[i] == '-p' and i + 1 < len(args):
        port = int(args[i+1]); i += 2
    elif args[i] == '-c' and not cred and i + 1 < len(args):
        cred = args[i+1]; i += 2
    elif not args[i].startswith('-'):
        break
    else:
        i += 1
expected_auth = "Basic " + base64.b64encode(cred.encode()).decode() if cred else ""
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        auth_header = self.headers.get('Authorization', '')
        if expected_auth and auth_header != expected_auth:
            self.send_response(401)
            self.send_header('WWW-Authenticate', 'Basic realm="ttyd"')
            self.end_headers()
            self.wfile.write(b'Unauthorized')
        else:
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'OK')
    def log_message(self, format, *args):
        pass
class ReusableServer(socketserver.TCPServer):
    allow_reuse_address = True
with ReusableServer((bind, port), Handler) as httpd:
    httpd.serve_forever()
EOF
    chmod 0755 "$MOCK_ROOT/.local/bin/ttyd"
fi

# shellcheck source=lib/webterm.sh
source "$REPO_DIR/lib/webterm.sh"

cleanup() {
    webterm_stop 2>/dev/null || true
    session_stop "test-webterm-sess" 2>/dev/null || true
    rm -rf "$MOCK_ROOT"
}
trap cleanup EXIT

echo "=== Testing Web Terminal Auth Generation ==="
webterm_ensure_auth
test -f "$XDG_CONFIG_HOME/cybervps/webterm/auth.env"
# shellcheck source=/dev/null
source "$XDG_CONFIG_HOME/cybervps/webterm/auth.env"
[ -n "$WEBTERM_USER" ]
[ -n "$WEBTERM_PASS" ]
echo "✔ PASS: Web terminal credentials generated"

echo "=== Testing Web Terminal Stopped State ==="
! webterm_is_running
status_out="$(webterm_status || true)"
echo "$status_out" | grep -q "STOPPED"
echo "✔ PASS: Initial stopped state"

echo "=== Testing Web Terminal Start ==="
webterm_start "test-webterm-sess"
webterm_is_running
session_is_alive "test-webterm-sess"
echo "✔ PASS: Web terminal started and session attached"

echo "=== Testing Web Terminal Localhost Bind & Auth Check ==="
meta_file="$XDG_STATE_HOME/cybervps/webterm/current.json"
test -f "$meta_file"
bind_ip="$(grep -o '"bind": *"[^"]*"' "$meta_file" | cut -d'"' -f4)"
port="$(grep -o '"port": *[0-9]*' "$meta_file" | grep -o '[0-9]*')"
[ "$bind_ip" = "127.0.0.1" ]
echo "✔ PASS: Localhost 127.0.0.1 bind verified"

# Test HTTP connection if curl available
if have_command curl; then
    # Unauthenticated request should fail / challenge (401)
    http_code="$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${port}/" || true)"
    [ "$http_code" = "401" ]
    echo "✔ PASS: Unauthenticated access rejected with 401"

    # Authenticated request should succeed
    auth_code="$(curl -s -o /dev/null -w "%{http_code}" -u "${WEBTERM_USER}:${WEBTERM_PASS}" "http://127.0.0.1:${port}/" || true)"
    [ "$auth_code" = "200" ]
    echo "✔ PASS: Authenticated access succeeds with 200"
fi

echo "=== Testing Web Terminal Stop ==="
webterm_stop
! webterm_is_running
# Underlying tmux session MUST survive webterm stop
session_is_alive "test-webterm-sess"
echo "✔ PASS: Web terminal stopped while persistent session survived"

session_stop "test-webterm-sess"
echo "All web terminal tests passed!"
exit 0
