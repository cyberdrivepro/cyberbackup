#!/usr/bin/env bash
# restore.sh — CyberVPS restore CLI entry point
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/restore.sh
source "$SCRIPT_DIR/lib/restore.sh"

ARCHIVE_PATH=""
DRY_RUN=0
FORCE_REBUILD=0

show_usage() {
    cat << EOF
CyberVPS Restore CLI
Usage: $(basename "$0") [options] [archive_path]

Options:
  --archive <path>     Path to the backup archive to restore
  --dry-run            Simulate restore process without modifying files
  --force-rebuild      Force recreation of user-space environments
  -h, --help           Show this help message
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --archive)
            ARCHIVE_PATH="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --force-rebuild)
            FORCE_REBUILD=1
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            if [ -z "$ARCHIVE_PATH" ] && [ -f "$1" ]; then
                ARCHIVE_PATH="$1"
                shift
            else
                log_error "Unknown option: $1"
                show_usage
                exit 1
            fi
            ;;
    esac
done

if [ -z "$ARCHIVE_PATH" ]; then
    ARCHIVE_PATH="$(find_backup_archive "$SCRIPT_DIR/downloads" 2>/dev/null || true)"
fi

if [ -z "$ARCHIVE_PATH" ] || [ ! -f "$ARCHIVE_PATH" ]; then
    log_error "No backup archive found in $SCRIPT_DIR/downloads. Please specify --archive <path>"
    exit 1
fi

acquire_lock "restore" || exit 1
trap 'release_lock' EXIT

restore_cybervps_backup "$ARCHIVE_PATH" "$DRY_RUN" "$FORCE_REBUILD"
exit 0
