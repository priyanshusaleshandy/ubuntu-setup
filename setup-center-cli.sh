#!/usr/bin/env bash
# ==============================================================================
# SETUP CENTER CLI — Ubuntu / Bash Edition
# ==============================================================================
# All features from the Setup Center EXE, in a lightweight CLI dashboard:
#
#  [1] Install Packages        — select from 12 tools via checkbox menu
#  [2] Uninstall Packages      — remove selected or all packages
#  [3] System Status           — show what's installed / running
#  [4] Update System           — apt update + upgrade
#  [5] Tailscale VPN           — install / login / connect / diagnose / remove
#  [6] System Config           — hostname, git config
#  [7] Onboarding User         — create new user (admin account flow)
#  [0] Exit
#
# Usage:
#   chmod +x setup-center-cli.sh
#   ./setup-center-cli.sh
# ==============================================================================

set -uo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}    $1"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}      $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $1"; }
log_section() { echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}"; }

press_enter() { echo ""; read -rp "  Press Enter to return to menu..." _ < /dev/tty; }

# ── Root guard ────────────────────────────────────────────────────────────────
if [[ "$EUID" -eq 0 ]]; then
    log_error "Do NOT run this script as root. Run as a normal user."
    log_error "The script will ask for sudo when needed."
    exit 1
fi

# ── Sudo keep-alive ───────────────────────────────────────────────────────────
log_info "Acquiring sudo privileges..."
sudo -v
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT

# ── Package list & selections ─────────────────────────────────────────────────
OPTIONS=(
    "Core Utilities & libfuse2 (git, curl, unzip, build-essential, etc.)"
    "Node.js v15.14.0 (via NVM)"
    "Google Chrome"
    "Visual Studio Code"
    "MySQL Workbench"
    "DBeaver Community Edition"
    "Postman (Snap)"
    "Redis Insight (Snap)"
    "MongoDB Compass"
    "Tailscale VPN"
    "GNOME Tweaks & Extension Manager"
    "ClamAV Antivirus"
    "Time Doctor"
)
SELECTIONS=(0 0 0 0 0 0 0 0 0 0 0 0 0)   # all unselected by default

# ── Install functions ─────────────────────────────────────────────────────────
install_core_utilities() {
    log_info "Installing core utilities & libfuse2..."
    sudo apt-get update -y
    sudo apt-get install -y curl git wget build-essential htop tmux unzip \
        software-properties-common apt-transport-https ca-certificates \
        gnupg lsb-release libfuse2
}

install_node() {
    log_info "Installing NVM + Node.js v15.14.0..."
    if [ ! -d "$HOME/.nvm" ]; then
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash || { log_error "NVM install failed."; return 1; }
    fi
    export NVM_DIR="$HOME/.nvm"
    # shellcheck source=/dev/null
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    nvm install 15.14.0 && nvm use 15.14.0 && nvm alias default 15.14.0
    log_ok "Node $(node -v) / npm $(npm -v) ready."
}

install_chrome() {
    log_info "Installing Google Chrome..."
    local tmp="$HOME/.sc_tmp/chrome.deb"; mkdir -p "$HOME/.sc_tmp"
    wget -O "$tmp" "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" || { log_error "Download failed."; return 1; }
    sudo apt-get install -y "$tmp"; rm -f "$tmp"
}

install_vscode() {
    log_info "Installing Visual Studio Code..."
    command -v gpg &>/dev/null || sudo apt-get install -y gnupg
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | \
        sudo tee /etc/apt/keyrings/packages.microsoft.gpg > /dev/null
    echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] \
https://packages.microsoft.com/repos/code stable main" | \
        sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null
    sudo apt-get update -y && sudo apt-get install -y code
}

install_mysql_workbench() {
    log_info "Installing MySQL Workbench..."
    sudo apt-get update -y
    if ! sudo apt-get install -y mysql-workbench 2>/dev/null; then
        log_warn "Apt failed — trying snap..."
        sudo snap install mysql-workbench-community
        sudo snap connect mysql-workbench-community:password-manager-service :password-manager-service || true
        rm -rf ~/.cache/fontconfig || true
    fi
}

install_dbeaver() {
    log_info "Installing DBeaver Community Edition..."
    local tmp="$HOME/.sc_tmp/dbeaver.deb"; mkdir -p "$HOME/.sc_tmp"
    wget -O "$tmp" "https://dbeaver.io/files/dbeaver-ce_latest_amd64.deb" || { log_error "Download failed."; return 1; }
    sudo apt-get install -y "$tmp"; rm -f "$tmp"
}

install_postman()      { log_info "Installing Postman...";      sudo snap install postman; }
install_redisinsight() { log_info "Installing Redis Insight..."; sudo snap install redisinsight; }

install_mongodb_compass() {
    log_info "Installing MongoDB Compass..."
    local tmp="$HOME/.sc_tmp/mongodb-compass.deb"; mkdir -p "$HOME/.sc_tmp"
    wget -O "$tmp" "https://downloads.mongodb.com/compass/mongodb-compass_1.43.0_amd64.deb" || { log_error "Download failed."; return 1; }
    sudo apt-get install -y "$tmp"; rm -f "$tmp"
}

install_tailscale() {
    log_info "Installing Tailscale VPN (official script)..."
    curl -fsSL https://tailscale.com/install.sh | sh || { log_error "Tailscale install failed."; return 1; }
    sudo systemctl enable --now tailscaled
    log_ok "Tailscale installed."
}

install_gnome_tools() {
    log_info "Installing GNOME Tweaks & Extension Manager..."
    sudo apt-get update -y && sudo apt-get install -y gnome-tweaks gnome-shell-extension-manager
}

install_clamav() {
    log_info "Installing ClamAV..."
    sudo apt-get update -y && sudo apt-get install -y clamav clamav-daemon clamav-freshclam
    sudo systemctl stop clamav-freshclam || true
    sudo freshclam || true
    sudo systemctl enable --now clamav-freshclam clamav-daemon
    log_ok "ClamAV installed & services started."
}

install_timedoctor() {
    log_info "Installing Time Doctor..."
    wget -O /tmp/sfproc https://download.timedoctor.com/3.16.69/linux/ubuntu-18.04/silent/sfproc-3.16.69-x86_64.run && \
        sudo /bin/bash /tmp/sfproc --nox11 -- --company-id=67ebb4c267041f1c3eb98aab && \
        rm -f /tmp/sfproc
}

# ── Uninstall functions ───────────────────────────────────────────────────────
uninstall_core_utilities() {
    log_info "Removing build-essential, htop, tmux, unzip, libfuse2..."
    sudo apt-get remove --purge -y build-essential htop tmux unzip libfuse2 || true
    sudo apt-get autoremove -y
}
uninstall_node()            { log_info "Removing NVM & Node.js..."; rm -rf "$HOME/.nvm" "$HOME/.npm"; sed -i '/NVM_DIR/d' "$HOME/.bashrc" "$HOME/.profile" 2>/dev/null || true; log_ok "NVM removed."; }
uninstall_chrome()          { sudo apt-get remove --purge -y google-chrome-stable || true; sudo apt-get autoremove -y; }
uninstall_vscode()          { sudo apt-get remove --purge -y code || true; sudo rm -f /etc/apt/sources.list.d/vscode.list; sudo apt-get autoremove -y; }
uninstall_mysql_workbench() { sudo apt-get remove --purge -y mysql-workbench || true; sudo snap remove mysql-workbench-community 2>/dev/null || true; sudo apt-get autoremove -y; }
uninstall_dbeaver()         { sudo apt-get remove --purge -y dbeaver-ce || true; sudo apt-get autoremove -y; }
uninstall_postman()         { sudo snap remove postman || true; }
uninstall_redisinsight()    { sudo snap remove redisinsight || true; }
uninstall_mongodb_compass() { sudo apt-get remove --purge -y mongodb-compass || true; sudo apt-get autoremove -y; }
uninstall_tailscale()       { sudo snap remove tailscale 2>/dev/null || true; sudo apt-get remove --purge -y tailscale || true; sudo rm -f /etc/apt/sources.list.d/tailscale.list; sudo apt-get autoremove -y; }
uninstall_gnome_tools()     { sudo apt-get remove --purge -y gnome-tweaks gnome-shell-extension-manager || true; sudo apt-get autoremove -y; }
uninstall_clamav()          {
    sudo systemctl stop clamav-freshclam clamav-daemon 2>/dev/null || true
    sudo systemctl disable clamav-freshclam clamav-daemon 2>/dev/null || true
    sudo apt-get remove --purge -y clamav clamav-daemon clamav-freshclam || true
    sudo apt-get autoremove -y
}

uninstall_timedoctor() {
    log_info "Removing Time Doctor..."
    sudo killall sfproc 2>/dev/null || true
    sudo rm -f /usr/bin/sfproc /usr/local/bin/sfproc 2>/dev/null || true
    log_ok "Time Doctor removed."
}

# ── Is-installed checks ───────────────────────────────────────────────────────
is_installed() {
    case $1 in
        0) command -v curl &>/dev/null && command -v git &>/dev/null && dpkg -s libfuse2 &>/dev/null ;;
        1) local nd="$HOME/.nvm"; [[ -s "$nd/nvm.sh" ]] && source "$nd/nvm.sh" && command -v node &>/dev/null ;;
        2) command -v google-chrome &>/dev/null ;;
        3) command -v code &>/dev/null ;;
        4) command -v mysql-workbench &>/dev/null || command -v mysql-workbench-community &>/dev/null ;;
        5) command -v dbeaver &>/dev/null ;;
        6) command -v postman &>/dev/null ;;
        7) command -v redisinsight &>/dev/null ;;
        8) command -v mongodb-compass &>/dev/null ;;
        9) command -v tailscale &>/dev/null ;;
        10) dpkg -s gnome-tweaks &>/dev/null ;;
        11) command -v clamscan &>/dev/null ;;
        12) pgrep -f sfproc &>/dev/null || [ -f /usr/bin/sfproc ] || [ -f /usr/local/bin/sfproc ] ;;
        *) return 1 ;;
    esac
}

install_component() {
    case $1 in
        0)  install_core_utilities ;;
        1)  install_node ;;
        2)  install_chrome ;;
        3)  install_vscode ;;
        4)  install_mysql_workbench ;;
        5)  install_dbeaver ;;
        6)  install_postman ;;
        7)  install_redisinsight ;;
        8)  install_mongodb_compass ;;
        9)  install_tailscale ;;
        10) install_gnome_tools ;;
        11) install_clamav ;;
        12) install_timedoctor ;;
    esac
}

uninstall_component() {
    case $1 in
        0)  uninstall_core_utilities ;;
        1)  uninstall_node ;;
        2)  uninstall_chrome ;;
        3)  uninstall_vscode ;;
        4)  uninstall_mysql_workbench ;;
        5)  uninstall_dbeaver ;;
        6)  uninstall_postman ;;
        7)  uninstall_redisinsight ;;
        8)  uninstall_mongodb_compass ;;
        9)  uninstall_tailscale ;;
        10) uninstall_gnome_tools ;;
        11) uninstall_clamav ;;
        12) uninstall_timedoctor ;;
    esac
}

# ── Install with retry ────────────────────────────────────────────────────────
install_with_retry() {
    local idx=$1 name="${OPTIONS[$1]}"
    if is_installed "$idx"; then log_info "$name already installed — skipping."; return 0; fi
    while true; do
        log_section "Installing: $name"
        set +e; install_component "$idx"; local rc=$?; set -e
        if [[ $rc -eq 0 ]]; then log_ok "$name installed."; break; fi
        log_error "Failed to install $name."
        echo -e "  ${BOLD}r)${NC} Retry   ${BOLD}s)${NC} Skip   ${BOLD}a)${NC} Abort"
        read -rp "  Choice [r/s/a]: " ch < /dev/tty
        case "$ch" in
            [Rr]*) continue ;;
            [Ss]*) log_warn "Skipping $name."; break ;;
            [Aa]*) log_error "Aborted."; exit 1 ;;
            *)     log_warn "Invalid — retrying."; continue ;;
        esac
    done
}

# ── Status check ──────────────────────────────────────────────────────────────
check_status_all() {
    log_section "SOFTWARE INSTALLATION STATUS"
    local checks=(
        "Core Utilities:command -v curl && command -v git && dpkg -s libfuse2:"
        "Node.js (NVM):source \"$HOME/.nvm/nvm.sh\" 2>/dev/null && command -v node:"
        "Google Chrome:command -v google-chrome:"
        "Visual Studio Code:command -v code:"
        "MySQL Workbench:command -v mysql-workbench || command -v mysql-workbench-community:"
        "DBeaver:command -v dbeaver:"
        "Postman:command -v postman:"
        "Redis Insight:command -v redisinsight:"
        "MongoDB Compass:command -v mongodb-compass:"
        "Tailscale VPN:command -v tailscale:tailscaled"
        "GNOME Tweaks:dpkg -s gnome-tweaks:"
        "ClamAV:command -v clamscan:clamav-daemon"
        "Time Doctor:pgrep -f sfproc || [ -f /usr/bin/sfproc ]:"
    )
    for entry in "${checks[@]}"; do
        IFS=':' read -r label cmd svc <<< "$entry"
        printf "  %-42s : " "$label"
        if eval "$cmd" &>/dev/null; then
            if [[ -n "$svc" ]] && systemctl is-active --quiet "$svc" 2>/dev/null; then
                echo -e "${GREEN}INSTALLED & RUNNING${NC}"
            elif [[ -n "$svc" ]]; then
                echo -e "${YELLOW}INSTALLED (not running)${NC}"
            else
                echo -e "${GREEN}INSTALLED${NC}"
            fi
        else
            echo -e "${RED}NOT INSTALLED${NC}"
        fi
    done
    echo ""
}

# ── [1] Install packages ──────────────────────────────────────────────────────
menu_install() {
    clear
    echo -e "${MAGENTA}${BOLD}=== [1] INSTALL PACKAGES ===${NC}\n"
    echo -e "Current selection (toggle with number, then press ${GREEN}i${NC} to install):\n"

    while true; do
        for i in "${!OPTIONS[@]}"; do
            local cb color
            if [[ "${SELECTIONS[$i]}" -eq 1 ]]; then cb="[X]"; color="$GREEN"; else cb="[ ]"; color="$NC"; fi
            printf "  %2d) %b%s %s%b\n" "$((i+1))" "$color" "$cb" "${OPTIONS[$i]}" "$NC"
        done
        echo -e "\n  ${BOLD}e)${NC} Select all   ${BOLD}c)${NC} Clear all   ${BOLD}i)${NC} ${GREEN}Start Install${NC}   ${BOLD}b)${NC} Back"
        read -rp "  Toggle (number) or command: " ch < /dev/tty
        ch="${ch//[[:space:]]/}" # Trim all whitespace

        if   [[ "$ch" =~ ^[Bb]$ ]]; then return
        elif [[ "$ch" =~ ^[Ee]$ ]]; then for j in "${!SELECTIONS[@]}"; do SELECTIONS[$j]=1; done
        elif [[ "$ch" =~ ^[Cc]$ ]]; then for j in "${!SELECTIONS[@]}"; do SELECTIONS[$j]=0; done
        elif [[ "$ch" =~ ^[Ii]$ ]]; then
            # configure hostname/git first
            configure_system_settings
            for i in "${!OPTIONS[@]}"; do
                [[ "${SELECTIONS[$i]}" -eq 1 ]] && install_with_retry "$i"
            done
            echo -e "\n${GREEN}${BOLD}Installation complete!${NC}"
            check_status_all
            read -rp "Reboot now? (y/N): " rb < /dev/tty
            [[ "$rb" =~ ^[Yy]$ ]] && sudo reboot
            return
        elif [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#OPTIONS[@]} )); then
            local idx=$((ch-1))
            SELECTIONS[$idx]=$(( 1 - SELECTIONS[$idx] ))
        else
            log_warn "Invalid input."
        fi
        clear
        echo -e "${MAGENTA}${BOLD}=== [1] INSTALL PACKAGES ===${NC}\n"
        echo -e "Current selection:\n"
    done
}

# ── [2] Uninstall packages ────────────────────────────────────────────────────
menu_uninstall() {
    clear
    echo -e "${RED}${BOLD}=== [2] UNINSTALL PACKAGES ===${NC}\n"

    while true; do
        for i in "${!OPTIONS[@]}"; do
            local cb color
            if [[ "${SELECTIONS[$i]}" -eq 1 ]]; then cb="[X]"; color="$GREEN"; else cb="[ ]"; color="$NC"; fi
            printf "  %2d) %b%s %s%b\n" "$((i+1))" "$color" "$cb" "${OPTIONS[$i]}" "$NC"
        done
        echo -e "\n  ${BOLD}e)${NC} Select all   ${BOLD}c)${NC} Clear all   ${BOLD}u)${NC} ${RED}Uninstall Selected${NC}   ${BOLD}a)${NC} ${RED}Uninstall ALL${NC}   ${BOLD}b)${NC} Back"
        read -rp "  Toggle (number) or command: " ch < /dev/tty
        ch="${ch//[[:space:]]/}" # Trim all whitespace

        if   [[ "$ch" =~ ^[Bb]$ ]]; then return
        elif [[ "$ch" =~ ^[Ee]$ ]]; then for j in "${!SELECTIONS[@]}"; do SELECTIONS[$j]=1; done
        elif [[ "$ch" =~ ^[Cc]$ ]]; then for j in "${!SELECTIONS[@]}"; do SELECTIONS[$j]=0; done
        elif [[ "$ch" =~ ^[Uu]$ || "$ch" =~ ^[Aa]$ ]]; then
            local scope="selected"; [[ "$ch" =~ ^[Aa]$ ]] && scope="all"
            echo ""
            read -rp "  Confirm uninstall $scope? (y/N): " conf < /dev/tty
            if [[ "$conf" =~ ^[Yy]$ ]]; then
                for i in "${!OPTIONS[@]}"; do
                    if [[ "$scope" == "all" || "${SELECTIONS[$i]}" -eq 1 ]]; then
                        echo -e "\n${YELLOW}Removing: ${OPTIONS[$i]}...${NC}"
                        set +e; uninstall_component "$i"; set -e
                    fi
                done
                log_ok "Uninstall complete."
                check_status_all
                press_enter; return
            fi
        elif [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#OPTIONS[@]} )); then
            local idx=$((ch-1))
            SELECTIONS[$idx]=$(( 1 - SELECTIONS[$idx] ))
        else log_warn "Invalid input."; fi
        clear
        echo -e "${RED}${BOLD}=== [2] UNINSTALL PACKAGES ===${NC}\n"
    done
}

# ── [4] System update ─────────────────────────────────────────────────────────
menu_update() {
    log_section "SYSTEM UPDATE"
    log_info "Running apt update + upgrade..."
    sudo apt-get update -y && sudo apt-get upgrade -y
    log_ok "System updated."
    press_enter
}

# ── [5] Tailscale VPN ─────────────────────────────────────────────────────────
menu_tailscale() {
    while true; do
        clear
        echo -e "${CYAN}${BOLD}=== [5] TAILSCALE VPN ===${NC}\n"
        echo -e "  [1] Install Tailscale"
        echo -e "  [2] Login  (open browser to bifrost.saleshandy.com)"
        echo -e "  [3] Connect (accept routes)"
        echo -e "  [4] Full Reset + Connect (reset + accept DNS & routes)"
        echo -e "  [5] Connect with Exit Node (100.64.0.7)"
        echo -e "  [6] Diagnose & Status"
        echo -e "  [7] Uninstall Tailscale"
        echo -e "  [0] Back\n"

        local server="https://bifrost.saleshandy.com"
        read -rp "  Choice: " ch < /dev/tty
        case "$ch" in
            1) install_tailscale; press_enter ;;
            2)
                clear
                echo -e "${CYAN}${BOLD}=== [5.2] TAILSCALE LOGIN / REGISTER ===${NC}\n"
                echo -e "  [1] Web Browser Login (Sends Auth URL to Admin)"
                echo -e "  [2] Auth Key Login    (Use pre-authorized key from Admin)"
                echo -e "  [0] Back\n"
                read -rp "  Select Login Method: " subChoice < /dev/tty
                if [[ "$subChoice" -eq 1 ]]; then
                    log_info "Opening browser login..."
                    log_warn "If browser doesn't open, COPY the URL printed below and send it to your Admin:"
                    sudo tailscale login --login-server "$server"
                elif [[ "$subChoice" -eq 2 ]]; then
                    read -rp "  Enter Tailscale Auth Key (tskey-auth-...): " authKey < /dev/tty
                    if [[ -z "$authKey" ]]; then
                        log_warn "Cancelled."
                    else
                        log_info "Registering node using Auth Key..."
                        sudo tailscale up --authkey="$authKey" --login-server="$server" --accept-routes --accept-dns
                        log_ok "Node successfully registered with Auth Key!"
                    fi
                fi
                press_enter ;;
            3) sudo tailscale up --accept-routes --login-server="$server"; press_enter ;;
            4) sudo tailscale up --login-server="$server" --reset --accept-dns --accept-routes; press_enter ;;
            5) sudo tailscale up --login-server="$server" --accept-dns --accept-routes --exit-node=100.64.0.7; press_enter ;;
            6)
                log_section "TAILSCALE DIAGNOSTICS"
                log_info "Status:";    sudo tailscale status 2>/dev/null || log_warn "tailscale not running"
                log_info "IP:";        sudo tailscale ip 2>/dev/null || true
                log_info "Ping test:"; sudo tailscale ping 100.64.0.1 2>/dev/null || log_warn "Ping failed"
                log_info "Service:";   systemctl is-active tailscaled && echo "tailscaled: ACTIVE" || echo "tailscaled: INACTIVE"
                press_enter ;;
            7)
                read -rp "  Confirm uninstall Tailscale? (y/N): " conf < /dev/tty
                [[ "$conf" =~ ^[Yy]$ ]] && uninstall_tailscale && log_ok "Tailscale removed."
                press_enter ;;
            0) return ;;
            *) log_warn "Invalid choice." ;;
        esac
    done
}

# ── [6] System config ─────────────────────────────────────────────────────────
configure_system_settings() {
    log_section "SYSTEM HOSTNAME & GIT SETUP"
    local cur_host; cur_host=$(hostname)
    echo "  Current hostname: $cur_host"
    read -rp "  New hostname (leave blank to keep): " new_host < /dev/tty
    read -rp "  Git user name  (leave blank to skip): " git_name < /dev/tty
    read -rp "  Git email      (leave blank to skip): " git_email < /dev/tty

    if [[ -n "$new_host" ]]; then
        sudo hostnamectl set-hostname "$new_host"
        sudo sed -i "s/127.0.1.1.*/127.0.1.1\t$new_host/g" /etc/hosts
        log_ok "Hostname set to: $new_host"
    fi
    [[ -n "$git_name" ]]  && git config --global user.name "$git_name"  && log_ok "Git name: $git_name"
    [[ -n "$git_email" ]] && git config --global user.email "$git_email" && log_ok "Git email: $git_email"
}

menu_sysconfig() {
    log_section "SYSTEM CONFIGURATION"
    configure_system_settings
    press_enter
}

# ── [7] Onboarding user creation ──────────────────────────────────────────────
menu_create_user() {
    log_section "ONBOARDING USER CREATION"
    read -rp "  New username: " NEW_USER < /dev/tty
    [[ -z "$NEW_USER" ]] && log_warn "Cancelled." && press_enter && return

    read -rsp "  Password for '$NEW_USER': " NEW_PASS < /dev/tty; echo ""
    [[ -z "$NEW_PASS" ]] && log_warn "Password cannot be empty." && press_enter && return

    read -rp "  Grant sudo/admin? (y/N): " is_admin < /dev/tty

    log_info "Creating user '$NEW_USER'..."
    sudo useradd -m -s /bin/bash "$NEW_USER"
    echo "$NEW_USER:$NEW_PASS" | sudo chpasswd

    if [[ "$is_admin" =~ ^[Yy]$ ]]; then
        sudo usermod -aG sudo "$NEW_USER"
        log_ok "User '$NEW_USER' created with sudo access."
    else
        log_ok "Standard user '$NEW_USER' created."
    fi

    # Copy this script to new user home
    local script; script=$(readlink -f "$0")
    sudo cp "$script" "/home/$NEW_USER/setup-center-cli.sh"
    sudo chown "$NEW_USER:$NEW_USER" "/home/$NEW_USER/setup-center-cli.sh"
    sudo chmod +x "/home/$NEW_USER/setup-center-cli.sh"
    log_ok "Setup script copied to /home/$NEW_USER/"
    echo -e "\n  Next: log out, log in as '$NEW_USER', then run ./setup-center-cli.sh"
    press_enter
}

# ── [3] Status ────────────────────────────────────────────────────────────────
menu_status() {
    check_status_all
    echo -e "  Tailscale status:"
    sudo tailscale status 2>/dev/null || echo -e "  ${RED}tailscale not running / not installed${NC}"
    echo ""
    press_enter
}

# ── MAIN MENU ─────────────────────────────────────────────────────────────────
while true; do
    clear
    echo -e "${MAGENTA}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║     SETUP CENTER CLI  —  Ubuntu / Bash Edition      ║"
    echo "  ║     Priyanshu Suryavanshi PC Setup Toolkit          ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  ${BOLD}[1]${NC} Install Packages      — select & install tools"
    echo -e "  ${BOLD}[2]${NC} Uninstall Packages    — remove installed tools"
    echo -e "  ${BOLD}[3]${NC} System Status         — check what's installed"
    echo -e "  ${BOLD}[4]${NC} Update System         — apt update + upgrade"
    echo -e "  ${BOLD}[5]${NC} Tailscale VPN         — install / connect / diagnose / remove"
    echo -e "  ${BOLD}[6]${NC} System Config         — hostname & git setup"
    echo -e "  ${BOLD}[7]${NC} Create Onboarding User"
    echo -e "  ${BOLD}[0]${NC} Exit"
    echo -e "\n  ────────────────────────────────────────────────────────"

    read -rp "  Choice: " choice < /dev/tty
    case "$choice" in
        1) menu_install ;;
        2) menu_uninstall ;;
        3) menu_status ;;
        4) menu_update ;;
        5) menu_tailscale ;;
        6) menu_sysconfig ;;
        7) menu_create_user ;;
        0) echo -e "\n  ${CYAN}Goodbye!${NC}\n"; exit 0 ;;
        *) log_warn "Invalid choice — enter 0-7."; sleep 1 ;;
    esac
done
