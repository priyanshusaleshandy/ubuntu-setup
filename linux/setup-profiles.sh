#!/usr/bin/env bash
# setup-profiles.sh
# Interactive profile-based software setup script for Ubuntu

set -e

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Banner Function ---
show_banner() {
    clear
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "${MAGENTA}   ____  ______   _____ ______ ______  __  __  ____ ${NC}"
    echo -e "${MAGENTA}  / __ \/ ____/  / ___// ____//_  __/ / / / / / __ \\${NC}"
    echo -e "${CYAN} / /_/ / /       \\__ \\/ __/    / /   / / / / / /_/ /${NC}"
    echo -e "${CYAN}/ ____/ /___    ___/ / /___   / /   / /_/ / / ____/ ${NC}"
    echo -e "${BLUE}/_/    \\____/  /____/_____/  /_/    \\____/ /_/      ${NC}"
    echo -e ""
    echo -e "            ${NC}${BOLD}WORKSTATION PROFILE SETUP TOOLKIT (UBUNTU)${NC}"
    echo -e "${CYAN}======================================================================${NC}"
    echo ""
}

# --- Check Root/Sudo ---
if [[ "$EUID" -eq 0 ]]; then
   echo -e "${RED}[ERROR] Please do NOT run this script as root/sudo directly.${NC}"
   echo -e "Run it as a normal user: ./setup-profiles.sh"
   echo -e "The script will ask for sudo password when needed."
   exit 1
fi

# Acquire sudo privileges upfront
echo -e "${BLUE}[*] Acquiring sudo privileges...${NC}"
sudo -v
# Keep-alive: update existing sudo time stamp every 60s in the background
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

# --- Helper: Install via APT ---
install_apt() {
    local pkg=$1
    local name=$2
    echo -e "${YELLOW}[*] Installing $name via apt...${NC}"
    sudo apt-get install -y "$pkg"
    echo -e "${GREEN}[+] $name installed successfully.${NC}"
}

# --- Helper: Install via Snap ---
install_snap() {
    local snap_name=$1
    local name=$2
    local classic=$3
    echo -e "${YELLOW}[*] Installing $name via snap...${NC}"
    if [ "$classic" = "--classic" ]; then
        sudo snap install --classic "$snap_name"
    else
        sudo snap install "$snap_name"
    fi
    echo -e "${GREEN}[+] $name installed successfully.${NC}"
}

# --- Chrome Installation ---
install_chrome() {
    if command -v google-chrome &> /dev/null; then
        echo -e "${GREEN}[+] Google Chrome is already installed.${NC}"
        return
    fi
    echo -e "${YELLOW}[*] Installing Google Chrome...${NC}"
    local temp_deb="/tmp/google-chrome-stable_current_amd64.deb"
    wget -O "$temp_deb" "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
    sudo apt-get install -y "$temp_deb"
    rm -f "$temp_deb"
    echo -e "${GREEN}[+] Google Chrome installed.${NC}"
}

# --- Brave Installation ---
install_brave() {
    if command -v brave-browser &> /dev/null; then
        echo -e "${GREEN}[+] Brave Browser is already installed.${NC}"
        return
    fi
    install_snap "brave" "Brave Browser"
}

# --- Tailscale Installation ---
install_tailscale() {
    if command -v tailscale &> /dev/null; then
        echo -e "${GREEN}[+] Tailscale is already installed.${NC}"
        return
    fi
    echo -e "${YELLOW}[*] Installing Tailscale...${NC}"
    curl -fsSL https://tailscale.com/install.sh | sh
    echo -e "${GREEN}[+] Tailscale installed.${NC}"
}

# --- Custom App Handlers ---
install_basecamp() {
    echo -e "${YELLOW}[*] Configuring Basecamp 3...${NC}"
    echo -e "${WHITE}Basecamp 3 does not offer an official Linux desktop app.${NC}"
    echo -e "Using Basecamp via Chrome/Brave web application is recommended."
    echo -e "${BLUE}[INFO] Creating desktop shortcut for web-based Basecamp is suggested.${NC}"
}

install_timedoctor() {
    echo -e "${YELLOW}[*] Checking for Time Doctor 2...${NC}"
    # Time Doctor 2 has a Linux AppImage. We will download it.
    local appimage_path="$HOME/Applications/TimeDoctor2.AppImage"
    if [ -f "$appimage_path" ]; then
        echo -e "${GREEN}[+] Time Doctor 2 AppImage already exists at $appimage_path${NC}"
        return
    fi
    
    mkdir -p "$HOME/Applications"
    echo -e "${YELLOW}[*] Downloading Time Doctor 2 Linux AppImage...${NC}"
    # Using public direct link or fallback link. If URL fails, we inform the user.
    if wget -O "$appimage_path" "https://download.timedoctor.com/td2/install/desktop/TimeDoctor2-setup.AppImage" 2>/dev/null; then
        chmod +x "$appimage_path"
        echo -e "${GREEN}[+] Time Doctor 2 AppImage downloaded and saved to $appimage_path${NC}"
    else
        echo -e "${YELLOW}[!] Could not automatically download Time Doctor AppImage.${NC}"
        echo -e "    Please download the Linux app from https://www.timedoctor.com/download.html"
    fi
}

install_sprinto() {
    echo -e "${YELLOW}[*] Checking for Sprinto Compliance Agent (Linux)...${NC}"
    # Typically Sprinto agent is downloaded from dashboard as script or package
    local local_agent="./sprinto-agent.sh"
    if [ -f "$local_agent" ]; then
        echo -e "${GREEN}[+] Found local Sprinto installer: $local_agent${NC}"
        chmod +x "$local_agent"
        sudo "$local_agent"
    else
        echo -e "${YELLOW}[!] Local Sprinto installer script not found in current folder.${NC}"
        echo -e "    Download the Linux version of Sprinto Agent from your dashboard to configure it."
    fi
}

install_nvm_and_node() {
    echo -e "${YELLOW}[*] Checking NVM (Node Version Manager)...${NC}"
    export NVM_DIR="$HOME/.nvm"
    
    if [ ! -d "$NVM_DIR" ]; then
        echo -e "${YELLOW}[*] Installing NVM...${NC}"
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    fi
    
    # Load NVM into this session
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    
    if command -v nvm &> /dev/null; then
        echo -e "${GREEN}[+] NVM loaded successfully.${NC}"
        echo -e "${YELLOW}[*] Installing Node.js v15.14.0...${NC}"
        nvm install 15.14.0
        nvm use 15.14.0
        echo -e "${GREEN}[+] Node.js version in use: $(node -v)${NC}"
    else
        echo -e "${RED}[ERROR] NVM installation failed or could not be loaded.${NC}"
    fi
}

configure_tailscale_custom() {
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}       Tailscale Custom Server Setup         ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo -e "You can configure Tailscale connection to your custom login server here."
    echo -e "Example: sudo tailscale up --login-server=https://your-headscale-server"
    echo ""
    read -p "Would you like to run Tailscale up now? (y/N): " run_ts
    if [[ "$run_ts" =~ ^[Yy]$ ]]; then
        read -p "Enter custom login server URL (leave empty for default): " login_server
        if [ -n "$login_server" ]; then
            sudo tailscale up --login-server="$login_server" --accept-routes
        else
            sudo tailscale up --accept-routes
        fi
    else
        echo -e "Tailscale customization skipped. You can run 'sudo tailscale up' later."
    fi
}

# --- Runs i3 Normal User Suite ---
run_i3_profile() {
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}  Starting [i3 - Normal User Profile] Suite  ${NC}"
    echo -e "${GREEN}=============================================${NC}"
    
    # Update package indexes
    echo -e "${YELLOW}[*] Updating apt package lists...${NC}"
    sudo apt-get update -y
    
    # Core utilities
    install_chrome
    install_brave
    install_tailscale
    
    # Custom apps
    install_basecamp
    install_timedoctor
    install_sprinto
    
    echo -e "\n${GREEN}[+] i3 Normal User Profile suite completed successfully.${NC}"
}

# --- Runs i5 Developer Suite ---
run_i5_profile() {
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN} Starting [i5 - Developer User Profile] Suite ${NC}"
    echo -e "${GREEN}=============================================${NC}"
    
    # First install all i3 packages
    run_i3_profile
    
    echo -e "\n${CYAN}=============================================${NC}"
    echo -e "${CYAN}      Installing Developer packages          ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    # Dev packages
    install_snap "code" "VS Code" "--classic"
    install_snap "dbeaver-ce" "DBeaver Community Edition"
    install_nvm_and_node
    
    # GNOME Customization
    install_apt "gnome-tweaks" "Gnome Tweaks"
    install_apt "gnome-shell-extension-manager" "Gnome Shell Extension Manager"
    
    # Custom Tailscale Login
    configure_tailscale_custom
    
    echo -e "\n${GREEN}[+] i5 Developer User Profile suite completed successfully.${NC}"
}

# --- Main Entry Point ---
show_banner

echo -e "Please select the workstation profile to install:"
echo -e " [1] i3 Profile - Normal User (Chrome, Brave, Tailscale, Basecamp, Sprinto, Time Doctor)"
echo -e " [2] i5 Profile - Developer User (i3 Suite + VS Code, DBeaver, NVM + Node 15.14.0, Gnome Tweaks, Gnome Shell)"
echo -e " [0] Exit Setup"
echo ""
read -p "Enter choice (1, 2, or 0): " choice

case "$choice" in
    1)
        run_i3_profile
        ;;
    2)
        run_i5_profile
        ;;
    0)
        echo -e "Exiting. No changes made."
        exit 0
        ;;
    *)
        echo -e "${RED}[ERROR] Invalid choice. Exiting.${NC}"
        exit 1
        ;;
esac

echo -e "\n${GREEN}[+] Profile installation process finished successfully.${NC}"
