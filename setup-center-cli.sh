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

# ── Local NAS app cache ────────────────────────────────────────────────────────
# Installers are large and some upstream CDNs are flaky/geo-blocked. If the
# office NAS is reachable, pull from its local cache instead — falls straight
# through to the original web URL if it isn't (laptop off-site, NAS down, etc).
LOCAL_APPS_BASE="http://192.168.126.21:8001/linux/apps"

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
    "Action1 Agent (RMM)"
    "ClamAV Antivirus (clamav & clamav-daemon)"
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
        local nvm_script="$HOME/.sc_tmp/nvm-install.sh"; mkdir -p "$HOME/.sc_tmp"
        curl -fsSL --max-time 5 -o "$nvm_script" "$LOCAL_APPS_BASE/nvm-install.sh" 2>/dev/null || \
            curl -fsSL -o "$nvm_script" https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh || { log_error "NVM install failed."; return 1; }
        bash "$nvm_script" || { log_error "NVM install failed."; return 1; }
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
    curl -fsSL --max-time 5 -o "$tmp" "$LOCAL_APPS_BASE/google-chrome-stable_current_amd64.deb" 2>/dev/null || \
        wget -O "$tmp" "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" || { log_error "Download failed."; return 1; }
    sudo apt-get install -y "$tmp"; rm -f "$tmp"
}

install_vscode() {
    log_info "Installing Visual Studio Code..."
    command -v gpg &>/dev/null || sudo apt-get install -y gnupg
    local key_tmp="$HOME/.sc_tmp/microsoft.asc"; mkdir -p "$HOME/.sc_tmp"
    curl -fsSL --max-time 5 -o "$key_tmp" "$LOCAL_APPS_BASE/microsoft.asc" 2>/dev/null || \
        wget -qO "$key_tmp" https://packages.microsoft.com/keys/microsoft.asc
    gpg --dearmor < "$key_tmp" | sudo tee /etc/apt/keyrings/packages.microsoft.gpg > /dev/null
    rm -f "$key_tmp"
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
    curl -fsSL --max-time 5 -o "$tmp" "$LOCAL_APPS_BASE/dbeaver-ce_latest_amd64.deb" 2>/dev/null || \
        wget -O "$tmp" "https://dbeaver.io/files/dbeaver-ce_latest_amd64.deb" || { log_error "Download failed."; return 1; }
    sudo apt-get install -y "$tmp"; rm -f "$tmp"
}

install_postman()      { log_info "Installing Postman...";      sudo snap install postman; }
install_redisinsight() { log_info "Installing Redis Insight..."; sudo snap install redisinsight; }

install_mongodb_compass() {
    log_info "Installing MongoDB Compass..."
    local tmp="$HOME/.sc_tmp/mongodb-compass.deb"; mkdir -p "$HOME/.sc_tmp"
    curl -fsSL --max-time 5 -o "$tmp" "$LOCAL_APPS_BASE/mongodb-compass_1.43.0_amd64.deb" 2>/dev/null || \
        wget -O "$tmp" "https://downloads.mongodb.com/compass/mongodb-compass_1.43.0_amd64.deb" || { log_error "Download failed."; return 1; }
    sudo apt-get install -y "$tmp"; rm -f "$tmp"
}

install_tailscale() {
    log_info "Installing Tailscale VPN (official script)..."
    local ts_script="$HOME/.sc_tmp/tailscale-install.sh"; mkdir -p "$HOME/.sc_tmp"
    curl -fsSL --max-time 5 -o "$ts_script" "$LOCAL_APPS_BASE/tailscale-install.sh" 2>/dev/null || \
        curl -fsSL -o "$ts_script" https://tailscale.com/install.sh || { log_error "Tailscale install failed."; return 1; }
    sh "$ts_script" || { log_error "Tailscale install failed."; return 1; }
    sudo systemctl enable --now tailscaled 2>/dev/null || true
    sudo systemctl restart tailscaled 2>/dev/null || true
    log_ok "Tailscale installed successfully."
    install_saleshandy_tray
}

# Saleshandy Tailscale Tray — custom GNOME tray app (replaces the buggy
# tailscale-status@maxgallup.github.com extension). Always uses `tailscale set`
# (never `up --reset`), so switching exit-node never silently resets unrelated
# prefs like exit-node-allow-lan-access or the operator setting.
install_saleshandy_tray() {
    # Don't rely on $XDG_CURRENT_DESKTOP alone — it's only set by the display
    # manager for GUI-launched sessions, so it's empty over SSH or su/sudo
    # subshells even on a real GNOME desktop. Fall back to checking whether
    # gnome-shell is actually installed, which is invocation-independent.
    local desktop="${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-}}"
    if ! echo "$desktop" | grep -qi "gnome" && ! command -v gnome-shell &>/dev/null; then
        log_warn "GNOME not detected (desktop='$desktop') — Saleshandy Tailscale Tray targets GNOME's AppIndicator support. Skipping."
        return 0
    fi

    log_info "Installing Saleshandy Tailscale Tray (GUI exit-node switcher)..."
    sudo apt-get update -y
    sudo apt-get install -y gir1.2-ayatanaappindicator3-0.1 || { log_error "Failed to install gir1.2-ayatanaappindicator3-0.1."; return 1; }

    log_info "Granting $USER operator rights over tailscale (no sudo needed for day-to-day switching)..."
    sudo tailscale set --operator="$USER" 2>/dev/null || log_warn "Could not set tailscale operator yet — run 'sudo tailscale set --operator=$USER' after logging in."

    mkdir -p "$HOME/.local/bin"
    cat > "$HOME/.local/bin/saleshandy-tailscale-tray.py" <<'PYEOF'
#!/usr/bin/env python3
"""Saleshandy Tailscale Tray — GNOME tray indicator for Tailscale/Headscale (bifrost.saleshandy.com).

Replaces the buggy tailscale-status@maxgallup.github.com extension. Key differences:
  - Always uses `tailscale set` (never `up --reset`), so toggling one preference
    never silently resets unrelated ones (that reset behaviour is what broke
    exit-node-allow-lan-access and the operator setting before).
  - If a command fails because the operator isn't set, it prompts once via
    pkexec to fix that, then retries unprivileged - no more permission dance
    on every click.
"""
import fcntl
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import threading

import gi
gi.require_version('Gtk', '3.0')
gi.require_version('AyatanaAppIndicator3', '0.1')
from gi.repository import Gtk, GLib, AyatanaAppIndicator3 as AppIndicator3

TAILSCALE = shutil.which('tailscale') or '/usr/bin/tailscale'
APP_ID = 'saleshandy-tailscale-tray'
LOCK_PATH = os.path.expanduser('~/.cache/saleshandy-tailscale-tray.lock')
LOGIN_SERVER = 'https://bifrost.saleshandy.com'
# Auto-sends the login link here instead of leaving it to find in a terminal.
# Only reachable on the office LAN — off-site this send will just fail quietly
# and the link is still visible in `tailscale status` / journalctl as before.
NTFY_URL = 'http://192.168.126.101:8080/priyanshu-setup'

# ── Self-update ──────────────────────────────────────────────────────────────
# Bump this on every change that should roll out automatically. Checked
# against the same number embedded in whichever copy of this file is fetched
# below - NAS first (fast, LAN-only), GitHub as the fallback.
SCRIPT_VERSION = 2
UPDATE_CHECK_INTERVAL_SEC = 1800  # 30 minutes
UPDATE_SOURCES = (
    'http://192.168.126.21:8000/setup-center-cli.sh',
    'https://raw.githubusercontent.com/priyanshusaleshandy/ubuntu-setup/main/setup-center-cli.sh',
)


def _extract_embedded_tray_script(sh_text):
    m = re.search(
        r"cat > \"\$HOME/\.local/bin/saleshandy-tailscale-tray\.py\" <<'PYEOF'\n(.*?)\nPYEOF",
        sh_text, re.DOTALL)
    return m.group(1) if m else None


def _fetch_latest_tray_script():
    """Returns (version, script_text) for the newest copy of this script found
    across UPDATE_SOURCES (NAS first, GitHub fallback), or (None, None)."""
    for url in UPDATE_SOURCES:
        try:
            r = subprocess.run(['curl', '-fsSL', '--max-time', '8', url],
                                capture_output=True, text=True, timeout=12)
        except Exception:
            continue
        if r.returncode != 0 or not r.stdout:
            continue
        new_script = _extract_embedded_tray_script(r.stdout)
        if not new_script:
            continue
        m = re.search(r'^SCRIPT_VERSION\s*=\s*(\d+)', new_script, re.MULTILINE)
        if m:
            return int(m.group(1)), new_script
    return None, None


def acquire_single_instance_lock():
    """Returns an open file handle holding an exclusive lock, or None if
    another instance already holds it. Caller must keep the handle alive
    for the process lifetime."""
    os.makedirs(os.path.dirname(LOCK_PATH), exist_ok=True)
    lock_file = open(LOCK_PATH, 'w')
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return None
    return lock_file


def ts(*args, timeout=15):
    try:
        return subprocess.run([TAILSCALE, *args], capture_output=True, text=True, timeout=timeout)
    except Exception as e:
        return subprocess.CompletedProcess(args, 1, '', str(e))


def get_status():
    r = ts('status', '--json')
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return None


def node_name(peer):
    """Tailscale/Headscale display name (e.g. 'ikigai-office-network-node-1'),
    not the peer's raw OS hostname (e.g. 'WIN-PLGNKME7A7F')."""
    dns = peer.get('DNSName') or ''
    return dns.split('.')[0] or peer.get('HostName') or ''


def get_prefs():
    r = ts('debug', 'prefs')
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return None


class TailscaleTray:
    def __init__(self):
        self.indicator = AppIndicator3.Indicator.new(
            APP_ID, 'network-vpn-symbolic',
            AppIndicator3.IndicatorCategory.APPLICATION_STATUS)
        self.indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
        self.menu = Gtk.Menu()
        self.menu.connect('show', lambda _w: self.refresh())
        self.indicator.set_menu(self.menu)
        self.last_error = None
        self.info_message = None
        self._login_thread = None
        self._update_thread = None
        self._dismissed_version = None  # version the user said "No" to - don't re-prompt for it
        self.refresh()
        GLib.timeout_add_seconds(120, lambda: (self._check_for_update(), False)[1])  # early one-shot
        GLib.timeout_add_seconds(UPDATE_CHECK_INTERVAL_SEC, lambda: (self._check_for_update(), True)[1])

    def _append_label(self, text, sensitive=False):
        item = Gtk.MenuItem(label=text)
        item.set_sensitive(sensitive)
        self.menu.append(item)

    def _append_separator(self):
        self.menu.append(Gtk.SeparatorMenuItem())

    def _append_footer(self):
        self._append_separator()
        refresh_item = Gtk.MenuItem(label='Refresh')
        refresh_item.connect('activate', lambda _: self.refresh())
        self.menu.append(refresh_item)
        quit_item = Gtk.MenuItem(label='Quit')
        quit_item.connect('activate', lambda _: Gtk.main_quit())
        self.menu.append(quit_item)
        self._append_separator()
        self._append_label('Made by Priyanshu')

    def refresh(self):
        status = get_status()
        prefs = get_prefs()

        for child in self.menu.get_children():
            self.menu.remove(child)

        if status is None or status.get('BackendState') != 'Running':
            state = status.get('BackendState', 'unknown') if status else 'unreachable'
            self._append_label(f'Tailscale: {state}')
            self._append_separator()
            if status and status.get('BackendState') == 'Stopped':
                up_item = Gtk.MenuItem(label='Connect')
                up_item.connect('activate', self._on_connect)
                self.menu.append(up_item)
            login_item = Gtk.MenuItem(label='Login (send code to ntfy)')
            login_item.connect('activate', self._on_login)
            self.menu.append(login_item)
            if self.info_message:
                self._append_separator()
                self._append_label(f'ℹ {self.info_message}')
            if self.last_error:
                self._append_separator()
                self._append_label(f'⚠ {self.last_error}')
            self._append_footer()
            self.menu.show_all()
            return

        self_ips = status.get('Self', {}).get('TailscaleIPs') or []
        ip_label = self_ips[0] if self_ips else '-'
        self._append_label(f'Connected — {ip_label}')

        current_exit_name = None
        candidates = []
        for peer in (status.get('Peer') or {}).values():
            if peer.get('ExitNodeOption'):
                candidates.append(peer)
            if peer.get('ExitNode'):
                current_exit_name = node_name(peer)

        self._append_label(f'Exit node: {current_exit_name or "None"}')
        self._append_separator()

        exit_submenu = Gtk.Menu()
        none_item = Gtk.RadioMenuItem(label='None')
        none_item.set_active(current_exit_name is None)
        none_item.connect('toggled', self._on_exit_node, None)
        exit_submenu.append(none_item)
        group = none_item
        for peer in sorted(candidates, key=node_name):
            ip = (peer.get('TailscaleIPs') or [None])[0]
            name = node_name(peer) or ip
            radio = Gtk.RadioMenuItem.new_with_label_from_widget(group, name)
            radio.set_active(name == current_exit_name)
            radio.connect('toggled', self._on_exit_node, ip)
            exit_submenu.append(radio)
        exit_menu_item = Gtk.MenuItem(label='Exit node')
        exit_menu_item.set_submenu(exit_submenu)
        self.menu.append(exit_menu_item)

        lan_item = Gtk.CheckMenuItem(label='Allow LAN access while using exit node')
        lan_item.set_active(bool((prefs or {}).get('ExitNodeAllowLANAccess')))
        lan_item.connect('toggled', self._on_lan_access)
        self.menu.append(lan_item)

        self._append_separator()
        down_item = Gtk.MenuItem(label='Disconnect')
        down_item.connect('activate', self._on_disconnect)
        self.menu.append(down_item)

        login_item = Gtk.MenuItem(label='Login (send code to ntfy)')
        login_item.connect('activate', self._on_login)
        self.menu.append(login_item)

        logout_item = Gtk.MenuItem(label='Log out')
        logout_item.connect('activate', self._on_logout)
        self.menu.append(logout_item)

        if self.info_message:
            self._append_separator()
            self._append_label(f'ℹ {self.info_message}')
        if self.last_error:
            self._append_separator()
            self._append_label(f'⚠ {self.last_error}')

        self._append_footer()
        self.menu.show_all()

    def _run_set_and_refresh(self, args):
        r = ts('set', *args)
        if r.returncode != 0 and 'operator' in (r.stderr or '').lower():
            pk = subprocess.run(
                ['pkexec', TAILSCALE, 'set', f'--operator={GLib.get_user_name()}'],
                capture_output=True, text=True)
            if pk.returncode == 0:
                r = ts('set', *args)
        self.last_error = None if r.returncode == 0 else (r.stderr or 'command failed').strip().splitlines()[-1][:160]
        GLib.timeout_add(600, lambda: (self.refresh(), False)[1])

    def _on_exit_node(self, widget, ip):
        if not widget.get_active():
            return
        self._run_set_and_refresh([f'--exit-node={ip or ""}'])

    def _on_lan_access(self, widget):
        value = 'true' if widget.get_active() else 'false'
        self._run_set_and_refresh([f'--exit-node-allow-lan-access={value}'])

    def _on_connect(self, _widget):
        r = ts('up')
        self.last_error = None if r.returncode == 0 else (r.stderr or 'connect failed').strip().splitlines()[-1][:160]
        GLib.timeout_add(600, lambda: (self.refresh(), False)[1])

    def _on_disconnect(self, _widget):
        r = ts('down')
        self.last_error = None if r.returncode == 0 else (r.stderr or 'disconnect failed').strip().splitlines()[-1][:160]
        GLib.timeout_add(600, lambda: (self.refresh(), False)[1])

    def _on_logout(self, _widget):
        r = ts('logout')
        self.last_error = None if r.returncode == 0 else (r.stderr or 'logout failed').strip().splitlines()[-1][:160]
        GLib.timeout_add(600, lambda: (self.refresh(), False)[1])

    def _notify(self, text):
        try:
            subprocess.run(['notify-send', 'Saleshandy Tailscale', text], timeout=5)
        except Exception:
            pass
        return False

    def _check_for_update(self):
        if self._update_thread and self._update_thread.is_alive():
            return False
        self._update_thread = threading.Thread(target=self._update_check_worker, daemon=True)
        self._update_thread.start()
        return False

    def _update_check_worker(self):
        version, new_script = _fetch_latest_tray_script()
        if version is None or version <= SCRIPT_VERSION or version == self._dismissed_version:
            return
        GLib.idle_add(self._prompt_update, version, new_script)

    def _prompt_update(self, version, new_script):
        dialog = Gtk.MessageDialog(
            message_type=Gtk.MessageType.QUESTION, buttons=Gtk.ButtonsType.NONE,
            text='Saleshandy Tailscale Tray update available')
        dialog.format_secondary_text(f'Version {version} is available (you have {SCRIPT_VERSION}). Update now?')
        dialog.add_button('Remind me later', Gtk.ResponseType.CANCEL)
        dialog.add_button('No', Gtk.ResponseType.NO)
        dialog.add_button('Yes', Gtk.ResponseType.YES)
        dialog.set_default_response(Gtk.ResponseType.YES)
        response = dialog.run()
        dialog.destroy()

        if response == Gtk.ResponseType.YES:
            self._apply_update(version, new_script)
        elif response == Gtk.ResponseType.NO:
            self._dismissed_version = version  # don't ask again until a newer one shows up
        # "Remind me later" (or closing the dialog): do nothing - the next
        # periodic check will just ask again.
        return False

    def _apply_update(self, version, new_script):
        """The *only* thing an update ever does: write this file and re-exec
        the process. Never calls `tailscale` (login/logout/up/down/set)
        anywhere in this path, so it can never touch the VPN session or
        force a re-login. Keep it that way if you're editing this."""
        dest = os.path.realpath(__file__)
        try:
            with open(dest, 'w', encoding='utf-8', newline='\n') as f:
                f.write(new_script)
        except Exception as e:
            self.last_error = f'Update failed: {e}'[:160]
            self.refresh()
            return
        self._notify(f'Updated to v{version} — restarting')
        os.execv(sys.executable, [sys.executable, dest])

    def _on_login(self, _widget):
        if self._login_thread and self._login_thread.is_alive():
            return  # already in progress
        self.last_error = None
        self.info_message = 'Logging in — waiting for auth link…'
        self.refresh()
        self._login_thread = threading.Thread(target=self._login_worker, daemon=True)
        self._login_thread.start()

    def _login_worker(self):
        # --force-reauth always gets a fresh code, whether currently logged
        # out (NeedsLogin) or already connected (re-login/switch account) -
        # matches the setup-center-cli.sh login flow this mirrors.
        try:
            proc = subprocess.Popen(
                [TAILSCALE, 'up', f'--login-server={LOGIN_SERVER}',
                 '--accept-routes', '--accept-dns', '--force-reauth'],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        except Exception as e:
            GLib.idle_add(self._login_finished, None, str(e))
            return

        url = None
        for line in proc.stdout:
            # Only match an actual registration link (always has /register/ in
            # the path for this headscale server) - tailscale prints other
            # https:// mentions (e.g. the control server URL itself) earlier
            # in the output, and matching any https:// grabbed those instead.
            m = re.search(r'https://\S+/register/\S+', line)
            if m:
                url = m.group(0)
                GLib.idle_add(self._login_url_found, url)
                break
        try:
            proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            pass  # keep running in the background until the browser flow completes
        GLib.idle_add(self._login_finished, url, None)

    def _login_url_found(self, url):
        self.info_message = f'Login link sent to ntfy ({NTFY_URL})'
        self.refresh()

        def send():
            try:
                subprocess.run(
                    ['curl', '-fsSL', '--max-time', '10', '-d',
                     f'Tailscale login ({socket.gethostname()}): {url}', NTFY_URL],
                    capture_output=True, timeout=15)
            except Exception:
                pass
            GLib.idle_add(self._notify, f'Login link sent to ntfy for {socket.gethostname()}')
        threading.Thread(target=send, daemon=True).start()
        return False

    def _login_finished(self, url, err):
        if err:
            self.last_error = f'Login failed: {err}'[:160]
            self.info_message = None
        elif not url:
            self.last_error = 'Login finished but no auth link was seen — check `tailscale status`.'
            self.info_message = None
        GLib.timeout_add(600, lambda: (self.refresh(), False)[1])
        return False


if __name__ == '__main__':
    _lock = acquire_single_instance_lock()
    if _lock is None:
        sys.exit(0)  # another instance is already running
    TailscaleTray()
    Gtk.main()

PYEOF
    chmod +x "$HOME/.local/bin/saleshandy-tailscale-tray.py"

    mkdir -p "$HOME/.local/share/applications"
    cat > "$HOME/.local/share/applications/saleshandy-tailscale-tray.desktop" <<DESKEOF
[Desktop Entry]
Type=Application
Name=Saleshandy Tailscale Tray
Comment=Control Tailscale exit-node and connection settings
Exec=/usr/bin/python3 $HOME/.local/bin/saleshandy-tailscale-tray.py
Icon=network-vpn
Terminal=false
Categories=Network;
StartupNotify=false
DESKEOF
    chmod +x "$HOME/.local/share/applications/saleshandy-tailscale-tray.desktop"
    update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/saleshandy-tailscale-tray.service" <<SVCEOF
[Unit]
Description=Saleshandy Tailscale Tray
PartOf=graphical-session.target
After=graphical-session.target

[Service]
ExecStart=/usr/bin/python3 %h/.local/bin/saleshandy-tailscale-tray.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
SVCEOF

    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable --now saleshandy-tailscale-tray.service 2>/dev/null || \
        log_warn "Could not start the tray service now (no active graphical session?) — it will start automatically at next login."

    log_ok "Saleshandy Tailscale Tray installed — tray icon should appear in the top bar."
}

install_gnome_tools() {
    log_info "Installing GNOME Tweaks & Extension Manager..."
    sudo add-apt-repository universe -y 2>/dev/null || true
    sudo apt-get update -y && sudo apt-get install -y gnome-tweaks gnome-shell-extension-manager
}

install_clamav() {
    log_info "Installing & Configuring ClamAV Antivirus..."
    log_info "Purging existing ClamAV packages..."
    sudo systemctl stop clamav-freshclam clamav-daemon 2>/dev/null || true
    sudo systemctl disable clamav-freshclam clamav-daemon 2>/dev/null || true
    sudo apt-get remove --purge -y clamav clamav-daemon clamav-freshclam || true
    sudo apt-get autoremove -y

    log_info "Installing clamav and clamav-daemon..."
    sudo apt-get update -y
    sudo apt-get install -y clamav clamav-daemon

    log_info "Configuring /etc/clamav/freshclam.conf..."
    sudo mkdir -p /var/lib/clamav /var/log/clamav
    sudo chown -R clamav:clamav /var/lib/clamav /var/log/clamav 2>/dev/null || true

    cat << 'FRESHCLAM_EOF' | sudo tee /etc/clamav/freshclam.conf > /dev/null
DatabaseDirectory /var/lib/clamav
UpdateLogFile /var/log/clamav/freshclam.log
DatabaseMirror database.clamav.net
CompressLocalDatabase yes
FRESHCLAM_EOF

    log_info "Updating ClamAV virus database via freshclam..."
    sudo systemctl stop clamav-freshclam 2>/dev/null || true

    # clamav-daemon refuses to start without a virus database present, so
    # freshclam must actually succeed before we try starting it. The public
    # mirror is often slow/rate-limited on the first hit, so retry a few times.
    local attempt
    for attempt in 1 2 3; do
        sudo freshclam && break
        log_warn "freshclam attempt $attempt failed, retrying in 10s..."
        sleep 10
    done

    if ! compgen -G "/var/lib/clamav/main.c?d" >/dev/null || ! compgen -G "/var/lib/clamav/daily.c?d" >/dev/null; then
        log_error "Virus database never downloaded — clamav-daemon cannot start without it."
        log_error "Check network access to database.clamav.net, then run: sudo freshclam"
        return 1
    fi

    log_info "Starting clamav-daemon service..."
    sudo systemctl daemon-reload
    sudo systemctl reset-failed clamav-daemon 2>/dev/null || true
    sudo systemctl enable clamav-daemon
    sudo systemctl restart clamav-daemon
    sleep 2

    if systemctl is-active --quiet clamav-daemon; then
        log_ok "ClamAV installed, configured, & daemon started!"
    else
        log_error "clamav-daemon failed to start. Last 30 log lines:"
        sudo journalctl -u clamav-daemon --no-pager -n 30
        return 1
    fi
}

install_timedoctor() {
    log_info "Installing Time Doctor..."
    if curl -fsSL --max-time 5 -o /tmp/sfproc "$LOCAL_APPS_BASE/sfproc-3.16.69-x86_64.run" 2>/dev/null || \
        curl -fsSL -o /tmp/sfproc https://download.timedoctor.com/3.16.69/linux/ubuntu-18.04/silent/sfproc-3.16.69-x86_64.run; then
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
uninstall_tailscale() {
    log_info "Uninstalling Tailscale VPN completely..."
    sudo tailscale logout 2>/dev/null || true
    sudo tailscale down --accept-risk=lose-ssh 2>/dev/null || sudo tailscale down 2>/dev/null || true
    sudo systemctl stop tailscaled 2>/dev/null || true
    sudo systemctl disable tailscaled 2>/dev/null || true
    sudo pkill -9 -f tailscaled 2>/dev/null || true
    sudo pkill -9 -f tailscale 2>/dev/null || true

    # Remove APT packages
    sudo apt-get remove --purge -y tailscale tailscaled 2>/dev/null || true

    # Remove Snap package if installed
    sudo snap remove tailscale 2>/dev/null || true

    # Clean APT sources & GPG keyring files
    sudo rm -f /etc/apt/sources.list.d/tailscale*.list /etc/apt/sources.list.d/tailscale*.sources
    sudo rm -f /usr/share/keyrings/tailscale* /etc/apt/keyrings/tailscale* /etc/apt/trusted.gpg.d/tailscale*

    # Remove Tailscale sockets, state databases and configs
    sudo rm -rf /var/lib/tailscale /var/run/tailscale /etc/default/tailscaled /var/cache/tailscale $HOME/.tailscale

    # Remove lingering binaries if any
    sudo rm -f /usr/bin/tailscale /usr/sbin/tailscale /usr/local/bin/tailscale /usr/bin/tailscaled /usr/sbin/tailscaled /usr/local/bin/tailscaled

    sudo apt-get autoremove -y 2>/dev/null || true
    log_ok "Tailscale uninstalled completely."
}
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
    if curl -fsSL --max-time 5 -o "$pkg" "$LOCAL_APPS_BASE/agent(Saleshandy).deb" 2>/dev/null || \
        curl -fsSL -o "$pkg" "https://app.action1.com/agent/6fc55c64-6a4c-11f1-9c44-05814ea2b314/Linux/agent(Saleshandy).deb"; then
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
        13) dpkg -l 2>/dev/null | grep -qi action1 ;;
        14) command -v clamscan &>/dev/null || systemctl is-active --quiet clamav-daemon 2>/dev/null ;;
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
        11) install_timedoctor ;;
        12) set_screen_time_14m ;;
        13) install_action1_agent ;;
        14) install_clamav ;;
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
        13) uninstall_action1_agent ;;
        14) uninstall_clamav ;;
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
        "Action1 Agent:dpkg -l 2>/dev/null | grep -qi action1:"
        "Screen Timeout (14m):gsettings get org.gnome.desktop.session idle-delay | grep -q 840:"
        "ClamAV Antivirus:command -v clamscan || systemctl is-active --quiet clamav-daemon:clamav-daemon"
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
ensure_tailscale_service() {
    if ! command -v tailscale &>/dev/null; then
        log_warn "Tailscale is not installed yet. Installing Tailscale now..."
        install_tailscale || return 1
    fi
    if ! systemctl is-active --quiet tailscaled 2>/dev/null; then
        log_info "Starting tailscaled service..."
        sudo systemctl enable --now tailscaled 2>/dev/null || true
        sudo systemctl restart tailscaled 2>/dev/null || true
    fi
    return 0
}

menu_tailscale() {
    while true; do
        clear
        echo -e "${CYAN}${BOLD}=== [5] TAILSCALE VPN ===${NC}\n"
        echo -e "  [1] Install Tailscale"
        echo -e "  [2] Login  (auto-sent to Admin — no typing)"
        echo -e "  [3] Connect (accept routes & DNS)"
        echo -e "  [4] Full Reset + Connect (reset + accept DNS & routes)"
        echo -e "  [5] Select Exit Node (ikigaihq-primary / node-1 / node-2 / custom)"
        echo -e "  [6] Fix Ubuntu Exit Node Routing (sysctl rp_filter=2)"
        echo -e "  [7] Diagnose & Status"
        echo -e "  [8] Uninstall Tailscale"
        echo -e "  [9] Install Saleshandy Tailscale Tray (GUI exit-node switcher, no terminal)"
        echo -e "  [0] Back\n"

        local server="https://bifrost.saleshandy.com"
        read -rp "  Choice: " ch < /dev/tty
        case "$ch" in
            1) install_tailscale; press_enter ;;
            2)
                clear
                echo -e "${CYAN}${BOLD}=== [5.2] TAILSCALE LOGIN / REGISTER ===${NC}\n"
                echo -e "  [1] Auto-send Login Link to Admin (no typing, no QR)"
                echo -e "  [2] Auth Key Login    (Use pre-authorized key from Admin)"
                echo -e "  [0] Back\n"
                read -rp "  Select Login Method: " subChoice < /dev/tty
                if [[ "$subChoice" == "1" ]]; then
                    ensure_tailscale_service || { press_enter; continue; }
                    NTFY_TOPIC="$NTFY_ADMIN_CHANNEL"
                    NTFY_TOPIC="${NTFY_TOPIC#$NTFY_SERVER/}"
                    NTFY_TOPIC="${NTFY_TOPIC#https://ntfy.sh/}"
                    NTFY_TOPIC="${NTFY_TOPIC#http://ntfy.sh/}"
                    NTFY_TOPIC="${NTFY_TOPIC#ntfy.sh/}"
                    NTFY_TOPIC="${NTFY_TOPIC%/}"
                    log_info "Requesting login link (will auto-send to '$NTFY_TOPIC')..."
                    log_warn "This forces a fresh login even if already connected — if you're SSH'd in over Tailscale right now, that session may drop."
                    TS_LOG="$(mktemp)"
                    sudo tailscale up --login-server="$server" --accept-routes --accept-dns --force-reauth > "$TS_LOG" 2>&1 &
                    TS_PID=$!
                    LOGIN_URL=""
                    for _ in $(seq 1 30); do
                        LOGIN_URL=$(grep -oE 'https://[^ ]+' "$TS_LOG" 2>/dev/null | head -1)
                        [[ -n "$LOGIN_URL" ]] && break
                        kill -0 "$TS_PID" 2>/dev/null || break
                        sleep 1
                    done
                    cat "$TS_LOG"
                    if [[ -n "$LOGIN_URL" ]]; then
                        log_info "Sending link to Admin channel '$NTFY_TOPIC'..."
                        if curl -fsSL --max-time 10 -d "New PC ($(hostname)) Tailscale login: $LOGIN_URL" "$NTFY_SERVER/$NTFY_TOPIC" &>/dev/null; then
                            log_ok "Link sent! Admin should open: $NTFY_SERVER/$NTFY_TOPIC in a browser tab."
                        else
                            log_warn "Auto-send failed. Admin can still use the URL printed above."
                        fi
                    else
                        log_ok "Already logged in — no link needed."
                    fi
                    wait "$TS_PID" 2>/dev/null
                    rm -f "$TS_LOG"
                elif [[ "$subChoice" == "2" ]]; then
                    ensure_tailscale_service || { press_enter; continue; }
                    read -rp "  Enter Tailscale Auth Key (tskey-auth-...): " authKey < /dev/tty
                    if [[ -z "$authKey" ]]; then
                        log_warn "Cancelled."
                    else
                        log_info "Registering node using Auth Key..."
                        sudo tailscale up --authkey="$authKey" --login-server="$server" --accept-routes --accept-dns --force-reauth
                        log_ok "Node successfully registered with Auth Key!"
                    fi
                fi
                press_enter ;;
            3)
                ensure_tailscale_service || { press_enter; continue; }
                sudo tailscale up --accept-routes --accept-dns --login-server="$server"
                press_enter ;;
            4)
                ensure_tailscale_service || { press_enter; continue; }
                sudo tailscale up --login-server="$server" --reset --accept-dns --accept-routes
                press_enter ;;
            5)
                ensure_tailscale_service || { press_enter; continue; }
                clear
                echo -e "${CYAN}${BOLD}=== [5.5] SELECT EXIT NODE ===${NC}\n"
                echo -e "  [1] ikigaihq-office-network-primary  (Primary Office Exit Node)"
                echo -e "  [2] ikigai-office-network-node-1       (Office Exit Node 1)"
                echo -e "  [3] ikigai-office-network-node-2       (Office Exit Node 2)"
                echo -e "  [4] Custom Exit Node IP / Name        (e.g. 100.64.0.7)"
                echo -e "  [5] Turn OFF Exit Node               (Use local Wi-Fi / Direct)"
                echo -e "  [0] Back\n"
                read -rp "  Select Exit Node: " exitChoice < /dev/tty
                local target_node=""
                case "$exitChoice" in
                    1) target_node="ikigaihq-office-network-primary" ;;
                    2) target_node="ikigai-office-network-node-1" ;;
                    3) target_node="ikigai-office-network-node-2" ;;
                    4)
                        read -rp "  Enter Exit Node Name or IP [100.64.0.7]: " target_node < /dev/tty
                        target_node="${target_node:-100.64.0.7}"
                        ;;
                    5)
                        log_info "Disabling Exit Node..."
                        sudo tailscale set --exit-node=""
                        log_ok "Exit Node disabled."
                        press_enter; continue ;;
                    0) continue ;;
                    *) log_warn "Invalid selection."; press_enter; continue ;;
                esac

                if [[ -n "$target_node" ]]; then
                    log_info "Applying Ubuntu rp_filter routing fix..."
                    sudo sysctl -w net.ipv4.conf.all.rp_filter=2 2>/dev/null || true
                    sudo sysctl -w net.ipv4.conf.default.rp_filter=2 2>/dev/null || true

                    log_info "Setting Exit Node to '$target_node'..."
                    if sudo tailscale set --exit-node="$target_node" --exit-node-allow-lan-access 2>/dev/null; then
                        log_ok "Exit Node active: $target_node"
                    else
                        log_info "Retrying with full tailscale up..."
                        sudo tailscale up --login-server="$server" --accept-dns --accept-routes --exit-node="$target_node" --exit-node-allow-lan-access
                    fi
                    log_info "Current Public IP:"
                    curl -s --max-time 5 https://ifconfig.me || true; echo ""
                fi
                press_enter ;;
            6)
                log_section "FIX UBUNTU EXIT NODE ROUTING (SYSCTL)"
                log_info "Configuring rp_filter=2 for loose reverse path filtering..."
                sudo sysctl -w net.ipv4.conf.all.rp_filter=2
                sudo sysctl -w net.ipv4.conf.default.rp_filter=2
                if ! grep -q "rp_filter" /etc/sysctl.conf 2>/dev/null; then
                    echo "net.ipv4.conf.all.rp_filter=2" | sudo tee -a /etc/sysctl.conf >/dev/null
                    echo "net.ipv4.conf.default.rp_filter=2" | sudo tee -a /etc/sysctl.conf >/dev/null
                fi
                log_ok "sysctl rp_filter updated and saved to /etc/sysctl.conf."
                press_enter ;;
            7)
                log_section "TAILSCALE DIAGNOSTICS"
                if ! command -v tailscale &>/dev/null; then
                    log_warn "Tailscale is NOT installed."
                else
                    log_info "Status:";    sudo tailscale status 2>/dev/null || log_warn "tailscale not running / not logged in"
                    log_info "IP:";        sudo tailscale ip 2>/dev/null || true
                    log_info "Ping test:"; sudo tailscale ping 100.64.0.1 2>/dev/null || log_warn "Ping failed"
                fi
                log_info "Service:";   systemctl is-active tailscaled 2>/dev/null && echo -e "  ${GREEN}tailscaled: ACTIVE${NC}" || echo -e "  ${RED}tailscaled: INACTIVE${NC}"
                press_enter ;;
            8)
                read -rp "  Confirm uninstall Tailscale? (y/N): " conf < /dev/tty
                if [[ "$conf" =~ ^[Yy]$ ]]; then
                    uninstall_tailscale
                fi
                press_enter ;;
            9)
                log_section "SALESHANDY TAILSCALE TRAY — SWITCH EXIT NODE WITHOUT TERMINAL"
                ensure_tailscale_service || { press_enter; continue; }
                install_saleshandy_tray
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

# ── [9] Lid-Close / Suspend Fix ───────────────────────────────────────────────
# The exact fix that is known to work on HP Victus (Intel iGPU + NVIDIA dGPU):
#   /etc/default/grub         -> GRUB_CMDLINE_LINUX_DEFAULT gains
#                                intel_idle.max_cstate=4 nvidia-drm.modeset=1
#   /etc/systemd/logind.conf  -> HandleLidSwitch=ignore
# Everything below exists to apply exactly that, and to prove it landed.

LID_GRUB_FILE="/etc/default/grub"
LID_LOGIND_FILE="/etc/systemd/logind.conf"
LID_PARAMS="intel_idle.max_cstate=4 nvidia-drm.modeset=1"

# Read GRUB_CMDLINE_LINUX_DEFAULT the same way grub-mkconfig does — by sourcing the
# file — so single quotes, no quotes and trailing whitespace all parse correctly.
_lid_grub_value() {
    ( set +u; . "$LID_GRUB_FILE" >/dev/null 2>&1; printf '%s' "${GRUB_CMDLINE_LINUX_DEFAULT-}" )
}
_lid_grub_is_set() {
    ( set +u; . "$LID_GRUB_FILE" >/dev/null 2>&1; printf '%s' "${GRUB_CMDLINE_LINUX_DEFAULT+SET}" )
}

# Replace the key in place, or append it if missing. awk (not sed) so the value is
# always literal — no & / | / backslash surprises.
_lid_write_grub() {
    local new_val="$1" tmp rc
    tmp=$(mktemp) || return 1
    awk -v v="$new_val" '
        /^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=/ {
            if (!done) { print "GRUB_CMDLINE_LINUX_DEFAULT=\"" v "\""; done=1 }
            next
        }
        { print }
        END { if (!done) print "GRUB_CMDLINE_LINUX_DEFAULT=\"" v "\"" }
    ' "$LID_GRUB_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
    sudo cp "$tmp" "$LID_GRUB_FILE"
    rc=$?
    rm -f "$tmp"
    return $rc
}

_lid_write_logind() {
    local key="$1" val="$2" tmp rc
    [ -f "$LID_LOGIND_FILE" ] || echo "[Login]" | sudo tee "$LID_LOGIND_FILE" > /dev/null
    tmp=$(mktemp) || return 1
    # The "=" in the pattern is what stops HandleLidSwitch from also matching
    # HandleLidSwitchExternalPower / HandleLidSwitchDocked.
    awk -v k="$key" -v v="$val" '
        $0 ~ ("^[[:space:]]*#?[[:space:]]*" k "[[:space:]]*=") {
            if (!done) { print k "=" v; done=1 }
            next
        }
        { print }
        END { if (!done) print k "=" v }
    ' "$LID_LOGIND_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
    sudo cp "$tmp" "$LID_LOGIND_FILE"
    rc=$?
    rm -f "$tmp"
    return $rc
}

# Drop-ins are applied after the main file, so one of these silently beats any edit
# to logind.conf. This is the usual reason for "I set it but nothing changed".
_lid_dropin_overrides() {
    local d f hits=""
    for d in /etc/systemd/logind.conf.d /run/systemd/logind.conf.d \
             /usr/lib/systemd/logind.conf.d /usr/local/lib/systemd/logind.conf.d; do
        [ -d "$d" ] || continue
        for f in "$d"/*.conf; do
            [ -f "$f" ] || continue
            grep -qE '^[[:space:]]*HandleLidSwitch[[:space:]]*=' "$f" && hits="$hits $f"
        done
    done
    printf '%s' "$hits"
}

# The value logind is actually enforcing — not what the file claims.
_lid_effective() {
    local v
    v=$(loginctl show-config 2>/dev/null | grep -E '^HandleLidSwitch=' | head -n1 | cut -d= -f2-)
    if [ -n "$v" ]; then printf '%s' "$v"; else printf 'unknown'; fi
}

_lid_show_status() {
    local grub_val cmdline eff dropins missing p f
    grub_val=$(_lid_grub_value)
    cmdline=$(cat /proc/cmdline 2>/dev/null)

    echo -e "  ${BOLD}Current state${NC}"
    echo -e "  ${DIM}--------------------------------------------------------------${NC}"

    missing=""
    for p in $LID_PARAMS; do
        [[ " $grub_val " == *" $p "* ]] || missing="$missing $p"
    done
    if [ -z "$missing" ]; then
        echo -e "  GRUB config file  : ${GREEN}both parameters present${NC}"
    else
        echo -e "  GRUB config file  : ${YELLOW}missing:${missing}${NC}"
    fi

    missing=""
    for p in $LID_PARAMS; do
        [[ " $cmdline " == *" $p "* ]] || missing="$missing $p"
    done
    if [ -z "$missing" ]; then
        echo -e "  Running kernel    : ${GREEN}both parameters active${NC}"
    else
        echo -e "  Running kernel    : ${YELLOW}not active${missing}${NC} ${DIM}(reboot needed)${NC}"
    fi

    eff=$(_lid_effective)
    if [ "$eff" = "ignore" ]; then
        echo -e "  HandleLidSwitch   : ${GREEN}${eff}${NC} ${DIM}(effective)${NC}"
    else
        echo -e "  HandleLidSwitch   : ${YELLOW}${eff}${NC} ${DIM}(effective)${NC}"
    fi

    dropins=$(_lid_dropin_overrides)
    if [ -n "$dropins" ]; then
        echo -e "  Drop-in override  : ${RED}yes${NC}"
        for f in $dropins; do echo -e "                      ${RED}${f}${NC}"; done
    fi
    echo ""
}

_lid_apply() {
    log_section "APPLYING LID-CLOSE / SUSPEND FIX"

    # ---- 1. GRUB kernel parameters -------------------------------------------
    if [ ! -f "$LID_GRUB_FILE" ]; then
        log_error "$LID_GRUB_FILE not found — this does not look like a GRUB system. Aborting."
        return 1
    fi

    local current_val probe
    current_val=$(_lid_grub_value)
    probe=$(_lid_grub_is_set)
    if grep -qE '^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=' "$LID_GRUB_FILE" && [ "$probe" != "SET" ]; then
        log_error "Could not parse GRUB_CMDLINE_LINUX_DEFAULT in $LID_GRUB_FILE."
        log_info  "Refusing to write — a bad write here can stop the machine booting cleanly."
        log_info  "Fix the line by hand first:  sudo nano $LID_GRUB_FILE"
        return 1
    fi

    # Drop the params an older version of this menu used to add. They do not fix
    # this bug, and mem_sleep_default=deep breaks resume on S0ix-only laptops.
    local kept="" removed="" tok
    for tok in $current_val; do
        case "$tok" in
            intel_idle.max_cstate=*|nvidia-drm.modeset=*)  continue ;;
            i915.enable_psr=*|mem_sleep_default=*)         removed="$removed $tok" ;;
            *)                                             kept="$kept $tok" ;;
        esac
    done
    local new_val
    new_val=$(echo "$kept $LID_PARAMS" | xargs)

    sudo cp "$LID_GRUB_FILE" "${LID_GRUB_FILE}.bak-$(date +%s)"
    if ! _lid_write_grub "$new_val"; then
        log_error "Failed to write $LID_GRUB_FILE. Nothing was changed."
        return 1
    fi

    # Prove the value we intended is the value the file now yields.
    local readback
    readback=$(_lid_grub_value)
    if [ "$readback" != "$new_val" ]; then
        log_error "Write-back check failed. Expected:"
        echo -e "    ${DIM}${new_val}${NC}"
        log_error "File now reads:"
        echo -e "    ${DIM}${readback}${NC}"
        log_warn  "Restore the .bak-* file next to $LID_GRUB_FILE before rebooting."
        return 1
    fi
    log_ok "GRUB parameters set: ${new_val}"
    [ -n "$removed" ] && log_info "Removed parameters that do not help on this hardware:${removed}"

    log_info "Running update-grub..."
    if sudo update-grub; then
        log_ok "update-grub finished."
    else
        log_error "update-grub failed — see its output above. Do not reboot until it succeeds."
        return 1
    fi

    # ---- 2. logind lid behaviour ---------------------------------------------
    sudo cp "$LID_LOGIND_FILE" "${LID_LOGIND_FILE}.bak-$(date +%s)" 2>/dev/null
    _lid_write_logind "HandleLidSwitch" "ignore" && \
        log_ok "HandleLidSwitch=ignore written to $LID_LOGIND_FILE"

    # Ubuntu splits lid behaviour by power source. If this key exists on this
    # systemd version it has to be set too, or the fix does nothing while plugged
    # in — which is how a Victus is normally used.
    if grep -qE '^[[:space:]]*#?[[:space:]]*HandleLidSwitchExternalPower[[:space:]]*=' "$LID_LOGIND_FILE"; then
        _lid_write_logind "HandleLidSwitchExternalPower" "ignore" && \
            log_ok "HandleLidSwitchExternalPower=ignore written (applies while on AC power)."
    fi

    log_info "Reloading systemd-logind..."
    sudo systemctl restart systemd-logind 2>/dev/null || sudo systemctl reload systemd-logind 2>/dev/null

    # ---- 3. Verify what actually took effect ----------------------------------
    echo ""
    log_section "VERIFICATION"
    local eff dropins f
    eff=$(_lid_effective)
    if [ "$eff" = "ignore" ]; then
        log_ok "logind is enforcing HandleLidSwitch=ignore. Closing the lid now does nothing."
    elif [ "$eff" = "unknown" ]; then
        log_warn "Could not read the effective value — 'loginctl show-config' is not available here."
        log_info "Check by hand instead:  systemctl show systemd-logind -p HandleLidSwitch"
    else
        log_error "logind still reports HandleLidSwitch=${eff} — the file was written but something overrides it."
    fi

    dropins=$(_lid_dropin_overrides)
    if [ -n "$dropins" ]; then
        log_error "These drop-in files override logind.conf and must be edited or removed:"
        for f in $dropins; do echo -e "    ${YELLOW}${f}${NC}"; done
    fi

    echo ""
    log_warn "The kernel parameters only take effect after a reboot."
    read -rp "  Reboot now? (y/N): " rb < /dev/tty
    if [[ "$rb" =~ ^[Yy]$ ]]; then
        log_info "Rebooting..."
        sudo reboot
    else
        log_info "Reboot later, then reopen this menu — the status block will confirm both parameters are active."
    fi
    return 0
}

_lid_undo() {
    log_section "UNDO LID-CLOSE / SUSPEND FIX"
    local gbak lbak restored=0 conf
    gbak=$(ls -1t "${LID_GRUB_FILE}".bak-* 2>/dev/null | head -n1)
    lbak=$(ls -1t "${LID_LOGIND_FILE}".bak-* 2>/dev/null | head -n1)

    if [ -z "$gbak" ] && [ -z "$lbak" ]; then
        log_warn "No backups found — nothing to undo."
        return 0
    fi
    echo -e "  Will restore:"
    [ -n "$gbak" ] && echo -e "    ${DIM}${gbak}  ->  ${LID_GRUB_FILE}${NC}"
    [ -n "$lbak" ] && echo -e "    ${DIM}${lbak}  ->  ${LID_LOGIND_FILE}${NC}"
    echo ""
    read -rp "  Continue? (y/N): " conf < /dev/tty
    if [[ ! "$conf" =~ ^[Yy]$ ]]; then log_info "Cancelled."; return 0; fi

    if [ -n "$gbak" ]; then
        sudo cp "$gbak" "$LID_GRUB_FILE" && { log_ok "GRUB config restored."; sudo update-grub; restored=1; }
    fi
    if [ -n "$lbak" ]; then
        sudo cp "$lbak" "$LID_LOGIND_FILE" && { log_ok "logind.conf restored."; \
            sudo systemctl restart systemd-logind 2>/dev/null; restored=1; }
    fi
    [ "$restored" -eq 1 ] && log_warn "Reboot to fully revert the kernel parameters."
    return 0
}

menu_lid_fix() {
    while true; do
        clear
        echo -e "${CYAN}${BOLD}=== [9] FIX LID-CLOSE / SUSPEND (HP VICTUS & NVIDIA LAPTOPS) ===${NC}\n"
        echo -e "  ${DIM}Symptom: closing the lid suspends badly — screen blinks, stays black,${NC}"
        echo -e "  ${DIM}or never resumes properly on a hybrid Intel + NVIDIA laptop.${NC}\n"
        echo -e "  ${DIM}Applies one known-good fix, then verifies it:${NC}"
        echo -e "  ${DIM}  ${LID_GRUB_FILE}${NC}"
        echo -e "  ${DIM}    GRUB_CMDLINE_LINUX_DEFAULT += intel_idle.max_cstate=4 nvidia-drm.modeset=1${NC}"
        echo -e "  ${DIM}  ${LID_LOGIND_FILE}${NC}"
        echo -e "  ${DIM}    HandleLidSwitch=ignore${NC}\n"

        _lid_show_status

        echo -e "  [1] Apply the fix"
        echo -e "  [2] Undo (restore the last backup)"
        echo -e "  [0] Back\n"

        read -rp "  Choice: " ch < /dev/tty
        case "$ch" in
            1) _lid_apply; press_enter ;;
            2) _lid_undo;  press_enter ;;
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
        echo -e "  ${DIM}--- Slow WiFi speed vs Windows (dual-boot machines) ---${NC}"
        echo -e "  ${BOLD}[5]${NC} Fix WiFi Speed (Disable Power Saving — permanent)"
        echo -e "  ${BOLD}[6]${NC} Show WiFi Link Speed & Band (2.4GHz vs 5GHz)"
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
                            sudo sed -i '/^\[connectivity\]/a enabled=false' "$nm_conf"
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
            5)
                log_section "FIX WIFI SPEED — DISABLE POWER SAVING"
                echo -e "  ${DIM}Linux enables WiFi power saving by default (Windows doesn't), which${NC}"
                echo -e "  ${DIM}throttles throughput. This disables it — session now + permanently.${NC}\n"
                local wifi_if
                wifi_if=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')
                if [ -z "$wifi_if" ]; then
                    log_error "No WiFi interface detected."
                else
                    log_info "WiFi interface detected: $wifi_if"
                    sudo iw dev "$wifi_if" set power_save off 2>/dev/null && \
                        log_ok "Power saving disabled for this session." || \
                        log_warn "Could not set power_save via iw (driver may not support it)."

                    local nm_pwr_conf="/etc/NetworkManager/conf.d/wifi-powersave-off.conf"
                    sudo mkdir -p /etc/NetworkManager/conf.d
                    if [ -f "$nm_pwr_conf" ]; then
                        sudo cp "$nm_pwr_conf" "${nm_pwr_conf}.bak-$(date +%s)"
                    fi
                    printf '[connection]\nwifi.powersave = 2\n' | sudo tee "$nm_pwr_conf" > /dev/null
                    log_ok "Permanent fix written to ${nm_pwr_conf} (wifi.powersave=2 = disabled)."
                    read -rp "  Restart NetworkManager now to apply? (y/N): " conf < /dev/tty
                    if [[ "$conf" =~ ^[Yy]$ ]]; then
                        sudo systemctl restart NetworkManager
                        log_ok "NetworkManager restarted. WiFi power saving is now permanently disabled."
                    else
                        log_info "Restart NetworkManager later (or reboot) to apply."
                    fi
                fi
                press_enter ;;
            6)
                log_section "WIFI LINK SPEED & BAND"
                local wifi_if
                wifi_if=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')
                if [ -z "$wifi_if" ]; then
                    log_error "No WiFi interface detected."
                else
                    log_info "Interface: $wifi_if"
                    if command -v iw &>/dev/null; then
                        iw dev "$wifi_if" link 2>/dev/null | grep -E "SSID|freq|signal|bitrate" || \
                            log_warn "Not connected, or 'iw link' unsupported on this driver."
                    else
                        log_warn "'iw' not installed — install with: sudo apt-get install -y iw"
                    fi
                    echo ""
                    log_info "Band reference: 2400-2500 MHz = 2.4GHz (slower), 5000-5900 MHz = 5GHz (faster)"
                fi
                press_enter ;;
            0) return ;;
            *) log_warn "Invalid choice." ;;
        esac
    done
}

# ── [11] System Toolkit & Utilities ─────────────────────────────────────────
menu_system_toolkit() {
    while true; do
        clear
        echo -e "${CYAN}${BOLD}=== [11] SYSTEM TOOLKIT & UTILITIES ===${NC}\n"
        echo -e "  ${BOLD}[1]${NC} Create / Resize Swap File (16GB or 18GB + /etc/fstab)"
        echo -e "  ${BOLD}[2]${NC} Enable Docker Sudo-less Access (usermod -aG docker)"
        echo -e "  ${BOLD}[3]${NC} Setup XAMPP Auto-Start Service (/etc/systemd/system/xampp.service)"
        echo -e "  ${BOLD}[4]${NC} Setup OpenSSH Server (install & enable sshd)"
        echo -e "  ${BOLD}[5]${NC} Switch PHP Default Version (update-alternatives)"
        echo -e "  ${BOLD}[6]${NC} Check Disk Encryption (LUKS / crypto)"
        echo -e "  ${BOLD}[7]${NC} Emergency Package Repair (\"Oh No! Something went wrong\")"
        echo -e "  ${BOLD}[8]${NC} Install CPU Performance Tuner (cpupower-gui)"
        echo -e "  ${BOLD}[9]${NC} Canon LBP2900 Printer Driver Setup"
        echo -e "  ${BOLD}[0]${NC} Back\n"

        read -rp "  Choice: " ch < /dev/tty
        case "$ch" in
            1)
                log_section "SWAP FILE CONFIGURATION"
                swapon --show || true
                read -rp "  Enter desired swap size in GB (e.g. 16 or 18, blank=cancel): " sw_size < /dev/tty
                if [[ -n "$sw_size" && "$sw_size" =~ ^[0-9]+$ ]]; then
                    log_info "Turning off current swap..."
                    sudo swapoff /swapfile 2>/dev/null || true
                    log_info "Allocating ${sw_size}G swap file..."
                    sudo fallocate -l "${sw_size}G" /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=$((sw_size*1024))
                    sudo chmod 600 /swapfile
                    sudo mkswap /swapfile
                    sudo swapon /swapfile
                    if ! grep -q '/swapfile' /etc/fstab 2>/dev/null; then
                        echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab > /dev/null
                        log_ok "Added /swapfile entry to /etc/fstab"
                    fi
                    log_ok "Swap successfully updated to ${sw_size}GB!"
                    swapon --show
                else
                    log_info "Cancelled."
                fi
                press_enter ;;
            2)
                log_section "DOCKER SUDO-LESS ACCESS"
                if command -v docker &>/dev/null; then
                    sudo usermod -aG docker "$USER"
                    log_ok "Added $USER to 'docker' group. Log out and log back in for changes to take effect."
                else
                    log_warn "Docker is not installed yet. Install Docker first."
                fi
                press_enter ;;
            3)
                log_section "XAMPP AUTO-START SERVICE"
                if [ -d "/opt/lampp" ]; then
                    cat << 'XAMPP_EOF' | sudo tee /etc/systemd/system/xampp.service > /dev/null
[Unit]
Description=XAMPP
After=network.target

[Service]
ExecStart=/opt/lampp/lampp start
ExecStop=/opt/lampp/lampp stop
Type=forking

[Install]
WantedBy=multi-user.target
XAMPP_EOF
                    sudo systemctl daemon-reload
                    sudo systemctl enable xampp.service
                    log_ok "XAMPP auto-start service created & enabled at /etc/systemd/system/xampp.service!"
                else
                    log_error "/opt/lampp not found. Please install XAMPP first."
                fi
                press_enter ;;
            4)
                log_section "OPENSSH SERVER SETUP"
                log_info "Installing openssh-server and openssh-client..."
                sudo apt-get update -y && sudo apt-get install -y openssh-server openssh-client
                sudo systemctl enable --now ssh
                log_ok "OpenSSH server is active & enabled!"
                log_info "Connect using: ssh $USER@$(hostname -I | awk '{print $1}')"
                press_enter ;;
            5)
                log_section "PHP VERSION SWITCHER"
                if command -v update-alternatives &>/dev/null; then
                    log_info "Running update-alternatives --config php..."
                    sudo update-alternatives --config php || true
                else
                    log_error "update-alternatives command not found."
                fi
                press_enter ;;
            6)
                log_section "DISK ENCRYPTION CHECK"
                log_info "Checking for encrypted LUKS partitions (lsblk -f | grep crypto)..."
                local crypto_output
                crypto_output=$(lsblk -f | grep -i crypto || true)
                if [[ -n "$crypto_output" ]]; then
                    echo -e "${GREEN}Encrypted partitions detected:${NC}\n$crypto_output"
                else
                    echo -e "${YELLOW}No encrypted (crypto/LUKS) partitions found.${NC}"
                fi
                press_enter ;;
            7)
                log_section "EMERGENCY SYSTEM & PACKAGE REPAIR"
                log_info "Fixing broken packages & upgrading system..."
                sudo dpkg --configure -a
                sudo apt-get clean
                sudo apt-get update --fix-missing
                sudo apt-get install -f -y
                sudo apt-get dist-upgrade -y
                log_ok "Package repair complete!"
                press_enter ;;
            8)
                log_section "CPU PERFORMANCE TUNER"
                log_info "Installing cpupower-gui..."
                sudo apt-get update -y && sudo apt-get install -y cpupower-gui
                log_ok "cpupower-gui installed. Launch it from app menu or terminal with: cpupower-gui"
                press_enter ;;
            9)
                log_section "CANON PRINTER DRIVERS"
                log_info "Canon LBP2900 / 2900B setup helper..."
                log_info "Cloning printer driver installer script..."
                local tmp_dir="/tmp/canon_printer"
                rm -rf "$tmp_dir"
                if git clone https://github.com/hieplpvip/ubuntu_canon_printer.git "$tmp_dir"; then
                    log_ok "Driver repository cloned to $tmp_dir"
                    log_info "Run: cd $tmp_dir && sudo ./canon_lbp2900.sh"
                else
                    log_error "Failed to clone driver repo."
                fi
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
    echo -e "  ${BOLD}[9]${NC} Fix Lid-Close / Suspend  — HP Victus & hybrid NVIDIA laptops"
    echo -e "  ${BOLD}[10]${NC} Diagnose WiFi         — fix ? / limited connectivity false warning"
    echo -e "  ${BOLD}[11]${NC} System Toolkit        — swap, docker, xampp, ssh, php, repair, canon"
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
        9) menu_lid_fix ;;
        10) menu_wifi_diagnose ;;
        11) menu_system_toolkit ;;
        0) echo -e "\n  ${CYAN}Goodbye!${NC}\n"; exit 0 ;;
        *) log_warn "Invalid choice — enter 0-11."; sleep 1 ;;
    esac
done
