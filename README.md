# Ubuntu Post-Install Setup Dashboard

An interactive post-install configuration script to automate the setup of new laptops with Ubuntu. It features a graphical console in the terminal allowing selective or full software installation and status testing.

## Features

- **Interactive Menu**: Toggle individual packages on/off.
- **Diagnostics Panel**: Run status checks on all packages.
- **Persistent Services**: Configures ClamAV and other services to auto-start on reboot.

## How to Run

Open your terminal in Ubuntu and run the following command to download and run the script:

```bash
wget -O install.sh https://raw.githubusercontent.com/priyanshusaleshandy/ubuntu-setup/master/install.sh && chmod +x install.sh && ./install.sh
```

## Software Included

- **Core**: Updates, git, curl, build-essential, libfuse2
- **Runtimes**: Node.js v15.14.0 (NVM), Python 3 & Pip
- **Desktop Apps**: VS Code, Google Chrome
- **Database Tools**: MySQL Workbench, DBeaver, MongoDB Compass
- **Developer Tools**: Postman, Redis Insight
- **VPN / Security**: Tailscale, ClamAV Antivirus Daemon
- **System**: GNOME Tweaks & Extension Manager
