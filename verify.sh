#!/usr/bin/env bash
# verify.sh — verify CyberVPS environment health
set -euo pipefail

CYBERBACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$CYBERBACKUP_DIR"

LOG="$CYBERBACKUP_DIR/logs/verify.log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
bold='\033[1m'
reset='\033[0m'
ok()      { echo -e "${green}✔${reset} $*"; }
warn()    { echo -e "${yellow}⚠${reset} $*"; }
err()     { echo -e "${red}✖${reset} $*"; }
header()  { echo -e "\n${bold}$*${reset}\n"; }

FAIL=0
check_pass() { ok "$@"; }
check_fail() { err "$@"; FAIL=1; }

export PATH="$HOME/bin:$HOME/apps/micromamba/envs/hosting/bin:$HOME/.cargo/bin:$HOME/go/bin:$HOME/apps/go/bin:$PATH"

header "CYBER VPS VERIFICATION"
echo "Host: $(hostname)"
echo "User: $(whoami)"
echo

# Micromamba
if command -v micromamba >/dev/null 2>&1; then
    check_pass "micromamba: available ($(micromamba --version 2>/dev/null | head -1))"
else
    check_fail "micromamba: not found"
fi

# Hosting environment
if [ -d "$HOME/apps/micromamba/envs/hosting" ]; then
    check_pass "hosting environment: present"
else
    check_fail "hosting environment: missing"
fi

# Python
if command -v python >/dev/null 2>&1; then
    check_pass "python: $(python --version 2>&1)"
else
    check_fail "python: not found"
fi

# pip
if python -m pip --version >/dev/null 2>&1; then
    check_pass "pip: $(python -m pip --version 2>/dev/null | cut -d' ' -f1-2)"
else
    check_fail "pip: not found"
fi

# Node
if command -v node >/dev/null 2>&1; then
    check_pass "node: $(node --version 2>/dev/null)"
else
    check_fail "node: not found"
fi

# npm
if command -v npm >/dev/null 2>&1; then
    check_pass "npm: $(npm --version 2>/dev/null)"
else
    check_fail "npm: not found"
fi

# pnpm
if command -v pnpm >/dev/null 2>&1; then
    check_pass "pnpm: $(pnpm --version 2>/dev/null)"
else
    check_fail "pnpm: not found"
fi

# PM2
if command -v pm2 >/dev/null 2>&1 && pm2 ping >/dev/null 2>&1; then
    check_pass "pm2: daemon running"
else
    check_fail "pm2: daemon not running"
fi

# Rust
if command -v rustc >/dev/null 2>&1; then
    check_pass "rustc: $(rustc --version 2>/dev/null)"
else
    check_fail "rustc: not found"
fi

# Cargo
if command -v cargo >/dev/null 2>&1; then
    check_pass "cargo: $(cargo --version 2>/dev/null)"
else
    check_fail "cargo: not found"
fi

# Go
if command -v go >/dev/null 2>&1; then
    check_pass "go: $(go version 2>/dev/null)"
else
    check_fail "go: not found"
fi

# Git
if command -v git >/dev/null 2>&1; then
    check_pass "git: $(git --version 2>/dev/null)"
else
    check_fail "git: not found"
fi

# SQLite
if command -v sqlite3 >/dev/null 2>&1; then
    check_pass "sqlite3: $(sqlite3 --version 2>/dev/null | cut -d' ' -f1-2)"
else
    check_fail "sqlite3: not found"
fi

# Redis user service
if command -v redis-cli >/dev/null 2>&1 && redis-cli -h 127.0.0.1 -p 6380 ping >/dev/null 2>&1 | grep -q PONG; then
    check_pass "redis (6380): PONG"
else
    check_fail "redis (6380): not responding"
fi

# nginx
if curl -fs -m 3 http://127.0.0.1:8080/health >/dev/null 2>&1; then
    check_pass "nginx (8080): HTTP OK"
else
    check_fail "nginx (8080): HTTP failed"
fi

# Supervisor
if [ -f "$HOME/run/svcd-h24.pid" ] && kill -0 "$(cat "$HOME/run/svcd-h24.pid" 2>/dev/null)" 2>/dev/null; then
    check_pass "supervisor (svcd-h24): running"
else
    check_fail "supervisor (svcd-h24): not running"
fi

# PM2 status
if pm2 ping >/dev/null 2>&1; then
    check_pass "pm2: UP"
else
    check_fail "pm2: DOWN"
fi

# tmux hosting24
if tmux has-session -t hosting24 >/dev/null 2>&1; then
    check_pass "tmux hosting24: RUNNING"
else
    check_fail "tmux hosting24: NOT RUNNING"
fi

# Disk
avail_kb=$(df "$HOME" | awk 'NR==2{print $4}')
if [ "${avail_kb:-0}" -gt 1048576 ]; then
    check_pass "disk free: ${avail_kb}KB"
else
    check_fail "disk low: ${avail_kb}KB free"
fi

# Memory
mem_avail=$(free -m | awk '/^Mem:/{print $7}')
if [ "${mem_avail:-0}" -gt 200 ]; then
    check_pass "memory available: ${mem_avail}MB"
else
    check_fail "memory low: ${mem_avail}MB"
fi

# Configured example APIs
if command -v python >/dev/null 2>&1 && python -c "import socket; s=socket.socket(); s.settimeout(0.3); exit(0 if s.connect_ex(('127.0.0.1',8000))==0 else 1)" 2>/dev/null; then
    if curl -fs -m 3 http://127.0.0.1:8000/health >/dev/null 2>&1; then
        check_pass "api :8000: responding"
    else
        check_fail "api :8000: not responding"
    fi
else
    warn "api :8000: not listening (optional)"
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo -e "\n${green}==============================${reset}"
    echo -e "${green}  RESULT: ALL CHECKS PASSED   ${reset}"
    echo -e "${green}==============================${reset}"
else
    echo -e "\n${red}==============================${reset}"
    echo -e "${red}  RESULT: FAILURES PRESENT     ${reset}"
    echo -e "${red}==============================${reset}"
fi

exit "$FAIL"
