# Ubuntu Post-Install Setup Dashboard

An interactive post-install configuration script to automate the setup of new laptops with Ubuntu. It features a graphical console in the terminal allowing selective or full software installation, diagnostics testing, and system setups.

## How to Run

Open your terminal in Ubuntu and run the following memorable command:

```bash
wget -O install.sh spoo.me/saleshandy && chmod +x install.sh && ./install.sh
```

---

## Features

- **Initial User Setup**: Sets up administrative users (`Admin` and your personal user) on a fresh system.
- **Interactive Menu**: Toggle individual packages on/off.
- **Diagnostics Panel**: Run status checks on all packages.
- **Persistent Services**: Configures ClamAV and other services to auto-start on reboot.
- **High-Speed Engine**: Spawns parallel background downloads and consolidates APT installations to run in minutes.

---

## Software List

1. **Core Utilities & libfuse2**: Git, curl, unzip, build-essential, and libfuse2 (for AppImage compatibility).
2. **Node.js**: Node.js **v15.14.0** (via NVM).
3. **Google Chrome**: Official Chrome desktop browser.
4. **Visual Studio Code**: VS Code IDE.
5. **MySQL Workbench**: Official database administration tool.
6. **DBeaver Community Edition**: Latest `.deb` package.
7. **Postman (Snap)**: API development client.
8. **Redis Insight (Snap)**: GUI for Redis database.
9. **MongoDB Compass**: Official GUI for MongoDB.
10. **Tailscale VPN**: Installed via the **Snap Store** (`snap install tailscale`) to integrate with GNOME Settings.
11. **GNOME Tweaks & Extension Manager**: Desktop customizers.
12. **ClamAV Antivirus Daemon**: Full ClamAV setup with persistent auto-start systemd configurations.
