#!/usr/bin/env bash
# ==============================================================================
# fix-tailscaled.sh — Repair a failed tailscaled.service on Ubuntu/Debian
#
# Targets: "Job for tailscaled.service failed because of unavailable
#           resources or another system error."
#
# Usage:
#   chmod +x fix-tailscaled.sh && ./fix-tailscaled.sh
#   -- or, once pushed --
#   curl -fsSL https://raw.githubusercontent.com/priyanshusaleshandy/ubuntu-setup/main/fix-tailscaled.sh | bash
# ==============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[*]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[X]${NC} $1"; }

if [[ "$EUID" -eq 0 ]]; then
    err "Do NOT run this as root. Run as your normal user (it uses sudo when needed)."
    exit 1
fi

is_active() { systemctl is-active tailscaled &>/dev/null; }

echo "=== tailscaled repair ==="

if is_active; then
    ok "tailscaled is already running. Nothing to do."
    exit 0
fi

info "Current failure reason (last 20 log lines):"
sudo journalctl -xeu tailscaled.service --no-pager -n 20 || true
echo

# 1. Clear systemd rate-limit lockout + reload unit files
info "Step 1: daemon-reload + reset-failed + start"
sudo systemctl daemon-reload
sudo systemctl reset-failed tailscaled 2>/dev/null || true
sudo systemctl start tailscaled 2>/dev/null || true
sleep 2
if is_active; then ok "Fixed — tailscaled is active."; exit 0; fi
warn "Still not running. Continuing..."

# 2. Disk space check
info "Step 2: Disk space (tailscaled needs room to write /var/lib/tailscale state)"
df -h / | tail -n +1
avail_kb=$(df -k / | awk 'NR==2{print $4}')
if [[ "$avail_kb" -lt 51200 ]]; then
    err "Less than 50MB free on /. Free up disk space, then re-run this script."
    exit 1
fi
ok "Disk space looks fine."

# 3. AppArmor stale-profile check (common on Ubuntu after apt upgrades)
if command -v aa-status &>/dev/null && sudo aa-status 2>/dev/null | grep -qi tailscaled; then
    info "Step 3: Resetting stale AppArmor profile for tailscaled"
    sudo apparmor_parser -R /etc/apparmor.d/tailscaled 2>/dev/null || true
    sudo systemctl restart tailscaled 2>/dev/null || true
    sleep 2
    if is_active; then ok "Fixed — tailscaled is active (AppArmor profile was the cause)."; exit 0; fi
    warn "Still not running. Continuing..."
else
    info "Step 3: No AppArmor profile loaded for tailscaled, skipping."
fi

# 4. TUN device check
info "Step 4: Checking /dev/net/tun"
sudo modprobe tun 2>/dev/null || true
if [[ ! -c /dev/net/tun ]]; then
    err "/dev/net/tun is missing. If this is a VM/container, the host must expose the tun device."
else
    ok "/dev/net/tun present."
fi
sudo systemctl restart tailscaled 2>/dev/null || true
sleep 2
if is_active; then ok "Fixed — tailscaled is active."; exit 0; fi

# 5. Give up gracefully with full diagnostics for a human to read
err "tailscaled still won't start. Full status + logs below — send this output back:"
echo
sudo systemctl status tailscaled.service --no-pager -l
echo
sudo journalctl -xeu tailscaled.service --no-pager -n 50
exit 1
