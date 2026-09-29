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
    echo "Using local 1080p dependency file..."
    cp -f "saleshandy-wallpaper-1080p.png" "$DEST_PATH"
elif [ -f "saleshandy-wallpaper.jpg" ]; then
    echo "Using local jpg dependency file..."
    cp -f "saleshandy-wallpaper.jpg" "$DEST_PATH"
else
    echo "Downloading wallpaper from GitHub..."
    curl -fsSL "$WALLPAPER_URL" -o "$DEST_PATH"
fi
chmod 644 "$DEST_PATH"

# Also keep /usr/share/backgrounds/saleshandy-wallpaper.jpg in sync so legacy references never break
cp -f "$DEST_PATH" /usr/share/backgrounds/saleshandy-wallpaper.jpg 2>/dev/null || true
chmod 644 /usr/share/backgrounds/saleshandy-wallpaper.jpg 2>/dev/null || true
echo "Wallpaper saved at $DEST_PATH"

# 2. Temporarily lift lock so active user sessions can receive live background update
rm -f /etc/dconf/db/local.d/locks/wallpaper 2>/dev/null || true
if command -v dconf &>/dev/null; then
    dconf update 2>/dev/null || true
fi

# 3. Apply immediately to active user graphical sessions (live repaint)
for u in $(who | awk '{print $1}' | sort -u); do
    uid=$(id -u "$u" 2>/dev/null) || continue
    user_bus="/run/user/$uid/bus"
    if [ -S "$user_bus" ]; then
        echo "Applying live wallpaper to user session: $u (UID: $uid)"
        sudo -u "$u" DBUS_SESSION_BUS_ADDRESS="unix:path=$user_bus" \
            gsettings set org.gnome.desktop.background picture-uri "file://${DEST_PATH}" 2>/dev/null || true
        sudo -u "$u" DBUS_SESSION_BUS_ADDRESS="unix:path=$user_bus" \
            gsettings set org.gnome.desktop.background picture-uri-dark "file://${DEST_PATH}" 2>/dev/null || true
        sudo -u "$u" DBUS_SESSION_BUS_ADDRESS="unix:path=$user_bus" \
            gsettings set org.gnome.desktop.background picture-options "zoom" 2>/dev/null || true
        sudo -u "$u" DBUS_SESSION_BUS_ADDRESS="unix:path=$user_bus" \
            gsettings set org.gnome.desktop.screensaver picture-uri "file://${DEST_PATH}" 2>/dev/null || true
        sudo -u "$u" DBUS_SESSION_BUS_ADDRESS="unix:path=$user_bus" \
            gsettings set org.gnome.desktop.screensaver picture-options "zoom" 2>/dev/null || true
    fi
done

# 4. System-wide dconf configuration (profile & defaults)
mkdir -p /etc/dconf/profile
cat << 'PROFILE' > /etc/dconf/profile/user
user-db:user
system-db:local
PROFILE

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

# 5. System-wide dconf locks (strict lockdown)
mkdir -p /etc/dconf/db/local.d/locks
cat << 'LOCKS' > /etc/dconf/db/local.d/locks/wallpaper
/org/gnome/desktop/background/picture-uri
/org/gnome/desktop/background/picture-uri-dark
/org/gnome/desktop/background/picture-options
/org/gnome/desktop/screensaver/picture-uri
/org/gnome/desktop/screensaver/picture-options
LOCKS

# Update system dconf database
if command -v dconf &>/dev/null; then
    dconf update
    echo "System dconf database locked successfully."
fi

# 6. Restart dconf-service for active sessions so new locks take effect immediately
for u in $(who | awk '{print $1}' | sort -u); do
    uid=$(id -u "$u" 2>/dev/null) || continue
    pkill -u "$uid" dconf-service 2>/dev/null || true
done

echo "=== Fleet Wallpaper Setup Complete ==="
exit 0
