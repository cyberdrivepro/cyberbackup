#!/usr/bin/env bash
# backup-now.sh — CyberVPS automated backup CLI entry point
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/backup.sh
source "$SCRIPT_DIR/lib/backup.sh"

INCLUDE_SHARED="${CYBERVPS_INCLUDE_SHARED:-0}"
ENCRYPT_SECRETS=0
DRY_RUN=0
VERBOSE=0

show_usage() {
    cat << EOF
CyberVPS Backup CLI
Usage: $(basename "$0") [options]

Options:
  --include-shared     Include ~/shared in a separate archive
  --encrypt-secrets    Create an encrypted archive of secrets using OpenSSL
  --dry-run            Simulate backup without creating archive
  --verbose            Enable debug logging
  -h, --help           Show this help message
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --include-shared)
            INCLUDE_SHARED=1
            shift
            ;;
        --encrypt-secrets)
            ENCRYPT_SECRETS=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --verbose)
            VERBOSE=1
            export CYBERVPS_LOG_LEVEL="debug"
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

# Acquire user-space lock
acquire_lock "backup" || exit 1
trap 'release_lock' EXIT

create_cybervps_backup "$INCLUDE_SHARED" "$ENCRYPT_SECRETS" "$DRY_RUN" "$SCRIPT_DIR/downloads"

log_ok "Backup process finished."
exit 0
