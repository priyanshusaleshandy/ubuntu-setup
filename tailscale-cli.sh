#!/usr/bin/env bash
# ==============================================================================
# TAILSCALE MANAGEMENT CLI — Ubuntu / Linux Edition
# ==============================================================================
# Single interactive dashboard for Tailscale on Ubuntu:
#   [1] Tailscale Login    — Headscale (bifrost.saleshandy.com) / Official Cloud / Auth Key
#   [2] Diagnostics        — Status, IP, Netcheck, Ping, Service Health
#   [3] Switch Account     — Interactive account / profile switcher
#   [4] Exit Node Setup    — Enable / Disable Office Exit Nodes & Routing Fix
#   [5] Quick Actions      — Connect, Disconnect, Reset, Logout
#   [0] Exit
#
# Usage:
#   chmod +x tailscale-cli.sh
#   ./tailscale-cli.sh
# ==============================================================================

set -uo pipefail

# ── Self-relaunch (fixes FAT32/exFAT pendrive noexec issue & syncs updates) ───
SAFE_DIR="$HOME/.local/share/tailscale-cli"
SAFE_SCRIPT="$SAFE_DIR/tailscale-cli.sh"
THIS_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
if [[ "$THIS_SCRIPT" != "$SAFE_SCRIPT" ]]; then
    mkdir -p "$SAFE_DIR" 2>/dev/null
    if ! cmp -s "$THIS_SCRIPT" "$SAFE_SCRIPT" 2>/dev/null; then
        cp -f "$THIS_SCRIPT" "$SAFE_SCRIPT" 2>/dev/null
        chmod +x "$SAFE_SCRIPT" 2>/dev/null
    fi
    exec bash "$SAFE_SCRIPT" "$@"
fi

# ── Colors & Logging ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[INFO]${NC}    $1"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}      $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $1"; }
log_section() { echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}"; }

press_enter() { echo ""; read -rp "  Press Enter to return to menu..." _ < /dev/tty; }

# ── Configuration Defaults ────────────────────────────────────────────────────
HEADSCALE_SERVER="https://bifrost.saleshandy.com"
NTFY_SERVER="http://192.168.126.101:8080"
NTFY_ADMIN_CHANNEL="priyanshu-setup"

# ── Root Guard ────────────────────────────────────────────────────────────────
if [[ "$EUID" -eq 0 ]]; then
    log_error "Do NOT run this script as root. Run as a normal user."
    log_error "The script will use sudo when needed."
    exit 1
fi

# ── Sudo Keep-Alive ───────────────────────────────────────────────────────────
log_info "Acquiring sudo privileges..."
sudo -v
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT

# ── Ensure Tailscale Installed ────────────────────────────────────────────────
ensure_tailscale_installed() {
    if ! command -v tailscale &>/dev/null; then
        log_warn "Tailscale CLI is not installed!"
        read -rp "  Would you like to install Tailscale now via official script? (Y/n): " instChoice < /dev/tty
        if [[ "${instChoice:-y}" =~ ^[Yy]$ ]]; then
            log_info "Installing Tailscale..."
            curl -fsSL https://tailscale.com/install.sh | sh
            sudo systemctl enable --now tailscaled
            log_ok "Tailscale installed successfully!"
        else
            log_error "Tailscale is required for this tool."
            return 1
        fi
    fi
    return 0
}

ensure_tailscale_service() {
    ensure_tailscale_installed || return 1
    if ! systemctl is-active tailscaled &>/dev/null; then
        log_info "Starting tailscaled daemon..."
        sudo systemctl start tailscaled || sudo systemctl restart tailscaled
    fi
    # Self-healing socket check
    if ! sudo tailscale status &>/dev/null; then
        log_warn "Tailscaled daemon is not responding. Restarting service..."
        sudo systemctl restart tailscaled 2>/dev/null || true
        sleep 1
    fi
}

# ── Full tailscaled Repair ────────────────────────────────────────────────────
# Fixes: "Job for tailscaled.service failed because of unavailable resources
#         or another system error." — root cause is usually a missing
#         /etc/default/tailscaled defaults file, which the systemd unit
#         requires to even attempt starting the daemon.
repair_tailscaled_service() {
    log_section "REPAIRING TAILSCALED SYSTEMD CONFIGURATION"

    # 1. Ensure expected directories exist
    sudo mkdir -p /etc/default /var/lib/tailscale /run/tailscale /var/cache/tailscale

    # 2. Recreate the defaults file if missing
    if [[ ! -f /etc/default/tailscaled ]]; then
        log_info "Creating missing /etc/default/tailscaled"
        sudo tee /etc/default/tailscaled >/dev/null <<'EOF'
# Tailscale daemon defaults
PORT="41641"
FLAGS=""
EOF
    fi
    sudo chmod 0644 /etc/default/tailscaled

    # 3. Reinstall the binary if it's missing
    if [[ ! -x /usr/sbin/tailscaled ]]; then
        log_warn "tailscaled binary missing; reinstalling package..."
        sudo apt-get update
        sudo apt-get install --reinstall -y tailscale
    fi

    # 4. Clear systemd rate-limit lockout
    sudo systemctl daemon-reload
    sudo systemctl reset-failed tailscaled.service 2>/dev/null || true

    # 5. Start
    log_info "Starting tailscaled..."
    sudo systemctl enable tailscaled
    sudo systemctl start tailscaled
    sleep 3

    # 6. Verify
    if systemctl is-active --quiet tailscaled; then
        log_ok "tailscaled is running."
        tailscale version
        echo ""
        log_info "Starting login..."
        sudo tailscale login --login-server="${HEADSCALE_SERVER}"
    else
        log_error "tailscaled still failed to start."
        echo ""
        sudo systemctl status tailscaled --no-pager -l
        echo ""
        log_info "--- Last 100 log lines ---"
        sudo journalctl -u tailscaled --no-pager -n 100
    fi
}

# ── Kernel Routing & System Optimization Fixes ────────────────────────────────
apply_kernel_routing_fixes() {
    log_info "Applying Ubuntu sysctl Kernel Routing & IP Forwarding fixes..."
    sudo sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true

    # Persist via dedicated sysctl.d file (cleaner & persistent across reboots)
    cat << 'EOF' | sudo tee /etc/sysctl.d/99-tailscale-routing.conf >/dev/null
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sudo sysctl -p /etc/sysctl.d/99-tailscale-routing.conf >/dev/null 2>&1 || true
    log_ok "Kernel routing rules (rp_filter=2, IP forward=1) active and persisted to /etc/sysctl.d/99-tailscale-routing.conf!"
}

# ── [1] Tailscale Login Submenu ───────────────────────────────────────────────
menu_login() {
    while true; do
        clear
        echo -e "${CYAN}${BOLD}=== [1] TAILSCALE LOGIN & AUTHENTICATION ===${NC}\n"
        echo -e "  Current Server Target : ${YELLOW}${HEADSCALE_SERVER}${NC}\n"
        echo -e "  [1] Login to Saleshandy Headscale  (Auto-send login link to Admin Ntfy)"
        echo -e "  [2] Login via Auth Key            (tskey-auth-... or Headscale key)"
        echo -e "  [3] Login to Official Cloud        (controlserver.tailscale.com)"
        echo -e "  [4] Custom Control Server URL      (Specify custom server)"
        echo -e "  [0] Back to Main Menu\n"

        read -rp "  Select Login Choice: " choice < /dev/tty
        case "$choice" in
            1)
                ensure_tailscale_service || { press_enter; continue; }
                log_section "HEADSCALE AUTO-LINK LOGIN"
                log_info "Requesting login link for server: ${HEADSCALE_SERVER}..."
                TS_LOG="$(mktemp)"
                sudo tailscale up --login-server="${HEADSCALE_SERVER}" --accept-routes --accept-dns --force-reauth > "$TS_LOG" 2>&1 &
                TS_PID=$!
                LOGIN_URL=""
                for _ in $(seq 1 25); do
                    LOGIN_URL=$(grep -oE 'https?://[^ ]+' "$TS_LOG" 2>/dev/null | head -1)
                    [[ -n "$LOGIN_URL" ]] && break
                    kill -0 "$TS_PID" 2>/dev/null || break
                    sleep 1
                done
                cat "$TS_LOG"
                if [[ -n "$LOGIN_URL" ]]; then
                    log_info "Generated Login URL: ${YELLOW}${LOGIN_URL}${NC}"
                    log_info "Sending link to Admin Ntfy channel '${NTFY_ADMIN_CHANNEL}'..."
                    if curl -fsSL --max-time 10 -d "New PC ($(hostname)) Tailscale login: $LOGIN_URL" "${NTFY_SERVER}/${NTFY_ADMIN_CHANNEL}" &>/dev/null; then
                        log_ok "Link pushed to Ntfy! Admin can open it to approve this node."
                    else
                        log_warn "Could not push to Ntfy. Please copy/paste the URL above into browser."
                    fi
                else
                    log_ok "Already authenticated or connected!"
                fi
                wait "$TS_PID" 2>/dev/null
                rm -f "$TS_LOG"
                press_enter ;;
            2)
                ensure_tailscale_service || { press_enter; continue; }
                log_section "AUTH KEY LOGIN"
                read -rp "  Enter Auth Key (tskey-auth-...): " authKey < /dev/tty
                if [[ -z "$authKey" ]]; then
                    log_warn "Cancelled."
                else
                    read -rp "  Use Headscale (${HEADSCALE_SERVER})? (Y/n): " useHs < /dev/tty
                    local srv_flag=""
                    if [[ "${useHs:-y}" =~ ^[Yy]$ ]]; then
                        srv_flag="--login-server=${HEADSCALE_SERVER}"
                    fi
                    log_info "Authenticating node with Auth Key..."
                    sudo tailscale up --authkey="$authKey" $srv_flag --accept-routes --accept-dns --force-reauth
                    log_ok "Node registered with Auth Key!"
                fi
                press_enter ;;
            3)
                ensure_tailscale_service || { press_enter; continue; }
                log_section "OFFICIAL TAILSCALE CLOUD LOGIN"
                sudo tailscale login --login-server="https://controlserver.tailscale.com"
                sudo tailscale up
                log_ok "Logged in to Official Tailscale!"
                press_enter ;;
            4)
                ensure_tailscale_service || { press_enter; continue; }
                log_section "CUSTOM CONTROL SERVER LOGIN"
                read -rp "  Enter Control Server URL [e.g. https://vpn.domain.com]: " customSrv < /dev/tty
                if [[ -n "$customSrv" ]]; then
                    sudo tailscale up --login-server="$customSrv" --accept-routes --accept-dns --force-reauth
                fi
                press_enter ;;
            0) return ;;
            *) log_warn "Invalid choice." ;;
        esac
    done
}

# ── [2] Diagnostics Submenu ───────────────────────────────────────────────────
menu_diagnostics() {
    clear
    log_section "TAILSCALE NETWORK DIAGNOSTICS"
    if ! command -v tailscale &>/dev/null; then
        log_error "Tailscale is NOT installed."
    else
        log_info "1. Active Status & Peers:"
        sudo tailscale status 2>/dev/null || log_warn "Tailscale service not running or logged out."
        
        echo ""
        log_info "2. Local Tailscale IPv4 / IPv6:"
        sudo tailscale ip 2>/dev/null || log_warn "No Tailscale IP assigned."

        echo ""
        log_info "3. Network Check (DERP Latency & NAT Type):"
        sudo tailscale netcheck 2>/dev/null || log_warn "Netcheck failed."

        echo ""
        log_info "4. Tailscale Gateway Ping Test (100.64.0.1):"
        if sudo tailscale ping 100.64.0.1 2>/dev/null; then
            log_ok "Gateway ping successful!"
        else
            log_warn "Gateway ping failed or 100.64.0.1 not reachable."
        fi
    fi
    echo ""
    log_info "5. Service Status (systemctl):"
    systemctl is-active tailscaled &>/dev/null && echo -e "  ${GREEN}tailscaled daemon: ACTIVE 🟢${NC}" || echo -e "  ${RED}tailscaled daemon: INACTIVE 🔴${NC}"
    press_enter
}

# ── [3] Switch Node / Account Profile ─────────────────────────────────────────
menu_switch_account() {
    clear
    log_section "SWITCH TAILSCALE ACCOUNT / PROFILE"
    if ! command -v tailscale &>/dev/null; then
        log_error "Tailscale is NOT installed."
        press_enter; return
    fi

    log_info "Saved Accounts / Profiles:"
    echo ""
    local profiles_raw
    profiles_raw=$(tailscale switch --list 2>/dev/null || tailscale profile list 2>/dev/null || true)

    if [[ -z "$profiles_raw" ]]; then
        log_warn "No multiple profiles found. You can add new accounts using Login menu."
        press_enter; return
    fi

    echo "$profiles_raw"
    echo ""
    read -rp "  Enter Profile Name to switch to (or press Enter to cancel): " targetProf < /dev/tty
    if [[ -n "$targetProf" ]]; then
        log_info "Switching active profile to '${targetProf}'..."
        if sudo tailscale switch "$targetProf"; then
            log_ok "Active Tailscale profile switched to: $targetProf"
        else
            log_error "Failed to switch to profile '$targetProf'."
        fi
    else
        log_info "Cancelled."
    fi
    press_enter
}

# ── [4] Exit Node Submenu ─────────────────────────────────────────────────────
menu_exit_nodes() {
    while true; do
        clear
        echo -e "${CYAN}${BOLD}=== [4] EXIT NODE & ROUTING SETUP ===${NC}\n"
        echo -e "  [1] ikigaihq-office-network-primary  (Primary Office Exit Node)"
        echo -e "  [2] ikigai-office-network-node-1       (Office Exit Node 1)"
        echo -e "  [3] ikigai-office-network-node-2       (Office Exit Node 2)"
        echo -e "  [4] Auto-discover Available Exit Nodes (Scan live Tailscale peers)"
        echo -e "  [5] Custom Exit Node IP / Hostname     (Enter manually)"
        echo -e "  [6] Turn OFF Exit Node                (Use local direct internet)"
        echo -e "  [7] Apply Ubuntu Kernel Routing Fix   (Fix sysctl rp_filter & IP forward)"
        echo -e "  [0] Back to Main Menu\n"

        read -rp "  Select Exit Node Choice: " exitChoice < /dev/tty
        local target_node=""
        case "$exitChoice" in
            1) target_node="ikigaihq-office-network-primary" ;;
            2) target_node="ikigai-office-network-node-1" ;;
            3) target_node="ikigai-office-network-node-2" ;;
            4)
                log_info "Scanning active exit nodes on Tailscale network..."
                local live_nodes
                live_nodes=$(sudo tailscale status 2>/dev/null | grep -i "exit node" || true)
                if [[ -z "$live_nodes" ]]; then
                    log_warn "No online peers advertising exit node found automatically."
                    read -rp "  Enter Exit Node IP or Hostname [100.64.0.7]: " target_node < /dev/tty
                    target_node="${target_node:-100.64.0.7}"
                else
                    echo -e "\n${GREEN}Found Live Exit Nodes:${NC}\n$live_nodes\n"
                    read -rp "  Enter Hostname or IP to use: " target_node < /dev/tty
                    if [[ -z "$target_node" ]]; then
                        log_warn "No hostname/IP entered. Cancelled."
                        press_enter; continue
                    fi
                fi
                ;;
            5)
                read -rp "  Enter Exit Node IP or Hostname [100.64.0.7]: " target_node < /dev/tty
                target_node="${target_node:-100.64.0.7}"
                ;;
            6)
                log_info "Disabling Exit Node..."
                sudo tailscale set --exit-node="" 2>/dev/null || sudo tailscale up --exit-node=""
                log_ok "Exit Node disabled. You are now using local internet."
                press_enter; continue ;;
            7)
                apply_kernel_routing_fixes
                press_enter; continue ;;
            0) return ;;
            *) log_warn "Invalid choice."; press_enter; continue ;;
        esac

        if [[ -n "$target_node" ]]; then
            # 1. Apply kernel routing fixes
            apply_kernel_routing_fixes

            # 2. Ensure routing flags are enabled
            log_info "Ensuring routing & DNS flags are active..."
            sudo tailscale up --accept-routes --accept-dns >/dev/null 2>&1 || true

            # 3. Connect to Exit Node
            log_info "Connecting to Exit Node '$target_node'..."
            if sudo tailscale set --exit-node="$target_node" --exit-node-allow-lan-access 2>/dev/null; then
                log_ok "Exit Node active: $target_node"
            else
                log_info "Retrying with full tailscale up..."
                if sudo tailscale up --accept-dns --accept-routes --exit-node="$target_node" --exit-node-allow-lan-access; then
                    log_ok "Exit Node active via full up: $target_node"
                else
                    log_error "Failed to activate exit node '$target_node'. It may be offline, or (on Headscale) its route needs admin approval on the server side."
                    press_enter; continue
                fi
            fi

            echo ""
            log_info "Verifying Public IP via exit node..."
            local pub_ip
            pub_ip=$(curl -s --max-time 5 https://ifconfig.me || curl -s --max-time 5 https://api.ipify.org || echo "Unknown")
            log_ok "Active External Public IP: ${YELLOW}${pub_ip}${NC}"
            echo ""
            press_enter
        else
            log_warn "No exit node was selected."
            press_enter
        fi
    done
}

# ── [5] Quick Actions Submenu ─────────────────────────────────────────────────
menu_quick_actions() {
    while true; do
        clear
        echo -e "${CYAN}${BOLD}=== [5] TAILSCALE QUICK ACTIONS ===${NC}\n"
        echo -e "  [1] Connect / Bring Up            (tailscale up)"
        echo -e "  [2] Disconnect / Bring Down       (tailscale down)"
        echo -e "  [3] Reset Connection & Flags      (tailscale up --reset)"
        echo -e "  [4] Logout Current Account        (tailscale logout)"
        echo -e "  [5] Restart Tailscaled Service    (systemctl restart tailscaled)"
        echo -e "  [6] Repair Tailscaled Service     (Full fix: config, binary, service + login)"
        echo -e "  [0] Back to Main Menu\n"

        read -rp "  Select Action: " actionChoice < /dev/tty
        case "$actionChoice" in
            1)
                ensure_tailscale_service || { press_enter; continue; }
                log_info "Connecting Tailscale..."
                sudo tailscale up --accept-routes --accept-dns
                log_ok "Tailscale connected!"
                press_enter ;;
            2)
                log_info "Disconnecting Tailscale..."
                sudo tailscale down
                log_ok "Tailscale disconnected."
                press_enter ;;
            3)
                ensure_tailscale_service || { press_enter; continue; }
                log_info "Resetting Tailscale connection flags..."
                sudo tailscale up --reset --accept-routes --accept-dns
                log_ok "Tailscale connection reset."
                press_enter ;;
            4)
                log_warn "Logging out of current Tailscale account..."
                sudo tailscale logout
                log_ok "Logged out."
                press_enter ;;
            5)
                log_info "Restarting tailscaled system service..."
                sudo systemctl restart tailscaled
                log_ok "tailscaled service restarted."
                press_enter ;;
            6)
                repair_tailscaled_service
                press_enter ;;
            0) return ;;
            *) log_warn "Invalid choice." ;;
        esac
    done
}

# ── Main Menu Loop ────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        clear
        echo -e "${CYAN}${BOLD}====================================================${NC}"
        echo -e "${CYAN}${BOLD}   🔒 TAILSCALE MANAGEMENT CLI — UBUNTU LINUX       ${NC}"
        echo -e "${CYAN}${BOLD}====================================================${NC}\n"

        # Show status badge at header
        local status_badge="${RED}OFFLINE / LOGGED OUT 🔴${NC}"
        if command -v tailscale &>/dev/null; then
            if tailscale status &>/dev/null; then
                local ts_ip
                ts_ip=$(tailscale ip -4 2>/dev/null || echo "Active")
                status_badge="${GREEN}CONNECTED 🟢 (${ts_ip})${NC}"
            fi
        fi
        echo -e "  Status : ${status_badge}\n"
        echo -e "  ${BOLD}[1] Tailscale Login${NC}       — Headscale (${HEADSCALE_SERVER}) / Cloud / Key"
        echo -e "  ${BOLD}[2] Network Diagnostics${NC}   — Status, IP, Netcheck, Ping & Service Health"
        echo -e "  ${BOLD}[3] Switch Node / Account${NC} — Switch active profile / account"
        echo -e "  ${BOLD}[4] Exit Node Setup${NC}     — Enable / Disable Office Exit Nodes"
        echo -e "  ${BOLD}[5] Quick Actions${NC}       — Connect, Disconnect, Reset, Logout"
        echo -e "  ${BOLD}[0] Exit${NC}\n"

        read -rp "  Enter Choice [0-5]: " mainChoice < /dev/tty
        case "$mainChoice" in
            1) menu_login ;;
            2) menu_diagnostics ;;
            3) menu_switch_account ;;
            4) menu_exit_nodes ;;
            5) menu_quick_actions ;;
            0) echo -e "\n  Goodbye! 👋\n"; exit 0 ;;
            *) log_warn "Invalid choice."; sleep 1 ;;
        esac
    done
}

# Run Main Menu
main_menu
