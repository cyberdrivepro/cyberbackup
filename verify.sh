#!/usr/bin/env bash
# verify.sh — CyberVPS health and environment verification CLI entry point
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/verify.sh
source "$SCRIPT_DIR/lib/verify.sh"

OPT_JSON=0

show_usage() {
    cat << EOF
CyberVPS Verification CLI
Usage: $(basename "$0") [options]

Options:
  --json       Output structured machine-readable JSON
  -h, --help   Show this help message
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --json)
            OPT_JSON=1
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

run_cybervps_verification "$OPT_JSON"
