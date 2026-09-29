#!/usr/bin/env bash
# ==============================================================================
# Set Corporate Fleet Wallpaper for Linux (GNOME / Ubuntu)
# Managed via ManageEngine Endpoint Central
# ==============================================================================
set -euo pipefail

WALLPAPER_URL="https://raw.githubusercontent.com/priyanshusaleshandy/ubuntu-setup/biomax-console/windows/wallpapers/saleshandy-wallpaper-1080p.png"
DEST_PATH="/usr/share/backgrounds/saleshandy-wallpaper-1080p.png"

echo "=== Setting Fleet Wallpaper (1080p Locked) ==="

# 1. Download/Copy wallpaper to system backgrounds
mkdir -p /usr/share/backgrounds
if [ -f "saleshandy-wallpaper-1080p.png" ]; then
    echo "Using local dependency file..."
    cp -f "saleshandy-wallpaper-1080p.png" "$DEST_PATH"
else
    echo "Downloading wallpaper from GitHub..."
    curl -fsSL "$WALLPAPER_URL" -o "$DEST_PATH"
fi
chmod 644 "$DEST_PATH"
echo "Wallpaper saved at $DEST_PATH"

# 2. System-wide dconf configuration (defaults & lock)
mkdir -p /etc/dconf/profile
if [ ! -f /etc/dconf/profile/user ] || ! grep -q "system-db:local" /etc/dconf/profile/user 2>/dev/null; then
    cat << 'PROFILE' > /etc/dconf/profile/user
user-db:user
system-db:local
PROFILE
fi

mkdir -p /etc/dconf/db/local.d
cat << DCONF > /etc/dconf/db/local.d/00-wallpaper
[org/gnome/desktop/background]
picture-uri='file://${DEST_PATH}'
picture-uri-dark='file://${DEST_PATH}'
picture-options='zoom'

[org/gnome/desktop/screensaver]
picture-uri='file://${DEST_PATH}'
picture-options='zoom'
DCONF

mkdir -p /etc/dconf/db/local.d/locks
cat << LOCKS > /etc/dconf/db/local.d/locks/wallpaper
/org/gnome/desktop/background/picture-uri
/org/gnome/desktop/background/picture-uri-dark
/org/gnome/desktop/background/picture-options
/org/gnome/desktop/screensaver/picture-uri
/org/gnome/desktop/screensaver/picture-options
LOCKS

# Update dconf database
if command -v dconf &>/dev/null; then
    dconf update
    echo "dconf database updated successfully."
fi

# 3. Apply immediately to active user graphical sessions
for u in $(who | awk '{print $1}' | sort -u); do
    uid=$(id -u "$u" 2>/dev/null) || continue
    user_bus="/run/user/$uid/bus"
    if [ -S "$user_bus" ]; then
        echo "Applying to active session for user: $u (UID: $uid)"
        sudo -u "$u" DBUS_SESSION_BUS_ADDRESS="unix:path=$user_bus" \
            gsettings set org.gnome.desktop.background picture-uri "file://${DEST_PATH}" 2>/dev/null || true
        sudo -u "$u" DBUS_SESSION_BUS_ADDRESS="unix:path=$user_bus" \
            gsettings set org.gnome.desktop.background picture-uri-dark "file://${DEST_PATH}" 2>/dev/null || true
        sudo -u "$u" DBUS_SESSION_BUS_ADDRESS="unix:path=$user_bus" \
            gsettings set org.gnome.desktop.background picture-options "zoom" 2>/dev/null || true
    fi
done

echo "=== Fleet Wallpaper Setup Complete ==="
exit 0
