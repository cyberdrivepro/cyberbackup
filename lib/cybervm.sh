#!/usr/bin/env bash
# Optional QEMU control; Python uses argv execution and private JSON state.
cybervm_cli() {
    local script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd) || return 8
    command -v python3 >/dev/null 2>&1 || { printf 'CyberVM requires Python 3; optional feature unavailable.\n' >&2; return 3; }
    python3 "$script_dir/cybervm.py" "$@"
}
