#!/usr/bin/env bash
# lib/execution.sh — Resilient Script Execution Engine for CyberVPS
# Invokes internal scripts via Bash directly, eliminating dependency on Git execute bits.
# Handles permission self-repair, filesystem execution inspection, and friendly exit codes.

[ -n "${_CYBERVPS_EXECUTION_SH_LOADED:-}" ] && return 0
_CYBERVPS_EXECUTION_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/logging.sh
source "$LIB_DIR/logging.sh"

CYBERVPS_ROOT="$(cd "$LIB_DIR/.." && pwd)"

# Check if a directory or file resides on a noexec mount
check_filesystem_noexec() {
    local target="${1:-$CYBERVPS_ROOT}"
    [ ! -e "$target" ] && target="$(dirname "$target")"
    [ ! -e "$target" ] && target="$HOME"

    if [ -r /proc/mounts ]; then
        # Find mountpoint for target
        local canonical_target
        canonical_target="$(cd "$target" 2>/dev/null && pwd -P || echo "$target")"

        local best_mp=""
        local best_len=0
        local is_noexec=0

        while IFS=' ' read -r _ mp _ opts _ _; do
            if [[ "$canonical_target" == "$mp"* ]] || [ "$mp" = "/" ]; then
                local len="${#mp}"
                if [ "$len" -ge "$best_len" ]; then
                    best_len="$len"
                    best_mp="$mp"
                    if [[ ",$opts," == *",noexec,"* ]]; then
                        is_noexec=1
                    else
                        is_noexec=0
                    fi
                fi
            fi
        done < /proc/mounts

        if [ "$is_noexec" -eq 1 ]; then
            log_debug "Mountpoint '$best_mp' for '$target' has noexec flag set"
            return 0 # is noexec
        fi
    fi
    return 1 # not noexec
}

# Interpret exit code into human-friendly explanation
interpret_exit_code() {
    local code="${1:-0}"
    case "$code" in
        0)
            echo "Success"
            ;;
        1)
            echo "General operation failure / check error log"
            ;;
        2)
            echo "Misuse of shell builtins or argument syntax error"
            ;;
        10)
            echo "Completed with warnings (all required components ready; optional components unavailable)"
            ;;
        126)
            echo "Execution denied (permission issue or restrictive mount policy)"
            ;;
        127)
            echo "Command or internal function not found (missing binary, script, or undefined function)"
            ;;
        130)
            echo "Operation cancelled by user (SIGINT / Ctrl+C)"
            ;;
        137)
            echo "Process killed by system (SIGKILL / likely Out-Of-Memory)"
            ;;
        143)
            echo "Process terminated by system (SIGTERM)"
            ;;
        *)
            if [ "$code" -gt 128 ]; then
                local sig=$((code - 128))
                echo "Terminated by fatal signal $sig"
            else
                echo "Operation failed with exit code $code"
            fi
            ;;
    esac
}

# Central resilient execution dispatcher
# Usage: run_cybervps_script SCRIPT_PATH [ARGS...]
run_cybervps_script() {
    local script_file="$1"
    shift

    # 1. Verification: Existence
    if [ ! -e "$script_file" ]; then
        log_error "CyberVPS execution error: Script not found: $script_file"
        return 127
    fi

    # 2. Verification: Regular file
    if [ ! -f "$script_file" ]; then
        log_error "CyberVPS execution error: Target is not a regular file: $script_file"
        return 126
    fi

    # 3. Path canonicalization & repository boundary check
    local script_dir
    script_dir="$(cd "$(dirname "$script_file")" 2>/dev/null && pwd -P || true)"
    local canonical_script="${script_dir}/$(basename "$script_file")"
    local canonical_root
    canonical_root="$(cd "$CYBERVPS_ROOT" 2>/dev/null && pwd -P || echo "$CYBERVPS_ROOT")"

    if [[ "$canonical_script" != "$canonical_root"* ]] && [[ "$canonical_script" != "$HOME"* ]] && [[ "$canonical_script" != "/tmp"* ]]; then
        log_error "CyberVPS execution error: Script outside authorized tree ($canonical_script)"
        return 126
    fi

    # 4. Check readability & attempt safe user-owned permission repair
    if [ ! -r "$canonical_script" ]; then
        if [ -O "$canonical_script" ]; then
            log_warn "Script is unreadable; attempting safe user-owned chmod u+r..."
            chmod u+r "$canonical_script" 2>/dev/null || true
        fi
        if [ ! -r "$canonical_script" ]; then
            log_error "CyberVPS execution error: Script is not readable: $canonical_script"
            return 126
        fi
    fi

    # 5. Check if user owns file and can opportunistically ensure +x
    # Note: We NEVER depend on +x because we dispatch via bash, but we keep file modes clean
    if [ -O "$canonical_script" ] && [ ! -x "$canonical_script" ]; then
        chmod u+x "$canonical_script" 2>/dev/null || true
    fi

    # 6. Execute safely through Bash interpreter
    # This completely bypasses missing execute bits or restrictive noexec mounts for scripts
    log_debug "Dispatching script via Bash: $canonical_script $*"

    local exit_code=0
    bash "$canonical_script" "$@" || exit_code=$?

    log_debug "Script '$canonical_script' exited with code: $exit_code"
    return "$exit_code"
}
