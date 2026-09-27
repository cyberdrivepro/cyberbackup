#!/usr/bin/env bash
# installers/redis.sh — Standalone user-space Redis server installer and rootless configurator
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=lib/ports.sh
source "$LIB_DIR/ports.sh"

USER_APPS_DIR="${HOME}/apps"
USER_BIN_DIR="${HOME}/bin"
CONFIG_DIR="${HOME}/config"
RUN_DIR="${HOME}/run"
LOGS_DIR="${HOME}/logs"

ensure_directory "$CONFIG_DIR"
ensure_directory "$RUN_DIR"
ensure_directory "$LOGS_DIR"

log_header "Checking / Configuring Rootless Redis"

# 1. Check if redis-server is available
if ! have_command redis-server && [ ! -x "$USER_BIN_DIR/redis-server" ]; then
    log_info "redis-server not found; installing via Micromamba conda-forge..."
    bash "$SCRIPT_DIR/micromamba.sh" || true
    if have_command micromamba || [ -x "$USER_BIN_DIR/micromamba" ]; then
        MAMBA_BIN="$(command -v micromamba || echo "$USER_BIN_DIR/micromamba")"
        MAMBA_ROOT_PREFIX="$USER_APPS_DIR/micromamba" "$MAMBA_BIN" install -y -n "${CYBERVPS_ENV_NAME:-hosting}" -c conda-forge redis || true
    fi
fi

# 2. Allocate or read rootless Redis port
redis_port="$(reserve_or_select_port "REDIS_PORT" 6380)"
redis_conf="$CONFIG_DIR/redis.conf"

# Generate strictly rootless local-only redis.conf
cat > "$redis_conf" <<EOF
# CyberVPS Rootless Redis Configuration
bind 127.0.0.1
port $redis_port
daemonize yes
pidfile $RUN_DIR/redis.pid
logfile $LOGS_DIR/redis.log
dir $RUN_DIR
databases 16
save 900 1
save 300 10
rdbcompression yes
dbfilename dump.rdb
appendonly no
maxmemory 256mb
maxmemory-policy allkeys-lru
EOF

chmod 0600 "$redis_conf"
log_ok "Rootless Redis configuration generated at $redis_conf (Port: $redis_port)"
exit 0
