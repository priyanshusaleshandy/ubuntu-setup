# Setup Center CLI

**Lightweight CLI scripts** — the full power of [Setup Center EXE](https://github.com/priyanshusaleshandy/ubuntu-setup), runnable from any fresh terminal with a single command.

| Platform | Script | One-liner |
|----------|--------|-----------|
| **Windows** | `setup-center-cli.ps1` | `Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; iex (irm https://raw.githubusercontent.com/Priyanshu8494/ubuntu-setup/main/setup-center-cli.ps1)` |
| **Ubuntu/Linux** | `setup-center-cli.sh` | `bash <(curl -fsSL https://raw.githubusercontent.com/priyanshusaleshandy/setup-center-cli/main/setup-center-cli.sh)` |

---

## Windows — PowerShell

> Paste into any **PowerShell window** (handles auto-elevation & execution policy):

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; iex (irm https://raw.githubusercontent.com/Priyanshu8494/ubuntu-setup/main/setup-center-cli.ps1)
```

### Features
| Option | Feature |
|--------|---------|
| `[1]` | Install Essential Software — Chrome, Firefox, WinRAR, VLC, Sumatra PDF, AnyDesk, UltraViewer |
| `[2]` | Install MS Office 2021 Pro Plus |
| `[3]` | System Activation Toolkit (get.activated.win) |
| `[4]` | Update All Software (winget upgrade --all) |
| `[5]` | Advanced Toolkit — Chris Titus WinUtil |
| `[6]` | RAM Optimizer — Test / Install permanent / Remove |
| `[7]` | Office Software — RabbitMQ & ElasticSearch install / repair |
| `[8]` | System Setup — Network info / Change hostname / Create user |
| `[9]` | Tailscale VPN — Install / Login / Connect / Diagnose / Remove |

---

## Ubuntu / Linux — Bash

> Run as a **normal user** (script asks for sudo when needed):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/priyanshusaleshandy/setup-center-cli/main/setup-center-cli.sh)
```

Or download and run locally:
```bash
curl -fsSL https://raw.githubusercontent.com/priyanshusaleshandy/setup-center-cli/main/setup-center-cli.sh -o setup.sh
chmod +x setup.sh
./setup.sh
```

### Features
| Option | Feature |
|--------|---------|
| `[1]` | Install Packages — 12 tools with checkbox toggle UI |
| `[2]` | Uninstall Packages — remove selected or all |
| `[3]` | System Status — check installed + running services |
| `[4]` | Update System — apt update + upgrade |
| `[5]` | Tailscale VPN — Install / Login / Connect / Diagnose / Remove |
| `[6]` | System Config — Hostname & Git global config |
| `[7]` | Create Onboarding User |

### Supported packages
- Core Utilities & libfuse2
- Node.js v15.14.0 (via NVM)
- Google Chrome
- Visual Studio Code
- MySQL Workbench
- DBeaver Community Edition
- Postman (Snap)
- Redis Insight (Snap)
- MongoDB Compass
- Tailscale VPN
- GNOME Tweaks & Extension Manager
- ClamAV Antivirus

---

## Requirements

**Windows:** PowerShell 5.1+, run as Administrator, winget installed  
**Ubuntu:** Ubuntu 20.04 / 22.04 / 24.04 LTS, curl installed

---

*Built by Priyanshu Suryavanshi — Saleshandy IT*
