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

# ── Self-relaunch (fixes "won't run from USB pendrive") ─────────────────────
# USB drives (FAT32/exFAT) don't preserve the executable bit, and Ubuntu mounts
# removable media with `noexec` by default — so running the script directly off
# a pendrive always fails, no matter how many times you chmod +x it.
# Fix: copy ourselves to a safe local folder and re-launch from there via bash
# (bash reading a file as an argument is not blocked by noexec, so this always
# works — even the very first time, even with zero setup on a brand new PC).
SAFE_DIR="$HOME/.local/share/setup-center"
SAFE_SCRIPT="$SAFE_DIR/setup-center-cli.sh"
THIS_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
if [[ "$THIS_SCRIPT" != "$SAFE_SCRIPT" ]]; then
    mkdir -p "$SAFE_DIR" 2>/dev/null
    if cp -f "$THIS_SCRIPT" "$SAFE_SCRIPT" 2>/dev/null; then
        chmod +x "$SAFE_SCRIPT" 2>/dev/null
        exec bash "$SAFE_SCRIPT" "$@"
    fi
    # If copy failed (e.g. read-only $HOME), just continue running from here.
fi

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

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

# ── Preflight: make sure base tools exist BEFORE anything else runs ──────────
# On a truly fresh Ubuntu install, curl/wget/gnupg/snap etc. may be missing.
# Without this, whichever menu option you pick first can silently fail with
# "command not found". This runs once, up front, no matter what you choose.
preflight_dependencies() {
    log_info "Checking base tools (curl, wget, git, gnupg, snap, etc.)..."
    local need_update=0
    local base_pkgs=(curl wget git gnupg ca-certificates apt-transport-https \
        software-properties-common lsb-release unzip)
    local to_install=()
    for pkg in "${base_pkgs[@]}"; do
        dpkg -s "$pkg" &>/dev/null || to_install+=("$pkg")
    done
    if ! command -v snap &>/dev/null; then to_install+=(snapd); fi

    if [[ ${#to_install[@]} -gt 0 ]]; then
        log_warn "Missing: ${to_install[*]} — installing now..."
        sudo apt-get update -y
        sudo apt-get install -y "${to_install[@]}"
    fi
    log_ok "Base tools ready."
}
preflight_dependencies

# ── Tailscale Auto-Send Config ────────────────────────────────────────────────
# Change these if you ever move to a different Admin channel or server.
# No need to type it every time — the script uses this automatically.
NTFY_SERVER="http://192.168.126.101:8080"   # Private self-hosted ntfy (Mac Mini via Docker)
NTFY_ADMIN_CHANNEL="priyanshu-setup"

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
    "Time Doctor"
    "GNOME Screen Blank Timeout (14 minutes)"
    "ESET PROTECT Agent (Antivirus/EDR)"
    "Action1 Agent (RMM)"
)
SELECTIONS=(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)   # all unselected by default

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
    if curl -fsSL -o /tmp/sfproc https://download.timedoctor.com/3.16.69/linux/ubuntu-18.04/silent/sfproc-3.16.69-x86_64.run; then
        log_info "Download complete. Running installer..."
        if sudo /bin/bash /tmp/sfproc --nox11 -- --company-id=67ebb4c267041f1c3eb98aab; then
            log_ok "Time Doctor installed successfully!"
            rm -f /tmp/sfproc
            return 0
        else
            log_error "Time Doctor installation failed."
            rm -f /tmp/sfproc
            return 1
        fi
    else
        log_error "Failed to download Time Doctor."
        return 1
    fi
}

install_eset_protect() {
    log_info "Installing ESET PROTECT Agent (Antivirus/EDR)..."
    local tmp="$HOME/.sc_tmp/eset-protect-installer.sh"
    mkdir -p "$HOME/.sc_tmp"
    cat > "$tmp" << 'ESET_INSTALLER_EOF'
#!/bin/sh -e
# ESET PROTECT
# Copyright (c) 1992-2026 ESET, spol. s r.o. All Rights Reserved

cleanup_file="$(mktemp -q)"
finalize()
{
  set +e
  if test -f "$cleanup_file"
  then
    while read f
    do
      rm -f "$f"
    done < "$cleanup_file"
    rm -f "$cleanup_file"
  fi
}

trap 'finalize' HUP INT QUIT TERM EXIT

eraa_server_hostname="udwzq2pdhinundkpdrrdi7vzlu.a.ecaserver.eset.com"
eraa_server_port="443"
eraa_server_company_name='Ikigai Infotech LLP'
eraa_peer_cert_b64="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"
eraa_peer_cert_pwd=""
eraa_ca_cert_b64="MIIFpDCCA4ygAwIBAgIIMUSW0eFkh/8wDQYJKoZIhvcNAQELBQAwaDELMAkGA1UEBhMCU0sxGDAWBgNVBAgTD1Nsb3ZhayBSZXB1YmxpYzETMBEGA1UEBxMKQnJhdGlzbGF2YTENMAsGA1UEChMERXNldDEbMBkGA1UEAxMSRVBDIEFnZW50IHByb3h5IENBMB4XDTIyMDYyMDAwMDAwMFoXDTMyMDYxOTIzNTk1OVowaDELMAkGA1UEBhMCU0sxGDAWBgNVBAgTD1Nsb3ZhayBSZXB1YmxpYzETMBEGA1UEBxMKQnJhdGlzbGF2YTENMAsGA1UEChMERXNldDEbMBkGA1UEAxMSRVBDIEFnZW50IHByb3h5IENBMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEApFyygZ31hn6s/K7+Lm/r3KP+P5Gn0pb5J6IR0F+KtBUiNE9nRn5PnVDdyj9uVd6BZIKcczoHebH/70GQUuOzprDtHhWUTNDZ7R4NfNz0u5cYn2mKPk9lJRPEcuvqKr+aGsCs1yMv226xd72ngJE/Z2MlGLGX5+kuO0HmQWRUK/SDtmcCvforHs7zE19PjXmZQnpW+bUFkLeHcHS4WtJ64CNkbuTHssK8nNDQoJXLZVKafLWCkAZ94vpZWDRG5AffdBDnKrSy+WOTI6dOJw8i+uJ7YtWconTJo9NRCcgTzCHujylXgqWkwm3f+Wh/h0u5KIJEzTPN/RTzP+/SWEDrYi7+wECXWv6kU3Ty3KkzPGsAt9ABmnvAUGShi8Heyhnes6E3IiUt3wko+LHVw9hFyXFjfqtgRtxvOTcX06zinpQbtl+d1Wm7mU/ORFIPffRec4B9YewF1VRCm4gT5vqFZbO7BUnuyKFeGr6Vxlgrgz0mPS0PAoATI500x9g8Md3Mmshc/6wLInMHgSh//n+aylnePRrTvLEJhcWgoDx57wZ7G5fTeHEFIRrcU3ez6PSKbodCBcjfWrGLkXNQzmIwhDxVRmo4DXLga6MzbYqU54zQVfk60CiFEvwwK8l7WBZ7XlqxRl8QmsIUGf278N8Hxe0qOs7fcZPvuVHyhS4WKxsCAwEAAaNSMFAwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUZ9DJSflsyGkpLas5Ll3dMzeMJSEwCwYDVR0PBAQDAgEGMBEGCWCGSAGG+EIBAQQEAwIABzANBgkqhkiG9w0BAQsFAAOCAgEAWrXSFAd4OmT0bxHj1q+zMROTxXalzfAfqncTGaTm2NiqL5be3WfgnQLjGOMX+VVC1YXDlI2xs2JAWD3myRT4u7g1Y320HmjWczaE36h8PrnL+M/LEIHem3bM7e6ZFGHzwN80D5bmM++qacrGnnSDXid/sVx2Vi5KKXOXcFB74Haef5mqVm9uNpjDuUO+7Zdip6xqieHOpYD7HIWCkq/bJXxyrPr9CY37KyVdeMoU8QuIzdlgn5l0yc8LNBXXv7pba+ykPirIWe1ZR0O0z5e0gAqUe0kz9fpiMmzWpaGS/4s8gt0oYX2Ahibc3Lgg179OOpUFOsz92TmPVQCnzseZCPirikCA7qUAmMFKqs+l+X6DdKIrL4ocHs5zFAL9fysdKpczKczAWpZXr9LtuY6WFDkcWhxm4kj1MXyte8UBBC4C1UX47Km5TlOQUApnp7LMXI3jlBB+2Lo3T9N2FhiQ5R2PoNdA+XONNaBb8E9mh83wOvA6+Me1Rb7bIO6q/dTULd41Jns3JQ8zy0H8rQrOSOREWfieW0Czd38ZRJoa7MRp6Z3aYAuqt8pJpOykVbKQY/OYh43pt5gfgFvIkI3CuoJvLPQ3bYKyBiJN8PYhFpOyLYOrOJqbd26x+QFORgiBdZo6u6Em31l3fVpiaMcSAD9Cny6VUEC2aYn00beB2Vc="
eraa_product_uuid=""
eraa_initial_sg_token="OWU3MTkwNjMtODY0Ny00YzdlLThiOTgtN2EyNGI1YzZjZTk18WFaj0hcTdKbrmRa7cLE4bKmLBA/I0Dml5b/Nk/RScXONGh83P9gx6+2ot1S4iwmYigq3w=="
eraa_policy_data="eyJwb2xpY3kiOnsiZm9ybWF0IjoxfX0KITxhcmNoPgovLyAgICAgICAgICAgICAgMTc4MjI5OTA3MyAgMCAgICAgMCAgICAgNjQ0ICAgICAxOCAgICAgICAgYApvcmlnaW5hbFBvbGljaWVzLwovMCAgICAgICAgICAgICAgMTc4MjI5OTA3MyAgMCAgICAgMCAgICAgNjQ0ICAgICAxMDQ0MyAgICAgYApleUp3YjJ4cFkza2lPbnNpWm05eWJXRjBJam95TENKMlpYSnphVzl1WDIxaGFtOXlJam8wTWprME9UWTNNamsxTENKMlpYSnphVzl1WDIxcGJtOXlJam8wTWprME9UWTNNamsxTENKMlpYSnphVzl1WDJKMWFXeGtJam93TENKa1lYUmhJanA3SW5OMFlXNWtZV3h2Ym1VaU9uc2lVMlYwZEdsdVozTWlPbnNpVlhCa1lYUmxjaUk2ZXlKalpWOW1iR0ZuY3lJNk1Dd2lRWFYwYjFWd1pHRjBaWE1pT25zaVkyVmZabXhoWjNNaU9qQXNJa1Z1WVdKc1pXUWlPbnNpWTJWZlpteGhaM01pT2pRc0ltTmxYM1I1Y0dVaU9qWXNJbU5sWDNaaGJIVmxJam94Zlgwc0ltTmxYM1psY25OcGIyNGlPaUl6TGpBaWZYMTlmWDE5CmV5SndiMnhwWTNraU9uc2labTl5YldGMElqb3hmWDBLSVR4aGNtTm9QZ3BsYm1Sd2IybHVkQzVzZW0xaEx5QWdNVGM0TWpFeU5qUTRNaUFnTUNBZ0lDQWdNQ0FnSUNBZ05qUTBJQ0FnSUNBek9Ea2dJQ0FnSUNBZ1lBcGRBQUFDQVAvLy8vLy8vLy8vQUQySWlnY3o4bXdudVYxUkZHd1cxd241bTZvaXJUOXhHbWJrbVVXcWdBOWNxNlN6L3pFTmtyZzVieGw1RXpXWnJRR3YxcGFPQnVkVkR5Q2JyaWJBaWtSNWR3QUI0RVRTWUwyVG4waWJMblhYOEczWFhaa0tSN1RmTVZGaXdEM0ptbWpPUWRqWmM2R1FDWWdJaG1JbUhpOEFldStIaTZuUDVwSFloeHlLL2tXUTNXdmk1TlZwWGFUdEFOaDlIUmxFeE4raHU3Q2QwTGQzcDN1TCtLcW8zcURHREwvOWJlcGJCeU9mR2pydUtFbytkbHpLQ1hHWHlkZjdzamRmTFVQekxCNzlmNVR3ak9xb2hLYUtrcFphNWF0U29SNkFQSFJuMld1UjUzMWFKektVWE1ESURXY1ViMWE2Q2RRa1pTZFc3aHM1aXA0bzkwaXdpakc1R0NBNVFIR3MyaU1VZ09DSHF5UWxtZ25NM0cwL0x3UEp2bmxhVVRzMzJYcENPM2dsUmVsanlqWXlyQmJLTjlkSFkxSGphczM4Z2J2Ri84N2RpaDlVZ29aellPbnhQNGZyWlQvbkdnaWhCSzRoQ1FNbEdFb2NZWU40YWF0dlludHRPOEVWVDVUcWduM2FOcC94MXJZMEhuK2NoZ3E0WGhYL2lJb0xBQXBvYVhOMGIzSjVMbUZ5THlBZ0lDQWdNVGM0TWpFeU5qUTRNaUFnTUNBZ0lDQWdNQ0FnSUNBZ05qUTBJQ0FnSUNBeU56QWdJQ0FnSUNBZ1lBb2hQR0Z5WTJnK0NtbHVabTh1YW5OdmJpNXNlbTFoTHlBeE56Z3lNVEkyTkRneUlDQXdJQ0FnSURBd0lDQWdJQ0EyTkRRZ0lDQWdJREl3TVNBZ0lDQWdJQ0JnQ2w0QUFFQUEvLy8vLy8vLy8vOEFQWUtBQVNMSzd5U3psd3BZVHZRWnpkMGYwZGEwaGNFaGtaRWg0U1BLNFJteEo1US8xdlo3S1d6RkNKUmlCQXQ3MDZDT1JHZUNMcmZxZVhxQSs5Qk91MkVYZjFySWZCbGJibkg4ZUxYZVUxdDNlVWRhMDgwdHlkNkxFMVJzV0ZSTVlSR2crWWUrb1pUTmdRNkh5ZndXL2NkT0RpNmY3WEk0dTM1RGNveUpsWWhyS2xzR2JQSXpsMGFad0JXTE9UNUZhUENRekp5RmhNbzBBdXgvVTJBb2RobGxkTnE0KzdMZHNxSFMxY0dWVXV6VmFNUFVXNTMrOWJhUFFBcHBibVp2TG1wemIyNHZJQ0FnSUNBZ01UYzRNakV5TmpRNE1pQWdNQ0FnSUNBZ01DQWdJQ0FnTmpRMElDQWdJQ0F4TlRBZ0lDQWdJQ0FnWUFwN0NpQWlkM0pwZEhSbGJsOWllVjlqWlNJNklqSXlNek11TlNBb01qQXlOakExTWpZcE95QXlORE16SWl3S0lDSmpiMjF3WVhScFltbHNhWFI1SWpwN0NpQWdJbVZ1WkhCdmFXNTBJanA3Q2lBZ0lDSTVMakVpT2lJM0xqQWlMQW9nSUNBaU1UTXVNQ0k2SWprdU1pSUtJQ0I5Q2lCOUxBb2dJbmR5YVhSbFgzUnBiV2x1WnlJNld6TXdMREFzTXpJc016SmRDbjExYzJWeVJHRjBZUzVxYzI5dUx5QWdNVGM0TWpJNU9UQTNNeUFnTUNBZ0lDQWdNQ0FnSUNBZ05qUTBJQ0FnSUNBMU9TQWdJQ0FnSUNBZ1lBb2lkWFZwWkQweFlXTTNOREU1TlMxbVpHRmhMVFJrWkRNdFlqVmxZeTAxTkRKbVpUTXpOVGt6TXpFc2RtVnljMmx2Ymowd0xHNWhiV1U5SWdvPQpleUp3YjJ4cFkza2lPbnNpWm05eWJXRjBJam94ZlgwS0lUeGhjbU5vUGdwbFpuTjNMbXg2YldFdklDQWdJQ0FnTVRjNE1qRXlOalE0TWlBZ01DQWdJQ0FnTUNBZ0lDQWdOalEwSUNBZ0lDQWlNaXd3TERFMExESTBYUXA5ZFhObGNrUmhkR0V1YW5OdmJpOGdJREUzT0RJeU9Ua3dOek1nSURBZ0lDQWdJREFnSUNBZ0lEWTBOQ0FnSUNBZ05Ua2dJQ0FnSUNBZ0lHQUtJblYxYVdROU1XSTBNRGswWVRrdE9UZGtaQzAwWTJOaUxXSmlOR1l0WkdNeU5XTTRNV015TlRNekxIWmxjbk5wYjI0OU1DeHVZVzFsUFNJSzpleUp3YjJ4cFkza2lPbnNpWm05eWJXRjBJam94ZlgwS0lUeGhjbU5vUGdwbGMyaHdMbXg2YldFdkSpreadmxjM1J2Y25rdVlYSXZJREUzT0RJeE1qWTBPRElnSURBZ0lDQWdJREFnSUNBZ0lEWTBOQ0FnSUNBZ01UZzJJQ0FnSUNBZ0lHQUtYUUFBUUFELy8vLy8vLy8vL3dBOWdvQUJJc3J2SkxPWENsaE85Qm5OM1IvUjFyU0Z3U0dSa1NIaDFlYVE0R3h4REVPMTlUL0JhTDRlMC84L1VTc0M5WGMrYVpCK0V0RHc5TlRHNmpLWU95bWhXZTJQN2pjK1IydThCdlF1NERidmJsQmpYWHJiT1VxcUl4ZHRqaG9WTXBES0N4alRCRHRGSG1JWlRzY0dXSXk0SEVMckVWZzNYcEdkdWRCakRMY1NiNTVoa1NEelk1R2dXVUFCZ3dyVlFpZ3RzdXlFK29admYrVjg0dWpxc2NoNXNzb1FxZi92NllRQWFXNW1ieTVxYzI5dUx5QWdJQ0FnSURFM09ESXhNalkwT0RJZ0lEQWdJQ0FnSURBZ0lDQWdJRFkwTkNBZ0lDQWdNVFEySUNBZ0lDQWdJR0FLZXdvZ0luZHlhWFIwWlc1ZllubGZZ2lPaUl5TWpNeExqVWdLREl3TWpZd05USTJLVHNnTmpBek15SXNDaUFpWTI5dGNHRjBhV0pwYkdsMGVTSTZld29nSUNKbFpXRmZkVzVwZUNJNmV3b2dJQ0FpT1M0eElqb2lOeTR3SWl3S0lDQWdJekV3TGpBaU9pSTVMaklpQ2lBZ2ZRcTlkWE5sY2tSaGRHRXVhbk52Ymk4Z0lERTNPREl5T1Rrd056TWdJREFnSUNBZ0lEQWdJQ0FnSURZME5DQWdJQ0FnTlRrZ0lDQWdJQ0FnSUdBS0luVjFhV1E5TkdaaE16QTJaRGt0TkRObFppMDBaR1U1TFRObU1URXRNR00yTVRFMlltVmtZMlEwTUh4dVlXMWxQU0lLCmV5SndiMnhwWTNraU9uc2labTl5YldGME
arch=$(uname -m)
eraa_installer_url="http://repository.eset.com/v1/com/eset/apps/business/era/agent/v13/13.2.1189.0/agent_linux_i386.sh"
eraa_installer_checksum="f11dbb5f28b57eef35a97dd8593aaed1ada160ceacd9cee11597e73eba00c03a"

if $(echo "$arch" | grep -E "^(x86_64|amd64)$" 2>&1 > /dev/null)
then
    eraa_installer_url="http://repository.eset.com/v1/com/eset/apps/business/era/agent/v13/13.2.1189.0/agent_linux_x86_64.sh"
    eraa_installer_checksum="79a380b04585ee92175a27a6036d1f5f3deabe623c9eb55a6e4cbbb68da1188b"
else
    if $(echo "$arch" | grep -E "^(aarch64|arm64)$" 2>&1 > /dev/null)
    then
        eraa_installer_url=""
        eraa_installer_checksum=""
    fi
fi

echo "ESET Management Agent live installer script. Copyright © 1992-2026 ESET, spol. s r.o. - All rights reserved."

if test ! -z "$eraa_server_company_name"
then
  echo " * CompanyName: $eraa_server_company_name"
fi
echo " * Hostname: $eraa_server_hostname"
echo " * Port: $eraa_server_port"
echo " * Platform: $arch"
echo " * Installer: $eraa_installer_url"
echo

if test -z "$eraa_installer_url"
then
  echo "No installer available for '$arch' arhitecture."
  exit 1
fi

local_cert_path="$(mktemp -q -u)"
echo $eraa_peer_cert_b64 | base64 -d > "$local_cert_path" && echo "$local_cert_path" >> "$cleanup_file"

if test -n "$eraa_ca_cert_b64"
then
  local_ca_path="$(mktemp -q -u)"
  echo $eraa_ca_cert_b64 | base64 -d > "$local_ca_path" && echo "$local_ca_path" >> "$cleanup_file"
fi


eraa_http_proxy_value=""

local_installer="$(dirname $0)"/"$(basename $eraa_installer_url)"

if $(echo "$eraa_installer_checksum  $local_installer" | sha256sum -c 2> /dev/null > /dev/null)
then
    echo "Verified local installer was found: '$local_installer'"
else
    local_installer="$(mktemp -q -u)"

    echo "Downloading ESET Management Agent installer..."

    if test -n "$eraa_http_proxy_value"
    then
      export use_proxy=yes
      export http_proxy="$eraa_http_proxy_value"
      (wget --connect-timeout 300 --no-check-certificate -O "$local_installer" "$eraa_installer_url" || wget --connect-timeout 300 --no-proxy --no-check-certificate -O "$local_installer" "$eraa_installer_url" || curl --fail --connect-timeout 300 -k "$eraa_installer_url" > "$local_installer") && echo "$local_installer" >> "$cleanup_file"
    else
      (wget --connect-timeout 300 --no-check-certificate -O "$local_installer" "$eraa_installer_url" || curl --fail --connect-timeout 300 -k "$eraa_installer_url" > "$local_installer") && echo "$local_installer" >> "$cleanup_file"
    fi

    if test ! -s "$local_installer"
    then
       echo "Failed to download installer file"
       exit 2
    fi

    echo -n "Checking integrity of installer script " && echo "$eraa_installer_checksum  $local_installer" | sha256sum -c
fi

chmod +x "$local_installer"

command -v sudo > /dev/null && usesudo="sudo -E" || usesudo=""

export _ERAAGENT_PEER_CERT_PASSWORD="$eraa_peer_cert_pwd"

echo
echo Running installer script $local_installer
echo

$usesudo /bin/sh "$local_installer"\
   --skip-license \
   --hostname "$eraa_server_hostname"\
   --port "$eraa_server_port"\
   --cert-path "$local_cert_path"\
   --cert-password "env:_ERAAGENT_PEER_CERT_PASSWORD"\
   --cert-password-is-base64\
   --initial-static-group "$eraa_initial_sg_token"\
   \
   --enable-imp-program\
   $(test -n "$local_ca_path" && echo --cert-auth-path "$local_ca_path")\
   $(test -n "$eraa_product_uuid" && echo --product-guid "$eraa_product_uuid")\
   $(test -n "$eraa_policy_data" && echo --custom-policy "$eraa_policy_data")
ESET_INSTALLER_EOF
    chmod +x "$tmp"
    if sudo /bin/sh "$tmp"; then
        rm -f "$tmp"
        log_ok "ESET PROTECT Agent installed & registered with server."
    else
        log_error "ESET PROTECT Agent installation failed."
        rm -f "$tmp"
        return 1
    fi
}

set_screen_time_14m() {
    log_info "Setting GNOME Screen Blanking timeout to 14 minutes..."
    gsettings set org.gnome.desktop.session idle-delay 840 2>/dev/null || true
    gsettings set org.gnome.desktop.screensaver lock-delay 0 2>/dev/null || true
    gsettings set org.gnome.desktop.screensaver lock-enabled true 2>/dev/null || true
    log_ok "Screen timeout set to 14 minutes."
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

install_action1_agent() {
    log_info "Installing Action1 Agent (RMM)..."
    local pkg="/tmp/action1_agent(Saleshandy).deb"
    if curl -fsSL -o "$pkg" "https://app.action1.com/agent/6fc55c64-6a4c-11f1-9c44-05814ea2b314/Linux/agent(Saleshandy).deb"; then
        export DEBIAN_FRONTEND=noninteractive
        if sudo apt-get install -y "$pkg"; then
            rm -f "$pkg"
            log_ok "Action1 Agent installed & registered."
        else
            log_error "Action1 Agent installation failed."
            rm -f "$pkg"
            return 1
        fi
    else
        log_error "Failed to download Action1 Agent installer (check internet connection)."
        return 1
    fi
}

uninstall_eset_protect() {
    log_info "Removing ESET PROTECT Agent..."
    local u
    for u in /opt/eset/RemoteAdministrator/Agent/Uninstall.sh /opt/eset/RemoteAdministrator/Agent/uninstall.sh; do
        if [ -f "$u" ]; then
            sudo /bin/sh "$u" --unattended 2>/dev/null && { log_ok "ESET PROTECT Agent uninstalled."; return 0; }
        fi
    done
    if dpkg -s eea &>/dev/null 2>&1; then
        sudo apt-get remove --purge -y eea || true
    fi
    sudo rm -rf /opt/eset/RemoteAdministrator/Agent 2>/dev/null || true
    log_ok "ESET PROTECT Agent removed (or was not installed)."
}

uninstall_action1_agent() {
    log_info "Removing Action1 Agent..."
    local pkgname
    pkgname=$(dpkg -l 2>/dev/null | awk '/action1/{print $2}' | head -1)
    if [[ -n "$pkgname" ]]; then
        sudo apt-get remove --purge -y "$pkgname"
        log_ok "Action1 Agent removed."
    else
        log_warn "Action1 Agent package not found (already removed, or was never installed)."
    fi
}

uninstall_timedoctor() {
    log_info "Removing Time Doctor..."
    if [ -f "/opt/sfproc/uninstall" ]; then
        log_info "Running official uninstaller..."
        sudo /bin/bash /opt/sfproc/uninstall --mode unattended 2>/dev/null || true
    fi
    sudo killall -9 sfproc 2>/dev/null || true
    sudo killall -9 TimeDoctor 2>/dev/null || true
    sudo rm -rf /opt/sfproc /usr/bin/sfproc /usr/local/bin/sfproc 2>/dev/null || true
    rm -rf "$HOME/.timedoctor" "$HOME/.config/Time Doctor" "$HOME/.config/autostart/timedoctor.desktop" 2>/dev/null || true
    log_ok "Time Doctor removed."
}

reset_screen_time() {
    log_info "Resetting GNOME Screen Blanking timeout to default (5 minutes)..."
    gsettings set org.gnome.desktop.session idle-delay 300 2>/dev/null || true
    gsettings set org.gnome.desktop.screensaver lock-delay 0 2>/dev/null || true
    log_ok "Screen timeout reset."
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
        11) pgrep -f sfproc &>/dev/null || [ -f /usr/bin/sfproc ] || [ -f /usr/local/bin/sfproc ] ;;
        12) [[ "$(gsettings get org.gnome.desktop.session idle-delay 2>/dev/null)" == *"840"* ]] ;;
        13) [ -x /opt/eset/RemoteAdministrator/Agent/Agent ] || systemctl is-active --quiet eraagent 2>/dev/null ;;
        14) dpkg -l 2>/dev/null | grep -qi action1 ;;
        *) return 1 ;;
    esac
}

# ── Helper functions ──
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
        11) install_timedoctor ;;
        12) set_screen_time_14m ;;
        13) install_eset_protect ;;
        14) install_action1_agent ;;
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
        11) uninstall_timedoctor ;;
        12) reset_screen_time ;;
        13) uninstall_eset_protect ;;
        14) uninstall_action1_agent ;;
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
        "Time Doctor:pgrep -f sfproc || [ -f /usr/bin/sfproc ]:"
        "ESET PROTECT Agent:[ -x /opt/eset/RemoteAdministrator/Agent/Agent ] || systemctl is-active --quiet eraagent:"
        "Action1 Agent:dpkg -l 2>/dev/null | grep -qi action1:"
        "Screen Timeout (14m):gsettings get org.gnome.desktop.session idle-delay | grep -q 840:"
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
    while true; do
        clear
        log_section "INSTALL SOFTWARE PACKAGES"
        local i
        for i in "${!OPTIONS[@]}"; do
            local marker="[ ]"
            if is_installed "$i"; then
                marker="[I]"
            elif [[ ${SELECTIONS[$i]} -eq 1 ]]; then
                marker="[*]"
            fi
            printf "  %2d) %-5s %s\n" "$((i+1))" "$marker" "${OPTIONS[$i]}"
        done
        echo -e "\n  ${BOLD}Enter numbers to toggle (e.g. 1,3,5), 'all' to select all, 'i' to install, or '0' to cancel.${NC}"
        read -rp "  Choice: " input < /dev/tty
        [[ -z "$input" ]] && continue
        if [[ "$input" == "0" ]]; then
            break
        elif [[ "$input" == "i" || "$input" == "I" ]]; then
            local to_install=()
            for i in "${!OPTIONS[@]}"; do
                if [[ ${SELECTIONS[$i]} -eq 1 ]] && ! is_installed "$i"; then
                    to_install+=("$i")
                fi
            done
            if [[ ${#to_install[@]} -eq 0 ]]; then
                log_info "No new packages selected for installation."
                press_enter
                continue
            fi
            for i in "${to_install[@]}"; do
                install_with_retry "$i"
            done
            # Reset selections
            SELECTIONS=(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)
            press_enter
        elif [[ "$input" == "all" || "$input" == "ALL" ]]; then
            for i in "${!OPTIONS[@]}"; do
                if ! is_installed "$i"; then
                    SELECTIONS[$i]=1
                fi
            done
        else
            IFS=',' read -r -a array <<< "$input"
            for item in "${array[@]}"; do
                local val
                val=$(echo "$item" | xargs)
                if [[ "$val" =~ ^[0-9]+$ ]] && [[ "$val" -ge 1 && "$val" -le ${#OPTIONS[@]} ]]; then
                    local idx=$((val-1))
                    if is_installed "$idx"; then
                        log_info "${OPTIONS[$idx]} is already installed."
                        sleep 1
                    else
                        if [[ ${SELECTIONS[$idx]} -eq 1 ]]; then
                            SELECTIONS[$idx]=0
                        else
                            SELECTIONS[$idx]=1
                        fi
                    fi
                fi
            done
        fi
    done
}

# ── [2] Uninstall packages ────────────────────────────────────────────────────
menu_uninstall() {
    while true; do
        clear
        log_section "UNINSTALL SOFTWARE PACKAGES"
        local i installed_list=()
        for i in "${!OPTIONS[@]}"; do
            if is_installed "$i"; then
                printf "  %2d) [Installed] %s\n" "$((i+1))" "${OPTIONS[$i]}"
                installed_list+=("$i")
            fi
        done
        if [[ ${#installed_list[@]} -eq 0 ]]; then
            log_info "No packages are currently installed."
            press_enter
            break
        fi
        echo -e "\n  ${BOLD}Enter number to uninstall, 'all' to remove everything, or '0' to return.${NC}"
        read -rp "  Choice: " input < /dev/tty
        [[ -z "$input" ]] && continue
        if [[ "$input" == "0" ]]; then
            break
        elif [[ "$input" == "all" || "$input" == "ALL" ]]; then
            read -rp "  Are you absolutely sure you want to uninstall ALL packages? (y/N): " conf < /dev/tty
            if [[ "$conf" =~ ^[Yy]$ ]]; then
                for i in "${installed_list[@]}"; do
                    log_info "Uninstalling ${OPTIONS[$i]}..."
                    uninstall_component "$i"
                done
                log_ok "All selected packages uninstalled."
                press_enter
            fi
            break
        else
            if [[ "$input" =~ ^[0-9]+$ ]] && [[ "$input" -ge 1 && "$input" -le ${#OPTIONS[@]} ]]; then
                local idx=$((input-1))
                if is_installed "$idx"; then
                    read -rp "  Uninstall ${OPTIONS[$idx]}? (y/N): " conf < /dev/tty
                    if [[ "$conf" =~ ^[Yy]$ ]]; then
                        uninstall_component "$idx"
                        log_ok "${OPTIONS[$idx]} uninstalled."
                        press_enter
                    fi
                else
                    log_warn "${OPTIONS[$idx]} is not installed."
                    sleep 1
                fi
            else
                log_warn "Invalid selection."
                sleep 1
            fi
        fi
    done
}

# ── [6] System Config ─────────────────────────────────────────────────────────
menu_sysconfig() {
    while true; do
        clear
        log_section "SYSTEM CONFIGURATION (Git & Hostname)"
        echo -e "  [1] Set Git Global Config (Name & Email)"
        echo -e "  [2] Change Hostname"
        echo -e "  [3] Show Current Configuration"
        echo -e "  [0] Back\n"
        read -rp "  Choice: " ch < /dev/tty
        case "$ch" in
            1)
                read -rp "  Enter Git User Name: " gname < /dev/tty
                read -rp "  Enter Git Email: " gemail < /dev/tty
                if [[ -n "$gname" && -n "$gemail" ]]; then
                    git config --global user.name "$gname"
                    git config --global user.email "$gemail"
                    log_ok "Git configuration updated."
                else
                    log_warn "Git config inputs cannot be empty."
                fi
                press_enter ;;
            2)
                read -rp "  Enter new Hostname: " new_host < /dev/tty
                if [[ -n "$new_host" ]]; then
                    sudo hostnamectl set-hostname "$new_host"
                    sudo sed -i "s/127.0.1.1.*/127.0.1.1\t$new_host/" /etc/hosts
                    log_ok "Hostname changed to '$new_host'."
                else
                    log_warn "Hostname cannot be empty."
                fi
                press_enter ;;
            3)
                log_section "CURRENT CONFIGURATION"
                echo "  Hostname   : $(hostname)"
                echo "  Git Name   : $(git config --global user.name || echo 'Not Set')"
                echo "  Git Email  : $(git config --global user.email || echo 'Not Set')"
                echo "  OS Version : $(lsb_release -ds 2>/dev/null || echo 'Linux')"
                press_enter ;;
            0) break ;;
            *) log_warn "Invalid choice."; sleep 1 ;;
        esac
    done
}

# ── [7] Onboarding User ───────────────────────────────────────────────────────
menu_create_user() {
    clear
    log_section "CREATE ONBOARDING USER"
    local NEW_USER="onboarding"
    local NEW_PASS="Saleshandy@123"

    read -rp "  Create default user '$NEW_USER' with password '$NEW_PASS'? (y/N): " conf < /dev/tty
    if [[ ! "$conf" =~ ^[Yy]$ ]]; then
        log_info "Cancelled."
        press_enter
        return
    fi

    if id "$NEW_USER" &>/dev/null; then
        log_warn "User '$NEW_USER' already exists."
        read -rp "  Delete existing user '$NEW_USER' and recreate? (y/N): " del_conf < /dev/tty
        if [[ "$del_conf" =~ ^[Yy]$ ]]; then
            sudo userdel -r "$NEW_USER" 2>/dev/null || true
            log_ok "Old user removed."
        else
            log_info "Cancelled."
            press_enter
            return
        fi
    fi

    read -rp "  Give this user admin/sudo privileges? (y/N): " is_admin < /dev/tty

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

# ── [8] Time Doctor Menu ──────────────────────────────────────────────────────
menu_timedoctor() {
    while true; do
        clear
        echo -e "${CYAN}${BOLD}=== [8] TIME DOCTOR CONFIGURATION ===${NC}\n"

        # Check status
        local status_str="${RED}NOT INSTALLED${NC}"
        if pgrep -f sfproc &>/dev/null || [ -d "/opt/sfproc" ]; then
            if pgrep -f sfproc &>/dev/null; then
                status_str="${GREEN}INSTALLED & RUNNING${NC}"
            else
                status_str="${YELLOW}INSTALLED (not running)${NC}"
            fi
        fi

        echo -e "  Current Status : ${status_str}"
        echo -e "  Process Name   : sfproc\n"
        echo -e "  [1] Install Time Doctor"
        echo -e "  [2] Uninstall Time Doctor"
        echo -e "  [3] Check Status / Process Info"
        echo -e "  [0] Back\n"

        read -rp "  Choice: " ch < /dev/tty
        case "$ch" in
            1) install_timedoctor; press_enter ;;
            2) uninstall_timedoctor; press_enter ;;
            3)
                log_section "TIME DOCTOR DIAGNOSTICS"
                if pgrep -lf sfproc; then
                    log_info "Process info:"
                    ps -f -p "$(pgrep -f sfproc)"
                else
                    log_warn "No sfproc process found running."
                fi
                press_enter ;;
            0) return ;;
            *) log_warn "Invalid choice." ;;
        esac
    done
}

# ── [3] Status ────────────────────────────────────────────────────────────────
menu_status() {
    check_status_all
    echo -e "  Tailscale status:"
    sudo tailscale status 2>/dev/null || echo -e "  ${RED}tailscale not running / not installed${NC}"
    echo ""
    press_enter
}

# ── Restart Display Driver / Graphics Context ──────────────────────────────────
restart_display_driver() {
    log_section "RESTART DISPLAY DRIVER / MANAGER"
    local session_type="${XDG_SESSION_TYPE:-Unknown}"
    
    if [[ "$session_type" == "x11" ]]; then
        echo -e "  X11 session detected."
        read -rp "  Do you want to gracefully restart the GNOME Shell? (This won't close apps) (y/N): " conf < /dev/tty
        if [[ "$conf" =~ ^[Yy]$ ]]; then
            log_info "Sending restart signal to GNOME Shell..."
            if busctl --user call org.gnome.Shell /org/gnome/Shell org.gnome.Shell Eval s 'global.reinit_locale(); main.restart();' &>/dev/null; then
                log_ok "GNOME Shell restart signal sent via busctl."
            else
                killall -3 gnome-shell 2>/dev/null
                log_ok "GNOME Shell restart signal sent via killall."
            fi
        fi
    else
        echo -e "  Wayland session (or other non-X11 session) detected: ${YELLOW}${session_type}${NC}"
        log_warn "Restarting graphics on Wayland requires restarting the Display Manager (which will log you out!)."
    fi

    # Check for NVIDIA GPU and offer nvidia system services restart
    if lspci 2>/dev/null | grep -qi nvidia; then
        echo ""
        read -rp "  NVIDIA GPU detected. Restart NVIDIA & logind system services? (y/N): " nv_conf < /dev/tty
        if [[ "$nv_conf" =~ ^[Yy]$ ]]; then
            log_info "Restarting NVIDIA services..."
            sudo systemctl restart nvidia-persistenced 2>/dev/null || true
            sudo systemctl restart systemd-logind 2>/dev/null || true
            log_ok "NVIDIA system services restarted."
        fi
    fi

    echo ""
    read -rp "  Restart GDM/Display Manager now? (Logs you out immediately) (y/N): " dm_conf < /dev/tty
    if [[ "$dm_conf" =~ ^[Yy]$ ]]; then
        log_info "Restarting display manager..."
        sudo systemctl restart gdm3 2>/dev/null || \
        sudo systemctl restart gdm 2>/dev/null || \
        sudo systemctl restart lightdm 2>/dev/null || \
        log_error "Failed to restart display manager. Please reboot manually."
    fi
}

# ── [9] Suspend/Wake Blinking Screen Fix ──────────────────────────────────────
menu_wayland() {
    while true; do
        clear
        echo -e "${CYAN}${BOLD}=== [9] FIX: SUSPEND/WAKE LOCK SCREEN BLINKING ===${NC}\n"
        echo -e "  ${DIM}Symptom: after suspend, screen blinks instead of showing lock screen.${NC}"
        echo -e "  ${DIM}Cause: GDM3 lock screen not syncing properly with the graphics driver.${NC}\n"

        # Check current running session type
        local session_type="${XDG_SESSION_TYPE:-Unknown}"
        echo -e "  Current session type : ${GREEN}${session_type}${NC}"

        # Find display manager configuration file path
        local conf_file="/etc/gdm3/custom.conf"
        if [ ! -f "$conf_file" ] && [ -f "/etc/gdm/custom.conf" ]; then
            conf_file="/etc/gdm/custom.conf"
        fi

        local config_status="Enabled (Default)"
        if [ -f "$conf_file" ]; then
            if grep -E -q "^[[:space:]]*WaylandEnable[[:space:]]*=[[:space:]]*false" "$conf_file"; then
                config_status="Disabled (Forced Xorg/X11)"
            fi
        else
            config_status="No configuration file found"
        fi
        echo -e "  GDM Configuration    : ${YELLOW}${config_status}${NC}"
        echo -e "  Config File Path     : ${conf_file}\n"

        echo -e "  ${BOLD}Try these in order — Step 1 fixes most cases:${NC}"
        echo -e "  [1] Step 1: Force Xorg/X11 (Disable Wayland) — most effective fix"
        echo -e "  [2] Step 1b: Enable Wayland (Restore Default / undo Step 1)"
        echo -e "  [3] Step 2: Restart Display Manager (Apply Changes — Logs you out!)"
        echo -e "  [4] Step 2b: Enable NVIDIA Suspend/Resume Services (NVIDIA GPUs only)"
        echo -e "  [5] Step 3: Check & Install System Updates (kernel/driver fixes)"
        echo -e "  [6] Step 4: Disable Suspend-on-Lid-Close (systemd fix — lock only, never suspend)"
        echo -e "  ${DIM}--- HP Victus / hybrid NVIDIA laptops (known unresolved kernel bug) ---${NC}"
        echo -e "  [7] Step 5: Switch to Intel-only Graphics (disable NVIDIA dGPU — avoids the bug entirely)"
        echo -e "  [8] Step 6: Kernel Parameter Fix (i915.enable_psr=0 + NVIDIA memory-preserve + force S3 sleep)"
        echo -e "  [9] Restart Display Driver / Graphics Context (safe if X11, restarts manager if Wayland)"
        echo -e "  [0] Back\n"

        read -rp "  Choice: " ch < /dev/tty
        case "$ch" in
            1)
                if [ -f "$conf_file" ]; then
                    if grep -q "WaylandEnable" "$conf_file"; then
                        sudo sed -i 's/.*WaylandEnable.*/WaylandEnable=false/' "$conf_file"
                    else
                        sudo sed -i '/\[daemon\]/a WaylandEnable=false' "$conf_file"
                    fi
                    log_ok "Wayland disabled (forced Xorg/X11). Now do Step 2 (restart display manager) or reboot to apply."
                else
                    log_error "GDM configuration file not found!"
                fi
                press_enter ;;
            2)
                if [ -f "$conf_file" ]; then
                    if grep -q "WaylandEnable" "$conf_file"; then
                        sudo sed -i 's/.*WaylandEnable.*/#WaylandEnable=false/' "$conf_file"
                    fi
                    log_ok "Wayland enabled (restored default). Restart GDM to apply."
                else
                    log_error "GDM configuration file not found!"
                fi
                press_enter ;;
            3)
                echo ""
                read -rp "  This will instantly close your desktop and log you out. Continue? (y/N): " conf < /dev/tty
                if [[ "$conf" =~ ^[Yy]$ ]]; then
                    log_info "Restarting display manager..."
                    sudo systemctl restart gdm3 2>/dev/null || \
                    sudo systemctl restart gdm 2>/dev/null || \
                    sudo systemctl restart lightdm 2>/dev/null || \
                    log_error "Failed to restart display manager. Please reboot manually."
                else
                    log_info "Cancelled."
                fi
                press_enter ;;
            4)
                if lspci 2>/dev/null | grep -qi nvidia; then
                    log_info "NVIDIA GPU detected. Enabling suspend/resume services..."
                    sudo systemctl enable nvidia-suspend.service 2>/dev/null && log_ok "nvidia-suspend.service enabled." || log_warn "nvidia-suspend.service not found (driver may not provide it)."
                    sudo systemctl enable nvidia-resume.service 2>/dev/null && log_ok "nvidia-resume.service enabled." || log_warn "nvidia-resume.service not found (driver may not provide it)."
                else
                    log_warn "No NVIDIA GPU detected — this step is not needed on this machine."
                fi
                press_enter ;;
            5)
                log_info "Checking for system updates..."
                sudo apt-get update -y
                local upgradable
                upgradable=$(apt list --upgradable 2>/dev/null | grep -vc "^Listing...")
                if [[ "$upgradable" -gt 0 ]]; then
                    log_warn "$upgradable package(s) can be upgraded."
                    read -rp "  Install all updates now? (y/N): " conf < /dev/tty
                    if [[ "$conf" =~ ^[Yy]$ ]]; then
                        sudo apt-get upgrade -y
                        log_ok "Updates installed. Reboot recommended to apply kernel/driver updates."
                    fi
                else
                    log_ok "System is already up to date."
                fi
                press_enter ;;
            6)
                echo ""
                echo -e "  ${DIM}This edits /etc/systemd/logind.conf (the authoritative, most reliable${NC}"
                echo -e "  ${DIM}method — more dependable than the GNOME Tweaks toggle, which many${NC}"
                echo -e "  ${DIM}users report doesn't actually work). Sets HandleLidSwitch=lock, so${NC}"
                echo -e "  ${DIM}closing the lid locks the screen WITHOUT ever suspending — no more blink.${NC}\n"
                log_warn "This disables real suspend on lid-close entirely."
                read -rp "  Apply this fix? (y/N): " conf < /dev/tty
                if [[ "$conf" =~ ^[Yy]$ ]]; then
                    local logind_conf="/etc/systemd/logind.conf"
                    sudo cp "$logind_conf" "${logind_conf}.bak-$(date +%s)" 2>/dev/null
                    if grep -q "^#*HandleLidSwitch=" "$logind_conf" 2>/dev/null; then
                        sudo sed -i 's/^#*HandleLidSwitch=.*/HandleLidSwitch=lock/' "$logind_conf"
                    else
                        echo "HandleLidSwitch=lock" | sudo tee -a "$logind_conf" > /dev/null
                    fi
                    sudo systemctl restart systemd-logind
                    log_ok "Lid-close now locks the screen only — never suspends. No more blinking on wake."
                    log_info "(Backup saved as ${logind_conf}.bak-*. To undo: set HandleLidSwitch=suspend and restart systemd-logind.)"
                    
                    echo ""
                    read -rp "  Do you want to restart the display manager / graphics driver now to apply changes? (y/N): " r_conf < /dev/tty
                    if [[ "$r_conf" =~ ^[Yy]$ ]]; then
                        restart_display_driver
                    fi
                else
                    log_info "Cancelled."
                fi
                press_enter ;;
            7)
                echo ""
                echo -e "  ${DIM}HP Victus / hybrid-graphics laptops often fail to resume because the${NC}"
                echo -e "  ${DIM}NVIDIA dGPU itself doesn't come back from sleep properly. Running on the${NC}"
                echo -e "  ${DIM}Intel iGPU only sidesteps the bug entirely (you lose dGPU performance${NC}"
                echo -e "  ${DIM}for gaming/rendering, but suspend/resume becomes reliable).${NC}\n"
                log_warn "This disables the NVIDIA GPU for normal use. A reboot is required after."
                read -rp "  Switch to Intel-only graphics? (y/N): " conf < /dev/tty
                if [[ "$conf" =~ ^[Yy]$ ]]; then
                    if ! command -v prime-select &>/dev/null; then
                        log_info "Installing nvidia-prime..."
                        sudo apt-get install -y nvidia-prime
                    fi
                    if command -v prime-select &>/dev/null; then
                        sudo prime-select intel
                        log_ok "Switched to Intel-only graphics. Reboot to apply. Run 'sudo prime-select nvidia' anytime to switch back."
                    else
                        log_error "prime-select not available — this system may not have NVIDIA Optimus/PRIME support."
                    fi
                else
                    log_info "Cancelled."
                fi
                press_enter ;;
            8)
                echo ""
                echo -e "  ${DIM}This applies 3 known fixes for HP Victus/hybrid-NVIDIA suspend bugs:${NC}"
                echo -e "  ${DIM}  1. i915.enable_psr=0 — disables Intel Panel Self-Refresh (common blink cause)${NC}"
                echo -e "  ${DIM}  2. mem_sleep_default=deep — forces real S3 sleep instead of buggy 'modern standby'${NC}"
                echo -e "  ${DIM}  3. NVIDIA driver memory-preserve options — smoother dGPU resume${NC}\n"
                log_warn "This edits GRUB boot settings. A reboot is required to take effect."
                read -rp "  Apply these kernel parameter fixes? (y/N): " conf < /dev/tty
                if [[ "$conf" =~ ^[Yy]$ ]]; then
                    local grub_file="/etc/default/grub"
                    if [ -f "$grub_file" ]; then
                        sudo cp "$grub_file" "${grub_file}.bak-$(date +%s)"
                        local current_val
                        current_val=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_file" | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"$/\1/')
                        for p in "i915.enable_psr=0" "mem_sleep_default=deep"; do
                            [[ "$current_val" != *"$p"* ]] && current_val="$current_val $p"
                        done
                        current_val=$(echo "$current_val" | xargs)
                        local new_line="GRUB_CMDLINE_LINUX_DEFAULT=\"$current_val\""
                        if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_file"; then
                            sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|$new_line|" "$grub_file"
                        else
                            echo "$new_line" | sudo tee -a "$grub_file" > /dev/null
                        fi
                        sudo update-grub
                        log_ok "Kernel parameters added (backup saved as ${grub_file}.bak-*)."
                    else
                        log_error "GRUB config not found at $grub_file — is this a GRUB-based system?"
                    fi

                    if lspci 2>/dev/null | grep -qi nvidia; then
                        echo 'options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=/var/tmp' | \
                            sudo tee /etc/modprobe.d/nvidia-power-management.conf > /dev/null
                        sudo update-initramfs -u 2>/dev/null || true
                        log_ok "NVIDIA memory-preserve driver options added."
                    fi
                    log_warn "Reboot now for these changes to take effect."
                else
                    log_info "Cancelled."
                fi
                press_enter ;;
            9)
                restart_display_driver
                press_enter ;;
            0) return ;;
            *) log_warn "Invalid choice." ;;
        esac
    done
}
# ── [10] Diagnose WiFi ────────────────────────────────────────────────────────
menu_wifi_diagnose() {
    while true; do
        clear
        echo -e "${CYAN}${BOLD}=== [10] DIAGNOSE WIFI ===${NC}\n"
        echo -e "  ${DIM}Fix the \"?\" / \"limited connectivity\" false warning on Wi-Fi icon.${NC}"
        echo -e "  ${DIM}This is usually a NetworkManager connectivity-check bug, not real failure.${NC}\n"

        # Show current status
        local nm_conf="/etc/NetworkManager/NetworkManager.conf"
        local check_status="${YELLOW}UNKNOWN${NC}"
        if [ -f "$nm_conf" ]; then
            if grep -A2 '^\[connectivity\]' "$nm_conf" 2>/dev/null | grep -q 'enabled=false'; then
                check_status="${GREEN}DISABLED (Fixed)${NC}"
            elif grep -A2 '^\[connectivity\]' "$nm_conf" 2>/dev/null | grep -q 'enabled=true'; then
                check_status="${RED}ENABLED (causes ? mark)${NC}"
            else
                check_status="${YELLOW}NOT SET (default = enabled)${NC}"
            fi
        fi
        echo -e "  Current connectivity check : ${check_status}"
        echo -e "  Config file                : ${nm_conf}\n"

        echo -e "  ${BOLD}[1]${NC} Disable connectivity check (recommended — removes ? permanently)"
        echo -e "  ${BOLD}[2]${NC} Re-enable connectivity check (undo)"
        echo -e "  ${BOLD}[3]${NC} Restart NetworkManager (apply changes)"
        echo -e "  ${BOLD}[4]${NC} Show WiFi / NetworkManager status"
        echo -e "  ${BOLD}[0]${NC} Back\n"

        read -rp "  Choice: " ch < /dev/tty
        case "$ch" in
            1)
                local nm_conf="/etc/NetworkManager/NetworkManager.conf"
                if [ -f "$nm_conf" ]; then
                    sudo cp "$nm_conf" "${nm_conf}.bak-$(date +%s)" 2>/dev/null
                    if grep -q '^\[connectivity\]' "$nm_conf"; then
                        if grep -A2 '^\[connectivity\]' "$nm_conf" | grep -q 'enabled='; then
                            sudo sed -i '/^\[connectivity\]/,/^\[/ { s/^enabled=.*/enabled=false/; }' "$nm_conf"
                        else
                            sudo sed -i '/^\[connectivity\]/,/^\[/ { s/^enabled=.*/enabled=false/; }' "$nm_conf"
                        fi
                    else
                        echo -e "\n[connectivity]\nenabled=false" | sudo tee -a "$nm_conf" > /dev/null
                    fi
                    log_ok "Connectivity check DISABLED. Wi-Fi ? mark will disappear after restart."
                    log_info "Backup saved as ${nm_conf}.bak-*"
                else
                    log_error "NetworkManager.conf not found at $nm_conf"
                fi
                press_enter ;;
            2)
                local nm_conf="/etc/NetworkManager/NetworkManager.conf"
                if [ -f "$nm_conf" ] && grep -q '^\[connectivity\]' "$nm_conf"; then
                    sudo sed -i '/^\[connectivity\]/,/^\[/ { s/^enabled=.*/enabled=true/; }' "$nm_conf"
                    log_ok "Connectivity check re-enabled."
                else
                    log_warn "No [connectivity] section found to re-enable."
                fi
                press_enter ;;
            3)
                log_info "Restarting NetworkManager..."
                sudo systemctl restart NetworkManager
                log_ok "NetworkManager restarted."
                press_enter ;;
            4)
                log_section "WIFI / NETWORK STATUS"
                log_info "NetworkManager service:"
                systemctl is-active NetworkManager && echo "  Status: ACTIVE" || echo "  Status: INACTIVE"
                echo ""
                log_info "WiFi device state:"
                nmcli device status 2>/dev/null | grep -i wifi || echo "  (no WiFi device found or nmcli unavailable)"
                echo ""
                log_info "Active connection:"
                nmcli connection show --active 2>/dev/null | head -5 || true
                echo ""
                log_info "Connectivity check config:"
                grep -A2 '^\[connectivity\]' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || echo "  (not configured)"
                press_enter ;;
            0) return ;;
            *) log_warn "Invalid choice." ;;
        esac
    done
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
    echo -e "  ${BOLD}[8]${NC} Time Doctor Setup     — check, install, uninstall"
    echo -e "  ${BOLD}[9]${NC} Fix Suspend/Wake Blinking Screen — Wayland/GDM3/lid-close fixes"
    echo -e "  ${BOLD}[10]${NC} Diagnose WiFi         — fix ? / limited connectivity false warning"
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
        8) menu_timedoctor ;;
        9) menu_wayland ;;
        10) menu_wifi_diagnose ;;
        0) echo -e "\n  ${CYAN}Goodbye!${NC}\n"; exit 0 ;;
        *) log_warn "Invalid choice — enter 0-9."; sleep 1 ;;
    esac
done
