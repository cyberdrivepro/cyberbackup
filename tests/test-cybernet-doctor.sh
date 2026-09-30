#!/usr/bin/env bash
# tests/test-cybernet-doctor.sh — Phase 3 CyberNet Diagnostics Doctor Tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"

log_header "Testing Phase 3 CyberNet Diagnostics Doctor"

PYTHONPATH="$REPO_DIR" python3 - << 'EOF'
from fleet.doctor import CyberNetDoctor

results = CyberNetDoctor.run_all()
assert len(results) >= 6, f"Expected at least 6 diagnostic checks, got {len(results)}"

check_names = [r["name"] for r in results]
assert "UDP Capability" in check_names, "Missing UDP capability check"
assert "DNS Resolution" in check_names, "Missing DNS resolution check"
assert "Clock Sync" in check_names, "Missing Clock Sync check"

for r in results:
    assert r["status"] in ("PASS", "WARN", "FAIL", "SKIP"), f"Invalid status: {r['status']}"
    assert len(r["detail"]) > 0, f"Detail should not be empty for {r['name']}"
    print(f"[{r['status']}] {r['name']}: {r['detail']}")

print("OK: CyberNetDoctor diagnostic checks verified")
EOF

# Test CLI execution
PYTHONPATH="$REPO_DIR" python3 -m fleet.cli net doctor

log_ok "All Phase 3 CyberNet Doctor tests passed successfully!"
