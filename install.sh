#!/usr/bin/env bash

# ==============================================================================
# UBUNTU INTERACTIVE POST-INSTALL SETUP SCRIPT
# ==============================================================================
# Description: Interactive dashboard console to install developer tools, GUI apps,
#              system configs, and check service statuses.
# Target OS: Ubuntu 20.04 LTS / 22.04 LTS / 24.04 LTS
# ==============================================================================

# Exit immediately if a command exits with a non-zero status during critical phases
set -e

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- Logging Helpers ---
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# --- Pre-run Checks ---
if [[ "$EUID" -eq 0 ]]; then
   log_error "Please do NOT run this script as root/sudo directly."
   log_error "Run it as a normal user: ./install.sh"
   log_error "The script will ask for sudo password when needed."
   exit 1
fi

# Acquire sudo privileges upfront and keep alive
log_info "Acquiring sudo privileges..."
sudo -v
# Keep-alive: update existing sudo time stamp if set, otherwise do nothing
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

# --- Initial User Setup (First-time run) ---
# Check if the 'Admin' user exists. If not, perform initial system user setup.
if ! id -u Admin >/dev/null 2>&1; then
    echo -e "${YELLOW}==============================================================================${NC}"
    echo -e "${YELLOW}                     INITIAL USER & SYSTEM SETUP                              ${NC}"
    echo -e "${YELLOW}==============================================================================${NC}"
    echo -e "Fresh Ubuntu installation detected ('Admin' user not found)."
    read -p "Would you like to set up the system administrators (Admin & personal user)? (y/N): " setup_users
    if [[ "$setup_users" =~ ^[Yy]$ ]]; then
        # 1. Create 'Admin' user
        log_info "Creating 'Admin' user..."
        sudo useradd -m -s /bin/bash Admin
        echo "Admin:Admin@ikigai" | sudo chpasswd
        sudo usermod -aG sudo Admin
        log_success "Created user 'Admin' with password 'Admin@ikigai' and added to sudo group."

        # 2. Ask for second user details
        echo ""
        read -p "Enter username for the secondary administrator (your personal account): " SECOND_USER
        while [[ -z "$SECOND_USER" ]]; do
            read -p "Username cannot be empty. Please enter a username: " SECOND_USER
        done

        log_info "Creating '$SECOND_USER' user..."
        sudo useradd -m -s /bin/bash "$SECOND_USER"
        echo "$SECOND_USER:123456" | sudo chpasswd
        sudo usermod -aG sudo "$SECOND_USER"
        log_success "Created user '$SECOND_USER' with password '123456' and added to sudo group."

        # 3. Optional Hostname Change
        echo ""
        read -p "Enter new hostname for this machine (or press Enter to keep current '$(hostname)'): " NEW_HOSTNAME
        if [[ -n "$NEW_HOSTNAME" ]]; then
            log_info "Setting hostname to '$NEW_HOSTNAME'..."
            sudo hostnamectl set-hostname "$NEW_HOSTNAME"
            # Update /etc/hosts to prevent sudo warnings
            sudo sed -i "s/127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/g" /etc/hosts
            log_success "Hostname updated to '$NEW_HOSTNAME'."
        fi

        # 4. Copy install.sh to the new user's home directory so they can run it
        SCRIPT_PATH=$(readlink -f "$0")
        log_info "Copying setup script to /home/$SECOND_USER/install.sh..."
        sudo cp "$SCRIPT_PATH" "/home/$SECOND_USER/install.sh"
        sudo chown "$SECOND_USER:$SECOND_USER" "/home/$SECOND_USER/install.sh"
        sudo chmod +x "/home/$SECOND_USER/install.sh"

        echo -e "\n${GREEN}[SUCCESS] Initial setup complete!${NC}"
        echo -e "We will now switch session to user '${BOLD}$SECOND_USER${NC}' to continue installing software."
        echo -e "Please enter the password for ${BOLD}$SECOND_USER${NC} (which is ${BOLD}123456${NC}) if prompted."
        echo -e "${YELLOW}------------------------------------------------------------------------------${NC}"
        
        # Switch user and execute the copied script
        exec sudo -i -u "$SECOND_USER" bash -c "cd ~ && ./install.sh"
    fi
fi


# --- Options Menu Data ---
OPTIONS=(
  "System Updates (apt update && upgrade)"
  "Core Utilities & libfuse2 (Git, curl, unzip, etc.)"
  "Docker & Docker Compose"
  "Node.js v15.14.0 (via NVM)"
  "Python 3 & Pip"
  "Google Chrome"
  "Visual Studio Code"
  "MySQL Workbench"
  "DBeaver Community Edition (.deb)"
  "Postman (Snap)"
  "Redis Insight (Snap)"
  "MongoDB Compass (.deb)"
  "Tailscale VPN"
  "GNOME Tweaks & Extension Manager"
  "ClamAV (Antivirus daemon configuration)"
)

# Selections array: 1 = Selected for install, 0 = Deselected. Default to all selected.
SELECTIONS=(1 1 1 1 1 1 1 1 1 1 1 1 1 1 1)

# --- Installer Functions ---

run_system_updates() {
    log_info "Running system updates..."
    sudo apt-get update -y
    sudo apt-get upgrade -y
    log_success "System updates completed."
}

install_core_utilities() {
    log_info "Installing core CLI utilities & libfuse2..."
    sudo apt-get install -y \
        curl \
        git \
        wget \
        build-essential \
        htop \
        tmux \
        unzip \
        software-properties-common \
        apt-transport-https \
        ca-certificates \
        gnupg \
        lsb-release \
        libfuse2
    log_success "Core CLI utilities & libfuse2 installed."
}

install_docker() {
    log_info "Installing Docker Engine & Docker Compose..."
    sudo apt-get remove -y docker docker-engine docker.io containerd runc || true
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    if ! getent group docker >/dev/null; then
        sudo groupadd docker
    fi
    sudo usermod -aG docker "$USER"
    log_success "Docker installed. Group permissions configured."
}

install_node() {
    log_info "Installing NVM and Node.js v15.14.0..."
    if [ ! -d "$HOME/.nvm" ]; then
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    fi
    
    # Load NVM for current context
    export NVM_DIR="$HOME/.nvm"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        \. "$NVM_DIR/nvm.sh"
        log_info "Installing Node.js v15.14.0..."
        nvm install 15.14.0
        nvm use 15.14.0
        nvm alias default 15.14.0
        log_success "Node.js $(node -v) and npm $(npm -v) configured."
    else
        log_error "NVM load failed. Node.js install skipped."
    fi
}

install_python() {
    log_info "Installing Python 3 & pip..."
    sudo apt-get install -y python3 python3-pip python3-venv
    log_success "Python environment installed."
}

install_chrome() {
    log_info "Installing Google Chrome..."
    wget -q -O /tmp/google-chrome-stable_current_amd64.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    sudo apt-get install -y /tmp/google-chrome-stable_current_amd64.deb
    rm /tmp/google-chrome-stable_current_amd64.deb
    log_success "Google Chrome installed."
}

install_vscode() {
    log_info "Installing Visual Studio Code..."
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /tmp/packages.microsoft.gpg
    sudo install -D -o root -g root -m 644 /tmp/packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
    sudo sh -c 'echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list'
    rm -f /tmp/packages.microsoft.gpg
    sudo apt-get update -y
    sudo apt-get install -y code
    log_success "VS Code installed."
}

install_mysql_workbench() {
    log_info "Installing MySQL Workbench..."
    sudo apt-get install -y mysql-workbench
    log_success "MySQL Workbench installed."
}

install_dbeaver() {
    log_info "Installing DBeaver Community Edition (.deb)..."
    wget -q -O /tmp/dbeaver-ce_amd64.deb https://dbeaver.io/files/dbeaver-ce_latest_amd64.deb
    sudo apt-get install -y /tmp/dbeaver-ce_amd64.deb
    rm /tmp/dbeaver-ce_amd64.deb
    log_success "DBeaver installed."
}

install_postman() {
    log_info "Installing Postman (Snap)..."
    sudo snap install postman
    log_success "Postman installed."
}

install_redisinsight() {
    log_info "Installing Redis Insight (Snap)..."
    sudo snap install redisinsight
    log_success "Redis Insight installed."
}

install_mongodb_compass() {
    log_info "Installing MongoDB Compass (.deb)..."
    wget -q -O /tmp/mongodb-compass_amd64.deb https://downloads.mongodb.com/compass/mongodb-compass_1.43.0_amd64.deb
    sudo apt-get install -y /tmp/mongodb-compass_amd64.deb
    rm /tmp/mongodb-compass_amd64.deb
    log_success "MongoDB Compass installed."
}

install_tailscale() {
    log_info "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    log_success "Tailscale installed."
}

install_gnome_tools() {
    log_info "Installing GNOME Tweaks & Extension Manager..."
    sudo apt-get install -y gnome-tweaks gnome-shell-extension-manager
    log_success "GNOME configurations ready."
}

install_clamav() {
    log_info "Installing ClamAV (Antivirus) and configuring Daemon to start automatically..."
    sudo apt-get install -y clamav clamav-daemon clamav-freshclam
    
    log_info "Stopping freshclam service to run manual update..."
    sudo systemctl stop clamav-freshclam || true
    
    log_info "Updating ClamAV virus signatures (freshclam)..."
    sudo freshclam || true # Ignore signature errors if mirrors are rate-limiting
    
    log_info "Starting and enabling ClamAV systemd services (Always run on restart)..."
    sudo systemctl enable clamav-freshclam
    sudo systemctl start clamav-freshclam
    sudo systemctl enable clamav-daemon
    sudo systemctl start clamav-daemon
    
    log_success "ClamAV daemon configured and running."
}

# --- System Configuration Setup ---

configure_system_settings() {
    echo -e "\n${CYAN}${BOLD}--- SYSTEM HOSTNAME & GIT SETUP ---${NC}"
    current_hostname=$(hostname)
    echo "Current Hostname: $current_hostname"
    read -r -p "Enter new hostname (leave empty to keep current): " new_hostname

    read -r -p "Enter global Git user name (leave empty to skip): " git_name
    read -r -p "Enter global Git email address (leave empty to skip): " git_email

    if [[ -n "$new_hostname" ]]; then
        log_info "Configuring hostname to: $new_hostname"
        sudo hostnamectl set-hostname "$new_hostname"
        sudo sed -i "s/127.0.1.1.*/127.0.1.1\t$new_hostname/g" /etc/hosts
        log_success "Hostname updated to $new_hostname"
    fi

    if [[ -n "$git_name" ]]; then
        git config --global user.name "$git_name"
        log_success "Git user name set to: $git_name"
    fi
    if [[ -n "$git_email" ]]; then
        git config --global user.email "$git_email"
        log_success "Git email set to: $git_email"
    fi
}

# --- Status & Diagnostic Module ---

check_status() {
    local label=$1
    local cmd=$2
    local service=$3 # optional
    
    printf " - %-50s: " "$label"
    if [ -n "$cmd" ] && eval "$cmd" >/dev/null 2>&1; then
        if [ -n "$service" ]; then
            if systemctl is-active --quiet "$service"; then
                echo -e "${GREEN}[INSTALLED & RUNNING]${NC}"
            else
                echo -e "${YELLOW}[INSTALLED, NOT RUNNING]${NC}"
            fi
        else
            echo -e "${GREEN}[INSTALLED]${NC}"
        fi
    else
        # Fallback to dpkg check for non-binary items
        if [[ "$cmd" == *"dpkg"* ]] && eval "$cmd" >/dev/null 2>&1; then
            if [ -n "$service" ]; then
                if systemctl is-active --quiet "$service"; then
                    echo -e "${GREEN}[INSTALLED & RUNNING]${NC}"
                else
                    echo -e "${YELLOW}[INSTALLED, NOT RUNNING]${NC}"
                fi
            else
                echo -e "${GREEN}[INSTALLED]${NC}"
            fi
        else
            echo -e "${RED}[NOT INSTALLED]${NC}"
        fi
    fi
}

show_status_results() {
    echo -e "\n${CYAN}${BOLD}========================================================"
    echo "          SOFTWARE INSTALLATION STATUS CHECK            "
    echo "========================================================${NC}"
    
    check_status "Core Utilities & libfuse2" "command -v curl && command -v git && command -v unzip && dpkg -s libfuse2"
    check_status "Docker Engine" "command -v docker" "docker"
    
    # Load NVM for check context
    export NVM_DIR="$HOME/.nvm"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        \. "$NVM_DIR/nvm.sh"
    fi
    check_status "Node.js (v15.14.0 via NVM)" "command -v node && node -v | grep -q 'v15.14.0'"
    
    check_status "Python 3 & Pip" "command -v python3 && command -v pip3"
    check_status "Google Chrome" "command -v google-chrome"
    check_status "Visual Studio Code" "command -v code"
    check_status "MySQL Workbench" "command -v mysql-workbench"
    check_status "DBeaver Community Edition" "command -v dbeaver"
    check_status "Postman (Snap)" "command -v postman"
    check_status "Redis Insight (Snap)" "command -v redisinsight"
    check_status "MongoDB Compass" "command -v mongodb-compass"
    check_status "Tailscale VPN" "command -v tailscale" "tailscaled"
    check_status "GNOME Tweaks & Extension Manager" "dpkg -s gnome-tweaks && dpkg -s gnome-shell-extension-manager"
    check_status "ClamAV Antivirus Daemon" "command -v clamscan" "clamav-daemon"
    check_status "ClamAV Freshclam Updates" "command -v freshclam" "clamav-freshclam"
    
    echo -e "========================================================\n"
}

# --- Execution Controller ---

run_installation() {
    # Request credentials/host configuration first
    configure_system_settings
    
    # Dispatch functions matching selections
    for i in "${!OPTIONS[@]}"; do
        if [ "${SELECTIONS[$i]}" -eq 1 ]; then
            echo -e "\n${MAGENTA}${BOLD}========================================================"
            echo " Installing: ${OPTIONS[$i]}"
            echo "========================================================${NC}"
            
            # Disable set -e for installers so one failure doesn't halt the entire run
            set +e
            case $i in
                0) run_system_updates ;;
                1) install_core_utilities ;;
                2) install_docker ;;
                3) install_node ;;
                4) install_python ;;
                5) install_chrome ;;
                6) install_vscode ;;
                7) install_mysql_workbench ;;
                8) install_dbeaver ;;
                9) install_postman ;;
                10) install_redisinsight ;;
                11) install_mongodb_compass ;;
                12) install_tailscale ;;
                13) install_gnome_tools ;;
                14) install_clamav ;;
            esac
            set -e
        fi
    done
    
    echo -e "\n${GREEN}${BOLD}Selected setup routines completed!${NC}"
    
    # Run status check
    show_status_results
    
    # Prompt for final restart
    read -r -p "Would you like to reboot the system now? (y/N): " reboot_now
    if [[ "$reboot_now" =~ ^[Yy]$ ]]; then
        log_info "Rebooting system..."
        sudo reboot
    else
        log_info "Reboot skipped. Please reload your shell or reboot manually."
    fi
}

# --- Interactive Main Console Loop ---

while true; do
    clear
    echo -e "${MAGENTA}${BOLD}========================================================"
    echo "          UBUNTU SYSTEM SETUP DASHBOARD                 "
    echo "========================================================${NC}"
    echo -e "Toggle installation items by entering their number."
    echo -e "Type ${GREEN}'i'${NC} to start installation, ${CYAN}'s'${NC} to test status, or ${RED}'q'${NC} to quit:\n"
    
    for i in "${!OPTIONS[@]}"; do
        if [ "${SELECTIONS[$i]}" -eq 1 ]; then
            checkbox="[X]"
            color="${GREEN}"
        else
            checkbox="[ ]"
            color="${NC}"
        fi
        # Add alignment spacing for single vs double digit indices
        printf " %2d) %b%s %s%b\n" "$((i+1))" "$color" "$checkbox" "${OPTIONS[$i]}" "$NC"
    done
    
    echo -e "--------------------------------------------------------"
    echo -e "  ${BOLD}i)${NC} ${GREEN}Start Installation${NC}"
    echo -e "  ${BOLD}s)${NC} ${CYAN}Check Current System Status / Diagnostics${NC}"
    echo -e "  ${BOLD}q)${NC} ${RED}Quit Setup${NC}"
    echo -e "========================================================"
    read -r -p "Choose command or index: " choice
    
    if [[ "$choice" =~ ^[Qq]$ ]]; then
        log_info "Exiting dashboard. Goodbye!"
        exit 0
    elif [[ "$choice" =~ ^[Ii]$ ]]; then
        run_installation
        exit 0
    elif [[ "$choice" =~ ^[Ss]$ ]]; then
        show_status_results
        read -r -p "Press Enter to return to menu..."
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#OPTIONS[@]}" ]; then
        idx=$((choice-1))
        # Toggle selection
        if [ "${SELECTIONS[$idx]}" -eq 1 ]; then
            SELECTIONS[$idx]=0
        else
            SELECTIONS[$idx]=1
        fi
    else
        log_warning "Invalid option. Please try again."
        sleep 1
    fi
done
