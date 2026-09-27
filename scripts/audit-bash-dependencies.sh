#!/usr/bin/env bash
# scripts/audit-bash-dependencies.sh — Static Bash function dependency auditor wrapper
# Runs python-based static analysis to verify every function call has a definition.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v python3 >/dev/null 2>&1; then
    exec python3 "$SCRIPT_DIR/audit_bash_dependencies.py"
elif command -v python >/dev/null 2>&1; then
    exec python "$SCRIPT_DIR/audit_bash_dependencies.py"
else
    echo "python3 is required to run the function dependency audit"
    exit 1
fi
