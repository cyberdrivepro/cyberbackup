#!/usr/bin/env bash
# scripts/secret-check.sh — Scan repository files for credentials and forbidden artifacts
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'

FOUND=0

PATTERNS=(
    'BEGIN[[:space:]]+(RSA|DSA|EC|OPENSSH|PGP)[[:space:]]+PRIVATE[[:space:]]+KEY'
    'github_pat_[a-zA-Z0-9_]{36,}'
    'ghp_[a-zA-Z0-9]{36}'
    'gho_[a-zA-Z0-9]{36}'
    'glpat-[a-zA-Z0-9\-_]{20,}'
    'xox[baprs]-[0-9]{10,13}-[0-9]{10,13}[a-zA-Z0-9]*'
    'AIza[0-9A-Za-z\-_]{35}'
    'AKIA[0-9A-Z]{16}'
    'ey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
    'password[[:space:]]*=[[:space:]]*["'"'"'][^"'"'"']{6,}["'"'"']'
    'secret[[:space:]]*=[[:space:]]*["'"'"'][^"'"'"']{6,}["'"'"']'
    'token[[:space:]]*=[[:space:]]*["'"'"'][a-zA-Z0-9_\-]{12,}["'"'"']'
    'api_key[[:space:]]*=[[:space:]]*["'"'"'][a-zA-Z0-9_\-]{12,}["'"'"']'
    'api_secret[[:space:]]*=[[:space:]]*["'"'"'][a-zA-Z0-9_\-]{12,}["'"'"']'
    '[0-9]{8,10}:AA[a-zA-Z0-9_-]{33,35}'
)

FORBIDDEN_FILES=(
    ".env"
    "remote.conf"
    "rclone.conf"
    "id_rsa"
    "id_ed25519"
    "latest.json"
    "SHA256SUMS"
)

echo "=== CyberVPS Secret Scanner ==="

# Check staged and tracked files
FILES=$(git ls-files 2>/dev/null || true)
STAGED=$(git diff --name-only --cached 2>/dev/null || true)
CANDIDATES=$(printf "%s\n%s\n" "$FILES" "$STAGED" | sort -u | grep -v '^$' || true)

if [ -z "$CANDIDATES" ]; then
    CANDIDATES=$(find . -maxdepth 3 -type f -not -path './.git/*' -not -path './logs/*' -not -path './downloads/*' -not -path './payload/staging/*')
fi

for file in $CANDIDATES; do
    fname=$(basename "$file")
    for fbd in "${FORBIDDEN_FILES[@]}"; do
        if [ "$fname" = "$fbd" ] || [[ "$fname" == *.tar.* ]] || [[ "$fname" == *.tar ]]; then
            echo -e "${RED}[FAIL]${RESET} Forbidden file detected for commit: $file"
            FOUND=1
        fi
    done

    # Skip checking secret-check.sh itself for its own pattern definitions
    if [[ "$file" == *"secret-check.sh"* ]]; then
        continue
    fi

    if [ -f "$file" ]; then
        for pat in "${PATTERNS[@]}"; do
            matches=$(grep -Eni "$pat" "$file" 2>/dev/null || true)
            if [ -n "$matches" ]; then
                line_nums=$(echo "$matches" | cut -d: -f1 | tr '\n' ' ')
                echo -e "${RED}[FAIL]${RESET} Secret pattern matched in $file at line(s): $line_nums"
                FOUND=1
            fi
        done
    fi
done

if [ "$FOUND" -ne 0 ]; then
    echo -e "${RED}❌ Secret scan failed! Resolve sensitive items before committing/pushing.${RESET}"
    exit 1
fi

echo -e "${GREEN}✔ Secret scan passed: No secrets or restricted files detected.${RESET}"
exit 0
