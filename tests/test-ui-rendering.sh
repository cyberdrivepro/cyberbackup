#!/usr/bin/env bash
# tests/test-ui-rendering.sh — Validate CyberVPS Ultra modern CYBER DARK UI components
# Tests responsive layout across widths (60, 80, 120), ANSI stripping, ASCII fallback, and NO_COLOR.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

# shellcheck source=lib/ui.sh
source "$REPO_DIR/lib/ui.sh"

echo "=== Testing UI Width Detection & Responsive Modes ==="
mode_60="$(COLUMNS=60 ui_layout_mode)"
mode_80="$(COLUMNS=80 ui_layout_mode)"
mode_120="$(COLUMNS=120 ui_layout_mode)"

[ "$mode_60" = "COMPACT" ] || { echo "FAIL: 60 columns should be COMPACT, got $mode_60"; exit 1; }
[ "$mode_80" = "NORMAL" ] || { echo "FAIL: 80 columns should be NORMAL, got $mode_80"; exit 1; }
[ "$mode_120" = "WIDE" ] || { echo "FAIL: 120 columns should be WIDE, got $mode_120"; exit 1; }
echo "✔ PASS: Responsive mode classification verified (COMPACT, NORMAL, WIDE)"

echo "=== Testing ANSI Stripping & Visible Length ==="
colored_sample="${C_PRIMARY}CYBER${C_TEXT}VPS${C_RESET} ${C_ACCENT}[ ULTRA ]${C_RESET}"
stripped="$(ui_strip_ansi "$colored_sample")"
[ "$stripped" = "CYBERVPS [ ULTRA ]" ] || { echo "FAIL: Strip ANSI failed, got '$stripped'"; exit 1; }

vis_len="$(ui_visible_length "$colored_sample")"
[ "$vis_len" -eq 18 ] || { echo "FAIL: Visible length expected 18, got $vis_len"; exit 1; }
echo "✔ PASS: ANSI stripping and visible length accurate"

echo "=== Testing Safe Truncation ==="
long_text="very_long_hostname_that_exceeds_limits.cybervps.internal"
trunc_text="$(ui_truncate "$long_text" 20 "...")"
[ "$(ui_visible_length "$trunc_text")" -eq 20 ] || { echo "FAIL: Truncated text length mismatch"; exit 1; }
[[ "$trunc_text" =~ \.\.\.$ ]] || { echo "FAIL: Truncated text should end in ..."; exit 1; }
echo "✔ PASS: Safe truncation verified"

echo "=== Testing Dashboard Rendering at Width 60 (Compact) ==="
out_compact="$(COLUMNS=60 bash "$REPO_DIR/cybervps.sh" </dev/null 2>&1)"
echo "$out_compact" | grep -q "CYBERVPS ULTRA" || { echo "FAIL: Header logo not found in compact"; exit 1; }
echo "$out_compact" | grep -q "Restore Backup" || { echo "FAIL: Restore Backup not found in compact"; exit 1; }
echo "$out_compact" | grep -q "Service Manager" || { echo "FAIL: Service Manager not found in compact"; exit 1; }
echo "✔ PASS: Dashboard rendered cleanly at width 60"

echo "=== Testing Dashboard Rendering at Width 80 (Normal) ==="
out_normal="$(COLUMNS=80 bash "$REPO_DIR/cybervps.sh" </dev/null 2>&1)"
echo "$out_normal" | grep -q "CYBERVPS ULTRA" || { echo "FAIL: Header logo not found in normal"; exit 1; }
echo "$out_normal" | grep -q "Cloudflare Tunnels" || { echo "FAIL: Cloudflare Tunnels not found in normal"; exit 1; }
echo "$out_normal" | grep -q "CyberRoot" || { echo "FAIL: CyberRoot not found in normal"; exit 1; }
echo "✔ PASS: Dashboard rendered cleanly at width 80"

echo "=== Testing Dashboard Rendering at Width 120 (Wide 2x2 Grid) ==="
out_wide="$(COLUMNS=120 bash "$REPO_DIR/cybervps.sh" </dev/null 2>&1)"
echo "$out_wide" | grep -q "CYBERVPS ULTRA" || { echo "FAIL: Header logo not found in wide"; exit 1; }
echo "$out_wide" | grep -q "QUICK ACTIONS" || { echo "FAIL: QUICK ACTIONS panel not found in wide"; exit 1; }
echo "$out_wide" | grep -q "HOSTING" || { echo "FAIL: HOSTING panel not found in wide"; exit 1; }
echo "$out_wide" | grep -q "SYSTEM" || { echo "FAIL: SYSTEM panel not found in wide"; exit 1; }
echo "$out_wide" | grep -q "MANAGEMENT" || { echo "FAIL: MANAGEMENT panel not found in wide"; exit 1; }
echo "✔ PASS: Dashboard rendered cleanly at width 120 (2x2 grid)"

echo "=== Testing ASCII Fallback Mode ==="
out_ascii="$(CYBERVPS_ASCII=1 COLUMNS=80 bash "$REPO_DIR/cybervps.sh" </dev/null 2>&1)"
# In ASCII mode, box corners should be '+'
echo "$out_ascii" | grep -q "+" || { echo "FAIL: Expected '+' ASCII box corners in ASCII mode"; exit 1; }
echo "$out_ascii" | grep -q "CYBERVPS ULTRA" || { echo "FAIL: Header logo not found in ASCII mode"; exit 1; }
echo "✔ PASS: ASCII fallback mode verified"

echo "=== Testing NO_COLOR Compliance ==="
out_nocolor="$(NO_COLOR=1 bash "$REPO_DIR/cybervps.sh" </dev/null 2>&1)"
# Check for raw escape code \033[
if printf '%s' "$out_nocolor" | grep -q $'\033\\['; then
    echo "FAIL: Raw ANSI escape sequences found when NO_COLOR=1"
    exit 1
fi
echo "✔ PASS: NO_COLOR=1 produces clean unescaped text"

echo "=== Testing Specialized Screens Rendering ==="
# Test Auto Install Screen
out_auto="$(COLUMNS=80 ui_auto_install_screen 2>&1)"
echo "$out_auto" | grep -q "CYBERVPS ULTRA AUTO DEPLOYMENT" || { echo "FAIL: Auto install screen failed"; exit 1; }
echo "$out_auto" | grep -q "ULTRA FULL" || { echo "FAIL: Level 4 not found"; exit 1; }

# Test Status Card
out_status="$(COLUMNS=80 ui_status_card 2>&1)"
echo "$out_status" | grep -q "HEALTHY" || { echo "FAIL: Status card failed"; exit 1; }

# Test Doctor View
out_doctor="$(COLUMNS=80 ui_doctor_view 2>&1)"
echo "$out_doctor" | grep -q "CyberVPS Doctor" || { echo "FAIL: Doctor view failed"; exit 1; }
echo "$out_doctor" | grep -q "SYSTEM" || { echo "FAIL: System section in doctor missing"; exit 1; }

# Test Fatal Error Card
out_err="$(COLUMNS=80 ui_fatal_error_card "ERR-TEST" "TestComp" "Simulated failure" "/tmp/test.log" "cybervps doctor" 2>&1)"
echo "$out_err" | grep -q "CYBERVPS ERROR" || { echo "FAIL: Error card title missing"; exit 1; }
echo "$out_err" | grep -q "ERR-TEST" || { echo "FAIL: Error code missing"; exit 1; }

# Test Success Card
out_succ="$(COLUMNS=80 ui_success_card "4" 2>&1)"
echo "$out_succ" | grep -q "INSTALLATION COMPLETE" || { echo "FAIL: Success card failed"; exit 1; }

echo "✔ PASS: All specialized UI cards rendered cleanly"

echo "ALL UI RENDERING TESTS PASSED"
exit 0
