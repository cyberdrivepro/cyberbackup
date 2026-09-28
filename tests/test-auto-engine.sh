#!/usr/bin/env bash
# tests/test-auto-engine.sh — Automated tests for CyberVPS Ultra Auto & PRoot Engine
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

MOCK_ROOT="$(mktemp -d /tmp/cybervps-test-auto-XXXXXX)"
ORIG_HOME="$HOME"
export HOME="$MOCK_ROOT"
export XDG_STATE_HOME="$MOCK_ROOT/.local/state"
export XDG_CONFIG_HOME="$MOCK_ROOT/.config"
export XDG_DATA_HOME="$MOCK_ROOT/.local/share"
mkdir -p "$MOCK_ROOT/.local/bin"
export PATH="$MOCK_ROOT/.local/bin:$PATH"

cleanup() {
    rm -rf "$MOCK_ROOT"
}
trap cleanup EXIT

# shellcheck source=lib/auto.sh
source "$REPO_DIR/lib/auto.sh"

echo "=== Testing Auto-Scan & Decision Matrix ==="
cyber_auto_scan
echo "Detected Mode: $CYBER_AUTO_MODE"
echo "Detected Reason: $CYBER_AUTO_REASON"
case "$CYBER_AUTO_MODE" in
    NATIVE_ROOT|PROOT_GUEST|CYBERROOT_USERNS|WSL_BRIDGE|WINDOWS_NATIVE)
        echo "✔ PASS: Recognized valid mode ($CYBER_AUTO_MODE)"
        ;;
    *)
        echo "FAIL: Unexpected auto mode: $CYBER_AUTO_MODE"
        exit 1
        ;;
esac

echo "=== Testing Architecture Mapping ==="
arch="$(cyber_proot_arch)"
echo "Mapped arch: $arch"
case "$arch" in
    x86_64|aarch64|arm|i386)
        echo "✔ PASS: Architecture normalized cleanly"
        ;;
    *)
        echo "FAIL: Unknown normalized architecture: $arch"
        exit 1
        ;;
esac

echo "=== Testing Guest Filesystem Setup ==="
guest_test_dir="$MOCK_ROOT/test_guest"
cyber_guest_setup_fs "$guest_test_dir"
test -f "$guest_test_dir/etc/resolv.conf"
grep -q "1.1.1.1" "$guest_test_dir/etc/resolv.conf"
test -f "$guest_test_dir/etc/hosts"
grep -q "cybervps" "$guest_test_dir/etc/hosts"
test -f "$guest_test_dir/etc/apt/apt.conf.d/99cybervps"
grep -q "Install-Recommends" "$guest_test_dir/etc/apt/apt.conf.d/99cybervps"
test -f "$guest_test_dir/root/.bashrc"
echo "✔ PASS: Guest filesystem scaffolding and network configurations verified"

echo "=== Testing Shell Integration Idempotency ==="
mock_rc="$MOCK_ROOT/.bashrc"
touch "$mock_rc"
cyber_auto_setup_shell_integration
grep -q "CyberVPS Ultra Integration" "$mock_rc"
first_count="$(grep -c "CyberVPS Ultra Integration" "$mock_rc")"

# Running second time must be idempotent
cyber_auto_setup_shell_integration
second_count="$(grep -c "CyberVPS Ultra Integration" "$mock_rc")"
[ "$first_count" -eq "$second_count" ]
echo "✔ PASS: Shell integration is idempotent (hook count: $second_count)"

echo "=== Testing PRoot Binary Resolution Override ==="
mock_proot="$MOCK_ROOT/.local/bin/mock_proot"
cat > "$mock_proot" << 'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ] || [ "${1:-}" = "--help" ]; then
    echo "proot version 5.4.0"
    exit 0
fi
exit 0
EOF
chmod 0755 "$mock_proot"
export CYBERVPS_PROOT_BIN="$mock_proot"
found_bin="$(cyber_proot_find_bin)"
[ "$found_bin" = "$mock_proot" ]
cyber_proot_test_bin "$found_bin"
echo "✔ PASS: PRoot binary resolution and validation operational"

echo "ALL AUTO-ENGINE TESTS PASSED"
exit 0
