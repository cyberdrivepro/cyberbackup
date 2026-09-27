#!/usr/bin/env bash
# installers/python.sh — Standalone user-space Python environment installer
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"

USER_APPS_DIR="${HOME}/apps"
USER_BIN_DIR="${HOME}/bin"
ensure_directory "$USER_APPS_DIR"
ensure_directory "$USER_BIN_DIR"

log_header "Setting Up Python Environment"

# Check if host python3 with pip is already good
if have_command python3 && have_command pip3; then
    log_ok "System python3 and pip3 available ($(python3 --version 2>&1))"
    exit 0
fi

# Ensure micromamba is present
bash "$SCRIPT_DIR/micromamba.sh" || true

if have_command micromamba || [ -x "$USER_BIN_DIR/micromamba" ]; then
    MAMBA_BIN="$(command -v micromamba || echo "$USER_BIN_DIR/micromamba")"
    mamba_root="$USER_APPS_DIR/micromamba"
    env_name="${CYBERVPS_ENV_NAME:-hosting}"
    env_prefix="$mamba_root/envs/$env_name"

    if [ ! -d "$env_prefix" ] || [ ! -x "$env_prefix/bin/python" ]; then
        log_info "Creating Python 3.12 environment in Micromamba..."
        MAMBA_ROOT_PREFIX="$mamba_root" "$MAMBA_BIN" create -y -n "$env_name" \
            -c conda-forge python=3.12 pip setuptools wheel
    fi
    log_ok "Python environment ready at $env_prefix"
    exit 0
else
    log_error "Could not establish Python environment without micromamba."
    exit 1
fi
