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
  "Core Utilities & libfuse2 (Git, curl, unzip, etc.)"
  "Node.js v15.14.0 (via NVM)"
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
SELECTIONS=(1 1 1 1 1 1 1 1 1 1 1 1)

# --- Installer Functions ---

# (System updates function removed as requested)

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

# --- Uninstallation Functions ---

uninstall_core_utilities() {
    log_info "Uninstalling core developer tools & libfuse2..."
    # Only remove non-critical developer utilities we added.
    # We must NEVER remove curl, wget, git, or system metadata packages (ca-certificates, gnupg, lsb-release, software-properties-common)
    # as doing so breaks the package graph and causes apt to autoremove ubuntu-desktop (Software Store, default browsers, etc.).
    sudo apt-get remove --purge -y \
        build-essential \
        htop \
        tmux \
        unzip \
        libfuse2 || true
    sudo apt-get autoremove -y
    log_success "Core developer tools & libfuse2 uninstalled."
}

uninstall_node() {
    log_info "Removing NVM and Node.js..."
    rm -rf "$HOME/.nvm" "$HOME/.npm" "$HOME/.bower" || true
    sed -i '/NVM_DIR/d' "$HOME/.bashrc" "$HOME/.profile" 2>/dev/null || true
    log_success "Node.js (NVM) removed."
}

uninstall_chrome() {
    log_info "Uninstalling Google Chrome..."
    sudo apt-get remove --purge -y google-chrome-stable || true
    sudo apt-get autoremove -y
    log_success "Google Chrome uninstalled."
}

uninstall_vscode() {
    log_info "Uninstalling Visual Studio Code..."
    sudo apt-get remove --purge -y code || true
    sudo rm -f /etc/apt/sources.list.d/vscode.list
    sudo apt-get autoremove -y
    log_success "VS Code uninstalled."
}

uninstall_mysql_workbench() {
    log_info "Uninstalling MySQL Workbench..."
    sudo apt-get remove --purge -y mysql-workbench || true
    sudo apt-get autoremove -y
    log_success "MySQL Workbench uninstalled."
}

uninstall_dbeaver() {
    log_info "Uninstalling DBeaver Community Edition..."
    sudo apt-get remove --purge -y dbeaver-ce || true
    sudo apt-get autoremove -y
    log_success "DBeaver uninstalled."
}

uninstall_postman() {
    log_info "Uninstalling Postman (Snap)..."
    sudo snap remove postman || true
    log_success "Postman uninstalled."
}

uninstall_redisinsight() {
    log_info "Uninstalling Redis Insight (Snap)..."
    sudo snap remove redisinsight || true
    log_success "Redis Insight uninstalled."
}

uninstall_mongodb_compass() {
    log_info "Uninstalling MongoDB Compass..."
    sudo apt-get remove --purge -y mongodb-compass || true
    sudo apt-get autoremove -y
    log_success "MongoDB Compass uninstalled."
}

uninstall_tailscale() {
    log_info "Uninstalling Tailscale..."
    sudo snap remove tailscale || true
    sudo apt-get remove --purge -y tailscale || true
    sudo rm -f /etc/apt/sources.list.d/tailscale.list
    sudo apt-get autoremove -y
    log_success "Tailscale uninstalled."
}

uninstall_gnome_tools() {
    log_info "Uninstalling GNOME Tweaks & Extension Manager..."
    sudo apt-get remove --purge -y gnome-tweaks gnome-shell-extension-manager || true
    sudo apt-get autoremove -y
    log_success "GNOME tools uninstalled."
}

uninstall_clamav() {
    log_info "Stopping and disabling ClamAV services..."
    sudo systemctl stop clamav-freshclam clamav-daemon 2>/dev/null || true
    sudo systemctl disable clamav-freshclam clamav-daemon 2>/dev/null || true
    log_info "Uninstalling ClamAV..."
    sudo apt-get remove --purge -y clamav clamav-daemon clamav-freshclam || true
    sudo apt-get autoremove -y
    log_success "ClamAV uninstalled."
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
    
    # Load NVM for check context
    export NVM_DIR="$HOME/.nvm"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        \. "$NVM_DIR/nvm.sh"
    fi
    check_status "Node.js (v15.14.0 via NVM)" "command -v node && node -v | grep -q 'v15.14.0'"
    
    check_status "Google Chrome" "command -v google-chrome"
    check_status "Visual Studio Code" "command -v code"
    check_status "MySQL Workbench" "command -v mysql-workbench"
    check_status "DBeaver Community Edition" "command -v dbeaver"
    check_status "Postman (Snap)" "command -v postman"
    check_status "Redis Insight (Snap)" "command -v redisinsight"
    check_status "MongoDB Compass" "command -v mongodb-compass"
    check_status "Tailscale VPN" "command -v tailscale" "snap.tailscale.tailscaled"
    check_status "GNOME Tweaks & Extension Manager" "dpkg -s gnome-tweaks && dpkg -s gnome-shell-extension-manager"
    check_status "ClamAV Antivirus Daemon" "command -v clamscan" "clamav-daemon"
    check_status "ClamAV Freshclam Updates" "command -v freshclam" "clamav-freshclam"
    
    echo -e "========================================================\n"
}

# --- Uninstallation Controller ---

uninstall_component() {
    local index=$1
    case $index in
        0) uninstall_core_utilities ;;
        1) uninstall_node ;;
        2) uninstall_chrome ;;
        3) uninstall_vscode ;;
        4) uninstall_mysql_workbench ;;
        5) uninstall_dbeaver ;;
        6) uninstall_postman ;;
        7) uninstall_redisinsight ;;
        8) uninstall_mongodb_compass ;;
        9) uninstall_tailscale ;;
        10) uninstall_gnome_tools ;;
        11) uninstall_clamav ;;
    esac
}

run_uninstallation() {
    local scope=$1 # "selected" or "all"
    
    echo -e "\n${RED}${BOLD}========================================================"
    if [ "$scope" = "all" ]; then
        echo " UNINSTALLING ALL COMPONENTS"
    else
        echo " UNINSTALLING SELECTED COMPONENTS"
    fi
    echo "========================================================${NC}"
    
    read -r -p "Are you sure you want to proceed with uninstallation? (y/N): " confirm_uninstall
    if [[ ! "$confirm_uninstall" =~ ^[Yy]$ ]]; then
        log_info "Uninstallation cancelled."
        return
    fi
    
    # Run the uninstallation logic
    for i in "${!OPTIONS[@]}"; do
        if [ "$scope" = "all" ] || [ "${SELECTIONS[$i]}" -eq 1 ]; then
            echo -e "\n${YELLOW}${BOLD}Removing: ${OPTIONS[$i]}...${NC}"
            set +e
            uninstall_component "$i"
            set -e
        fi
    done
    
    echo -e "\n${GREEN}${BOLD}Uninstallation process completed!${NC}"
    show_status_results
    read -r -p "Press Enter to return to menu..."
}

# --- Execution Controller ---

run_installation() {
    # Request credentials/host configuration first
    configure_system_settings
    
    local APT_PACKAGES=()
    local SNAP_PACKAGES=()
    local INSTALL_NODE=0
    local INSTALL_CLAMAV=0
    local DOWNLOAD_PIDS=()

    echo -e "\n${MAGENTA}${BOLD}========================================================"
    echo " Preparing Installation & Spawning Parallel Downloads..."
    echo "========================================================${NC}"

    # 1. Spawn background downloads for selected external .deb packages
    # Google Chrome (Index 2)
    if [ "${SELECTIONS[2]}" -eq 1 ]; then
        log_info "Starting Google Chrome download in background..."
        (wget -q -O /tmp/google-chrome-stable_current_amd64.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb || touch /tmp/chrome_fail) &
        DOWNLOAD_PIDS+=($!)
        APT_PACKAGES+=("/tmp/google-chrome-stable_current_amd64.deb")
    fi

    # DBeaver Community Edition (Index 5)
    if [ "${SELECTIONS[5]}" -eq 1 ]; then
        log_info "Starting DBeaver download in background..."
        (wget -q -O /tmp/dbeaver-ce_amd64.deb https://dbeaver.io/files/dbeaver-ce_latest_amd64.deb || touch /tmp/dbeaver_fail) &
        DOWNLOAD_PIDS+=($!)
        APT_PACKAGES+=("/tmp/dbeaver-ce_amd64.deb")
    fi

    # MongoDB Compass (Index 8)
    if [ "${SELECTIONS[8]}" -eq 1 ]; then
        log_info "Starting MongoDB Compass download in background..."
        (wget -q -O /tmp/mongodb-compass_amd64.deb https://downloads.mongodb.com/compass/mongodb-compass_1.43.0_amd64.deb || touch /tmp/mongodb_fail) &
        DOWNLOAD_PIDS+=($!)
        APT_PACKAGES+=("/tmp/mongodb-compass_amd64.deb")
    fi

    # Remove potential failure flag files from prior runs
    rm -f /tmp/chrome_fail /tmp/dbeaver_fail /tmp/mongodb_fail

    # 2. Add repo configurations synchronously (fast operations)
    # Visual Studio Code (Index 3)
    if [ "${SELECTIONS[3]}" -eq 1 ]; then
        log_info "Adding VS Code repository GPG key and source list..."
        wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /etc/apt/keyrings/packages.microsoft.gpg >/dev/null
        sudo sh -c 'echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list'
        APT_PACKAGES+=("code")
    fi

    # 3. Assemble packages from the rest of the options
    # Core Utilities (Index 0)
    if [ "${SELECTIONS[0]}" -eq 1 ]; then
        APT_PACKAGES+=("curl" "git" "wget" "build-essential" "htop" "tmux" "unzip" "software-properties-common" "apt-transport-https" "ca-certificates" "gnupg" "lsb-release" "libfuse2")
    fi

    # Node.js (Index 1)
    if [ "${SELECTIONS[1]}" -eq 1 ]; then
        INSTALL_NODE=1
    fi

    # MySQL Workbench (Index 4)
    if [ "${SELECTIONS[4]}" -eq 1 ]; then
        APT_PACKAGES+=("mysql-workbench")
    fi

    # Postman (Index 6)
    if [ "${SELECTIONS[6]}" -eq 1 ]; then
        SNAP_PACKAGES+=("postman")
    fi

    # Redis Insight (Index 7)
    if [ "${SELECTIONS[7]}" -eq 1 ]; then
        SNAP_PACKAGES+=("redisinsight")
    fi

    # Tailscale VPN (Index 9)
    if [ "${SELECTIONS[9]}" -eq 1 ]; then
        SNAP_PACKAGES+=("tailscale")
    fi

    # GNOME Tweaks & Extension Manager (Index 10)
    if [ "${SELECTIONS[10]}" -eq 1 ]; then
        APT_PACKAGES+=("gnome-tweaks" "gnome-shell-extension-manager")
    fi

    # ClamAV (Index 11)
    if [ "${SELECTIONS[11]}" -eq 1 ]; then
        INSTALL_CLAMAV=1
        APT_PACKAGES+=("clamav" "clamav-daemon" "clamav-freshclam")
    fi

    # 4. Wait for background downloads to complete
    if [ "${#DOWNLOAD_PIDS[@]}" -gt 0 ]; then
        log_info "Waiting for all background downloads to finish..."
        for pid in "${DOWNLOAD_PIDS[@]}"; do
            wait "$pid"
        done
        
        # Check download failure flags
        if [ -f /tmp/chrome_fail ] || [ -f /tmp/dbeaver_fail ] || [ -f /tmp/mongodb_fail ]; then
            log_warning "Some downloads failed. Script will attempt to continue but installation of failed packages might skip."
        fi
    fi

    # 5. Run CONSOLIDATED APT Installation
    if [ "${#APT_PACKAGES[@]}" -gt 0 ]; then
        echo -e "\n${CYAN}${BOLD}========================================================"
        echo " Executing Consolidated APT Package Installation..."
        echo "========================================================${NC}"
        
        log_info "Running apt update..."
        sudo apt-get update -y
        
        log_info "Installing packages: ${APT_PACKAGES[*]}..."
        set +e
        sudo apt-get install -y "${APT_PACKAGES[@]}"
        set -e
    fi

    # 6. Run SNAP installations
    if [ "${#SNAP_PACKAGES[@]}" -gt 0 ]; then
        echo -e "\n${CYAN}${BOLD}========================================================"
        echo " Executing Snap Package Installations..."
        echo "========================================================${NC}"
        
        for snap_pkg in "${SNAP_PACKAGES[@]}"; do
            log_info "Installing snap package: $snap_pkg..."
            set +e
            sudo snap install "$snap_pkg"
            set -e
        done
    fi

    # 7. Run Node.js / NVM Setup
    if [ "$INSTALL_NODE" -eq 1 ]; then
        echo -e "\n${CYAN}${BOLD}========================================================"
        echo " Configuring Node.js via NVM..."
        echo "========================================================${NC}"
        set +e
        install_node
        set -e
    fi

    # 8. Run ClamAV Post-Install configurations
    if [ "$INSTALL_CLAMAV" -eq 1 ]; then
        echo -e "\n${CYAN}${BOLD}========================================================"
        echo " Configuring ClamAV Antivirus Daemon..."
        echo "========================================================${NC}"
        set +e
        log_info "Stopping freshclam service to run manual update..."
        sudo systemctl stop clamav-freshclam || true
        
        log_info "Updating ClamAV virus signatures (freshclam)..."
        sudo freshclam || true # Ignore signature errors if mirrors are rate-limiting
        
        log_info "Starting and enabling ClamAV systemd services..."
        sudo systemctl enable clamav-freshclam
        sudo systemctl start clamav-freshclam
        sudo systemctl enable clamav-daemon
        sudo systemctl start clamav-daemon
        set -e
        log_success "ClamAV daemon configured."
    fi

    echo -e "\n${GREEN}${BOLD}Setup completed successfully!${NC}"
    
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
    echo -e "Toggle items by entering their number."
    echo -e "Type ${GREEN}'i'${NC} to install, ${YELLOW}'u'${NC} to uninstall selected, ${RED}'a'${NC} to uninstall all,"
    echo -e "or type ${CYAN}'s'${NC} to test status, ${RED}'q'${NC} to quit:\n"
    
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
    echo -e "  ${BOLD}u)${NC} ${YELLOW}Uninstall Selected Components${NC}"
    echo -e "  ${BOLD}a)${NC} ${RED}Uninstall ALL Components${NC}"
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
    elif [[ "$choice" =~ ^[Uu]$ ]]; then
        run_uninstallation "selected"
    elif [[ "$choice" =~ ^[Aa]$ ]]; then
        run_uninstallation "all"
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
