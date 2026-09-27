#!/usr/bin/env bash
# installers/nginx.sh — Standalone user-space Nginx installer and rootless configurator
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
TMP_NGINX="${HOME}/tmp/nginx"

ensure_directory "$CONFIG_DIR"
ensure_directory "$RUN_DIR"
ensure_directory "$LOGS_DIR"
ensure_directory "$TMP_NGINX"

log_header "Checking / Configuring Rootless Nginx"

# 1. Check if nginx binary is available
if ! have_command nginx && [ ! -x "$USER_BIN_DIR/nginx" ]; then
    log_info "nginx not found; installing via Micromamba conda-forge..."
    bash "$SCRIPT_DIR/micromamba.sh" || true
    if have_command micromamba || [ -x "$USER_BIN_DIR/micromamba" ]; then
        MAMBA_BIN="$(command -v micromamba || echo "$USER_BIN_DIR/micromamba")"
        MAMBA_ROOT_PREFIX="$USER_APPS_DIR/micromamba" "$MAMBA_BIN" install -y -n "${CYBERVPS_ENV_NAME:-hosting}" -c conda-forge nginx || true
    fi
fi

# 2. Allocate or read rootless ports
http_port="$(reserve_or_select_port "HTTP_PORT" 8080)"
nginx_conf="$CONFIG_DIR/nginx.conf"

# Generate strictly rootless local-only nginx.conf
cat > "$nginx_conf" <<EOF
# CyberVPS Rootless Nginx Configuration
worker_processes 1;
pid $RUN_DIR/nginx.pid;
error_log $LOGS_DIR/nginx_error.log warn;

events {
    worker_connections 1024;
}

http {
    include mime.types;
    default_type application/octet-stream;
    access_log $LOGS_DIR/nginx_access.log;
    sendfile on;
    keepalive_timeout 65;

    client_body_temp_path $TMP_NGINX/client_body 1 2;
    proxy_temp_path $TMP_NGINX/proxy 1 2;
    fastcgi_temp_path $TMP_NGINX/fastcgi 1 2;
    uwsgi_temp_path $TMP_NGINX/uwsgi 1 2;
    scgi_temp_path $TMP_NGINX/scgi 1 2;

    server {
        listen 127.0.0.1:$http_port;
        server_name localhost;

        location / {
            root ${HOME}/projects/default/public;
            index index.html index.htm;
            try_files \$uri \$uri/ =404;
        }
    }
}
EOF

chmod 0600 "$nginx_conf"
log_ok "Rootless Nginx configuration generated at $nginx_conf (Port: $http_port)"
exit 0
