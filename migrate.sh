#!/usr/bin/env bash
# migrate.sh — CyberVPS cross-host migration CLI entry point
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/migration.sh
source "$SCRIPT_DIR/lib/migration.sh"

ARCHIVE_PATH=""
DRY_RUN=0

show_usage() {
    cat << EOF
CyberVPS Migration CLI
Usage: $(basename "$0") [options] [archive_path]

Options:
  --archive <path>     Path to the backup archive to migrate
  --dry-run            Simulate migration and show planned adaptations
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
    log_error "No backup archive found to migrate. Please specify --archive <path>"
    exit 1
fi

acquire_lock "migration" || exit 1
trap 'release_lock' EXIT

execute_vps_migration "$ARCHIVE_PATH" "$DRY_RUN"
exit 0
