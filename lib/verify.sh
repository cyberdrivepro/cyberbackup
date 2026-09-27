#!/usr/bin/env bash
# lib/verify.sh — Comprehensive health and compatibility verification engine for CyberVPS
# Inspects environment, runtimes, ports, services, resources, and backups.
# Supports terminal display and structured --json output.

[ -n "${_CYBERVPS_VERIFY_SH_LOADED:-}" ] && return 0
_CYBERVPS_VERIFY_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=lib/ports.sh
source "$LIB_DIR/ports.sh"
# shellcheck source=lib/services.sh
source "$LIB_DIR/services.sh"

run_cybervps_verification() {
    local opt_json="${1:-0}"

    detect_environment
    load_ports_env

    local total_pass=0
    local total_warn=0
    local total_fail=0
    local total_disabled=0
    local total_not_installed=0

    local results=()

    add_result() {
        local category="$1"
        local item="$2"
        local status="$3" # PASS, WARN, FAIL, DISABLED, NOT INSTALLED
        local detail="$4"

        case "$status" in
            PASS) total_pass=$((total_pass + 1)) ;;
            WARN) total_warn=$((total_warn + 1)) ;;
            FAIL) total_fail=$((total_fail + 1)) ;;
            DISABLED) total_disabled=$((total_disabled + 1)) ;;
            "NOT INSTALLED") total_not_installed=$((total_not_installed + 1)) ;;
        esac

        results+=("{\"category\": \"$category\", \"item\": \"$item\", \"status\": \"$status\", \"detail\": \"$detail\"}")
    }

    # 1. Environment checks
    if [ -w "$CYBER_HOME" ]; then
        add_result "Environment" "Home directory write access" "PASS" "$CYBER_HOME is writable"
    else
        add_result "Environment" "Home directory write access" "FAIL" "$CYBER_HOME is not writable"
    fi

    add_result "Environment" "Architecture" "PASS" "$CYBER_ARCH (kernel: $CYBER_KERNEL)"
    add_result "Environment" "Operating System" "PASS" "$CYBER_DISTRO_PRETTY"
    add_result "Environment" "C Library" "PASS" "$CYBER_LIBC $CYBER_LIBC_VERSION"

    # 2. Runtimes
    if have_command micromamba; then
        local mver
        mver="$(micromamba --version 2>/dev/null | head -1 || echo "installed")"
        add_result "Runtime" "Micromamba" "PASS" "$mver"
    elif [ -x "$HOME/bin/micromamba" ]; then
        add_result "Runtime" "Micromamba" "PASS" "$HOME/bin/micromamba"
    else
        add_result "Runtime" "Micromamba" "NOT INSTALLED" "Can be installed via option 2"
    fi

    if have_command python; then
        local pyver
        pyver="$(python --version 2>&1)"
        add_result "Runtime" "Python" "PASS" "$pyver"
    else
        add_result "Runtime" "Python" "WARN" "Python not found in current PATH"
    fi

    if have_command node; then
        local nver
        nver="$(node --version 2>&1)"
        add_result "Runtime" "Node.js" "PASS" "$nver"
    else
        add_result "Runtime" "Node.js" "NOT INSTALLED" "Node.js not in PATH"
    fi

    if have_command pm2; then
        add_result "Runtime" "PM2" "PASS" "Available ($(command -v pm2))"
    else
        add_result "Runtime" "PM2" "NOT INSTALLED" "PM2 not in PATH"
    fi

    if have_command rustc; then
        local rver
        rver="$(rustc --version 2>&1)"
        add_result "Runtime" "Rust" "PASS" "$rver"
    else
        add_result "Runtime" "Rust" "NOT INSTALLED" "Rust toolchain optional"
    fi

    if have_command go; then
        local gover
        gover="$(go version 2>&1)"
        add_result "Runtime" "Go" "PASS" "$gover"
    else
        add_result "Runtime" "Go" "NOT INSTALLED" "Go toolchain optional"
    fi

    if have_command cloudflared; then
        local cfver
        cfver="$(cloudflared --version 2>&1 | head -1 || echo "installed")"
        add_result "Runtime" "Cloudflared" "PASS" "$cfver"
    else
        add_result "Runtime" "Cloudflared" "NOT INSTALLED" "Cloudflared tunnel optional"
    fi

    # 3. Services & Persistence
    local backend
    backend="$(get_process_backend)"
    add_result "Services" "Process Backend" "PASS" "Using backend: $backend"

    # Redis check (optional / provider compliance)
    if [ "${CYBERVPS_CACHE_BACKEND:-auto}" = "disabled" ]; then
        add_result "Services" "Redis Cache" "DISABLED" "Explicitly disabled in configuration"
    elif have_command redis-server || [ -x "$HOME/apps/redis/bin/redis-server" ] || [ -x "$HOME/apps/redis/bin/rsrvd-h24" ]; then
        if is_service_running "redis"; then
            add_result "Services" "Redis Cache" "PASS" "Redis service is running"
        else
            add_result "Services" "Redis Cache" "PASS" "Redis binary available (not running)"
        fi
    else
        add_result "Services" "Redis Cache" "NOT INSTALLED" "Redis binary not found"
    fi

    # Web service check
    if have_command nginx || [ -x "$HOME/apps/micromamba/envs/hosting/bin/nginx" ] || [ -x "$HOME/apps/micromamba/envs/hosting/sbin/nginx" ]; then
        if is_service_running "nginx"; then
            add_result "Services" "Nginx Web Server" "PASS" "Nginx service is running"
        else
            add_result "Services" "Nginx Web Server" "PASS" "Nginx binary available"
        fi
    else
        add_result "Services" "Nginx Web Server" "NOT INSTALLED" "Nginx binary not found"
    fi

    # 4. Resources
    if [ "$CYBER_DISK_FREE_MB" != "unknown" ]; then
        if [ "$CYBER_DISK_FREE_MB" -gt 1024 ]; then
            add_result "Resources" "Disk Space" "PASS" "${CYBER_DISK_FREE_MB} MB free"
        else
            add_result "Resources" "Disk Space" "WARN" "Low disk space: ${CYBER_DISK_FREE_MB} MB free"
        fi
    fi

    if [ "$CYBER_RAM_AVAIL_MB" != "unknown" ]; then
        if [ "$CYBER_RAM_AVAIL_MB" -gt 256 ]; then
            add_result "Resources" "Memory" "PASS" "${CYBER_RAM_AVAIL_MB} MB available"
        else
            add_result "Resources" "Memory" "WARN" "Low available RAM: ${CYBER_RAM_AVAIL_MB} MB"
        fi
    fi

    # Output formatting
    if [ "$opt_json" -eq 1 ]; then
        printf '{\n  "overall_status": "%s",\n  "summary": {\n    "pass": %d,\n    "warn": %d,\n    "fail": %d,\n    "disabled": %d,\n    "not_installed": %d\n  },\n  "checks": [\n' \
            "$([ "$total_fail" -eq 0 ] && echo "PASS" || echo "FAIL")" "$total_pass" "$total_warn" "$total_fail" "$total_disabled" "$total_not_installed"
        local first=1
        for res in "${results[@]}"; do
            [ "$first" -eq 1 ] || printf ',\n'
            first=0
            printf '    %s' "$res"
        done
        printf '\n  ]\n}\n'
    else
        log_header "CyberVPS Verification Report"
        local current_cat=""
        for res in "${results[@]}"; do
            local cat item stat det
            cat="$(echo "$res" | grep -oE '"category": "[^"]+"' | cut -d'"' -f4)"
            item="$(echo "$res" | grep -oE '"item": "[^"]+"' | cut -d'"' -f4)"
            stat="$(echo "$res" | grep -oE '"status": "[^"]+"' | cut -d'"' -f4)"
            det="$(echo "$res" | grep -oE '"detail": "[^"]+"' | cut -d'"' -f4)"

            if [ "$cat" != "$current_cat" ]; then
                echo
                echo "[$cat]"
                current_cat="$cat"
            fi

            case "$stat" in
                PASS)
                    printf "  ${CLR_GREEN}[PASS]${CLR_RESET}          %-30s %s\n" "$item" "$det"
                    ;;
                WARN)
                    printf "  ${CLR_YELLOW}[WARN]${CLR_RESET}          %-30s %s\n" "$item" "$det"
                    ;;
                FAIL)
                    printf "  ${CLR_RED}[FAIL]${CLR_RESET}          %-30s %s\n" "$item" "$det"
                    ;;
                DISABLED)
                    printf "  ${CLR_CYAN}[DISABLED]${CLR_RESET}      %-30s %s\n" "$item" "$det"
                    ;;
                "NOT INSTALLED")
                    printf "  ${CLR_BLUE}[NOT INSTALLED]${CLR_RESET} %-30s %s\n" "$item" "$det"
                    ;;
            esac
        done

        echo
        echo "========================================"
        printf "Summary: %d Passed, %d Warnings, %d Failed, %d Optional/Not-Installed\n" \
            "$total_pass" "$total_warn" "$total_fail" "$((total_disabled + total_not_installed))"
        echo "========================================"
        if [ "$total_fail" -gt 0 ]; then
            log_error "Verification completed with failures."
            return 1
        else
            log_ok "System is healthy and ready."
            return 0
        fi
    fi
}
