#!/usr/bin/env bash
# scripts/root-command-guard.sh — High-Performance Prohibited Root Command Scanner
# Enforces absolute rootless policy: scans scripts for any invocation of sudo, su,
# apt/apt-get/dnf/yum/pacman package installations in executable code paths.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="${1:-$REPO_DIR}"

echo "=== CyberVPS Root Command Guard ==="
echo "Scanning for prohibited root commands under: $TARGET_DIR"

VIOLATIONS=0
PATTERN='^[[:space:]]*(sudo[[:space:]]+|su[[:space:]]+-[[:space:]]+|su[[:space:]]+root|(apt|apt-get|dnf|yum)[[:space:]]+install|pacman[[:space:]]+-S)'

while IFS= read -r file; do
    [ -f "$file" ] || continue
    # Skip test files and markdown docs from code enforcement
    [[ "$file" == *"/tests/"* ]] && continue
    [[ "$file" == *"/docs/"* ]] && continue

    matches="$(grep -nE "$PATTERN" "$file" 2>/dev/null || true)"
    if [ -n "$matches" ]; then
        echo "✖ PROHIBITED ROOT COMMAND FOUND:"
        echo "  File: $file"
        echo "$matches" | sed 's/^/    /'
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
done < <(find "$TARGET_DIR" -not -path '*/.*' -type f -name "*.sh" 2>/dev/null)

if [ "$VIOLATIONS" -gt 0 ]; then
    echo
    echo "✖ FAILED: $VIOLATIONS file(s) containing prohibited root commands detected!"
    echo "CyberVPS is strictly rootless. Do NOT invoke sudo, su, or system package managers."
    exit 1
fi

echo "✔ Root command scan passed: Zero prohibited root commands found in codebase."
exit 0
