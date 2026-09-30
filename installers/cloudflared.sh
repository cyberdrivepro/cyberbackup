#!/usr/bin/env bash
# Compatibility entrypoint; use the shared capability-aware installer.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install.sh
source "$SCRIPT_DIR/../lib/install.sh"
install_resolve_mode "${CYBERVPS_INSTALL_MODE:-rootless}"
ensure_user_paths
install_component cloudflared
