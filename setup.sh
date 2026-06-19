#!/usr/bin/env bash

# setup.sh
# Universal bootstrap script for workstation-setup
# Detects operating system and launches the appropriate installer dashboard.

set -e

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

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

echo -e "${CYAN}${BOLD}========================================================${NC}"
echo -e "${CYAN}${BOLD}         UNIVERSAL WORKSTATION SETUP BOOTSTRAP          ${NC}"
echo -e "${CYAN}${BOLD}========================================================${NC}"
log_info "Detecting system operating system..."

OS_TYPE="$(uname -s)"
case "$OS_TYPE" in
    Linux*)
        # Check if it's Ubuntu/Debian
        if [ -f /etc/debian_version ]; then
            log_success "System detected: Linux (Debian/Ubuntu-based)"
            # Delegate to install.sh or linux/install.sh
            SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            if [ -f "$SCRIPT_DIR/install.sh" ]; then
                log_info "Launching Linux setup console..."
                exec "$SCRIPT_DIR/install.sh" "$@"
            elif [ -f "$SCRIPT_DIR/linux/install.sh" ]; then
                log_info "Launching Linux setup console from subdirectory..."
                exec "$SCRIPT_DIR/linux/install.sh" "$@"
            else
                log_info "Fetching latest linux setup dashboard from GitHub..."
                wget -O install.sh https://raw.githubusercontent.com/priyanshusaleshandy/ubuntu-setup/main/install.sh
                chmod +x install.sh
                exec ./install.sh "$@"
            fi
        else
            log_error "This script currently only supports Debian/Ubuntu-based Linux distributions."
            exit 1
        fi
        ;;
        
    Darwin*)
        log_success "System detected: macOS"
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [ -f "$SCRIPT_DIR/macos/install.sh" ]; then
            log_info "Launching macOS installation setup..."
            exec "$SCRIPT_DIR/macos/install.sh" "$@"
        else
            log_info "Fetching latest macOS setup dashboard from GitHub..."
            curl -fsSL https://raw.githubusercontent.com/priyanshusaleshandy/ubuntu-setup/main/macos/install.sh | bash
        fi
        ;;
        
    CYGWIN*|MINGW32*|MSYS*|MINGW*)
        log_success "System detected: Windows (Bash environment)"
        log_warning "Please run the setup console natively using PowerShell as Administrator."
        echo ""
        echo -e "Open a PowerShell window (as Administrator) and run:"
        echo -e "${GREEN}${BOLD}irm https://raw.githubusercontent.com/priyanshusaleshandy/ubuntu-setup/main/windows/install.ps1 | iex${NC}"
        echo ""
        ;;
        
    *)
        log_error "Unsupported operating system: $OS_TYPE"
        exit 1
        ;;
esac