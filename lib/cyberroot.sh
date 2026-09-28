#!/usr/bin/env bash
# lib/cyberroot.sh — CyberVPS CyberRoot Rootless Runtime Integration
# Provides interactive management of user-space rootless Linux containers
set -uo pipefail

# Ensure ~/.local/bin is in PATH
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"

find_cyberroot_bin() {
    if command -v cyberroot >/dev/null 2>&1; then
        command -v cyberroot
        return 0
    fi
    if [ -x "$HOME/.local/bin/cyberroot" ]; then
        echo "$HOME/.local/bin/cyberroot"
        return 0
    fi
    if [ -x "$HOME/cyberroot/target/release/cyberroot" ]; then
        echo "$HOME/cyberroot/target/release/cyberroot"
        return 0
    fi
    return 1
}

handle_cyberroot_menu() {
    while true; do
        clear 2>/dev/null || echo
        ui_header
        echo -e "${C_BCYAN}=== CyberRoot — Rootless Linux Runtime ===${C_RESET}"
        echo -e "${C_DIM}Completely user-space isolated rootfs environments (UID 0 virtual identity)${C_RESET}"
        echo

        local cr_bin
        if cr_bin="$(find_cyberroot_bin)"; then
            local cr_ver
            cr_ver="$("$cr_bin" --version 2>/dev/null || echo "v0.1.0")"
            echo -e "  ${C_BGREEN}● CyberRoot Status:${C_RESET} Installed (${cr_ver}) at ${cr_bin}"
            echo
            ui_menu_section "RUNTIME ACTIONS" \
                "[1] Run CyberRoot Doctor (Diagnostics & Capabilities)" \
                "[2] List Installed Rootless Guests" \
                "[3] Enter Interactive Guest Shell" \
                "[4] Install Linux Distribution (Ubuntu / Debian)" \
                "[5] Snapshot & Restore Manager" \
                "[6] Garbage Collection & State Cleanup" \
                "[7] Remote SSH Server (Direct Virtual-Root on Port 8022)" \
                "[0] Return to Main Menu"
        else
            echo -e "  ${C_BYELLOW}● CyberRoot Status:${C_RESET} Not installed in PATH or ~/.local/bin"
            echo
            ui_menu_section "INSTALLATION" \
                "[1] Build & Install CyberRoot Runtime" \
                "[2] Run Diagnostics (Doctor)" \
                "[0] Return to Main Menu"
        fi

        echo
        local choice=""
        if ! read -rp "Enter Selection: " choice; then
            break
        fi

        case "$choice" in
            1)
                if cr_bin="$(find_cyberroot_bin)"; then
                    echo
                    "$cr_bin" doctor
                    echo
                    read -rp "Press Enter to continue..." _
                else
                    echo
                    echo -e "${C_BCYAN}Building and installing CyberRoot...${C_RESET}"
                    if [ -d "$HOME/cyberroot" ]; then
                        (cd "$HOME/cyberroot" && cargo build --release && mkdir -p "$HOME/.local/bin" && cp target/release/cyberroot "$HOME/.local/bin/" && chmod +x "$HOME/.local/bin/cyberroot")
                        echo -e "${C_BGREEN}CyberRoot built and installed successfully to ~/.local/bin/cyberroot!${C_RESET}"
                    else
                        echo -e "${C_BRED}Source directory $HOME/cyberroot not found.${C_RESET}"
                    fi
                    echo
                    read -rp "Press Enter to continue..." _
                fi
                ;;
            2)
                if cr_bin="$(find_cyberroot_bin)"; then
                    echo
                    "$cr_bin" list
                    echo
                    read -rp "Press Enter to continue..." _
                else
                    echo
                    echo "CyberRoot is not yet installed."
                    read -rp "Press Enter to continue..." _
                fi
                ;;
            3)
                if cr_bin="$(find_cyberroot_bin)"; then
                    echo
                    "$cr_bin" list
                    echo
                    local target_guest=""
                    read -rp "Enter guest name to enter (or press Enter for default): " target_guest
                    if [ -n "$target_guest" ]; then
                        "$cr_bin" enter "$target_guest" || true
                    else
                        "$cr_bin" enter || true
                    fi
                    echo
                    read -rp "Press Enter to continue..." _
                fi
                ;;
            4)
                if cr_bin="$(find_cyberroot_bin)"; then
                    echo
                    echo -e "${C_BWHITE}Available distributions:${C_RESET} ubuntu, debian"
                    local distro_choice=""
                    read -rp "Select distro [ubuntu]: " distro_choice
                    distro_choice="${distro_choice:-ubuntu}"
                    local guest_name=""
                    read -rp "Enter name for this guest [$distro_choice]: " guest_name
                    guest_name="${guest_name:-$distro_choice}"
                    echo
                    "$cr_bin" install "$distro_choice" --name "$guest_name"
                    echo
                    read -rp "Press Enter to continue..." _
                fi
                ;;
            5)
                if cr_bin="$(find_cyberroot_bin)"; then
                    echo
                    "$cr_bin" list
                    echo
                    local guest_name=""
                    read -rp "Enter guest name to inspect snapshots: " guest_name
                    if [ -n "$guest_name" ]; then
                        "$cr_bin" snapshots "$guest_name"
                    fi
                    echo
                    read -rp "Press Enter to continue..." _
                fi
                ;;
            6)
                if cr_bin="$(find_cyberroot_bin)"; then
                    echo
                    "$cr_bin" gc
                    echo
                    read -rp "Press Enter to continue..." _
                fi
                ;;
            7)
                if cr_bin="$(find_cyberroot_bin)"; then
                    echo
                    "$cr_bin" list
                    echo
                    local guest_name=""
                    read -rp "Enter guest name for remote SSH server [testbox]: " guest_name
                    guest_name="${guest_name:-testbox}"
                    echo
                    echo "  [1] Start Remote SSH Server (Port 8022)"
                    echo "  [2] Check Remote SSH Status"
                    echo "  [3] Stop Remote SSH Server"
                    local r_action=""
                    read -rp "Select action [1]: " r_action
                    r_action="${r_action:-1}"
                    case "$r_action" in
                        1) "$cr_bin" remote start "$guest_name" --port 8022 ;;
                        2) "$cr_bin" remote status "$guest_name" ;;
                        3) "$cr_bin" remote stop "$guest_name" ;;
                    esac
                    echo
                    read -rp "Press Enter to continue..." _
                fi
                ;;
            0|*)
                break
                ;;
        esac
    done
}
