#!/usr/bin/env bash
# tests/test-menu.sh — Test non-interactive menu rendering and exit
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

echo "Testing cybervps.sh menu display..."

# Run cybervps.sh non-interactively
OUT="$(bash "$REPO_DIR/cybervps.sh" </dev/null 2>&1)"

echo "$OUT" | grep -q "CyberVPS" || { echo "FAIL: CyberVPS title not found"; exit 1; }
echo "$OUT" | grep -q "Restore Backup" || { echo "FAIL: Restore option not found"; exit 1; }
echo "$OUT" | grep -q "Fresh Install" || { echo "FAIL: Fresh Install option not found"; exit 1; }
echo "$OUT" | grep -q "Migrate Backup" || { echo "FAIL: Migrate option not found"; exit 1; }
echo "$OUT" | grep -q "Create Backup" || { echo "FAIL: Create Backup option not found"; exit 1; }
echo "$OUT" | grep -q "Service Manager" || { echo "FAIL: Service Manager option not found"; exit 1; }
echo "$OUT" | grep -q "Persistent Terminals" || { echo "FAIL: Persistent Terminals option not found"; exit 1; }
echo "$OUT" | grep -q "Web Terminal" || { echo "FAIL: Web Terminal option not found"; exit 1; }
echo "$OUT" | grep -q "Telegram Bot" || { echo "FAIL: Telegram Bot option not found"; exit 1; }
echo "$OUT" | grep -q "Cloudflare Tunnels" || { echo "FAIL: Cloudflare Tunnels option not found"; exit 1; }
echo "$OUT" | grep -q "Background Jobs" || { echo "FAIL: Background Jobs option not found"; exit 1; }
echo "$OUT" | grep -q "VPS Health Verification" || { echo "FAIL: Verify option not found"; exit 1; }
echo "$OUT" | grep -q "CyberRoot" || { echo "FAIL: CyberRoot option not found"; exit 1; }

echo "PASS: test-menu.sh completed successfully."
exit 0
