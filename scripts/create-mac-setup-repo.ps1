# ==============================================================================
# create-mac-setup-repo.ps1
# Creates GitHub repo "mac-setup-cli" and pushes setup-center-cli-mac.sh
# ==============================================================================
# Run karo:
#   Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
#   .\create-mac-setup-repo.ps1
# ==============================================================================

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "  ║   macOS Setup CLI — GitHub Repo Creator             ║" -ForegroundColor Magenta
Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""

# ── Config ────────────────────────────────────────────────────────────────────
$REPO_NAME    = "mac-setup-cli"
$REPO_DESC    = "macOS terminal setup script — Homebrew, Tailscale, tools installer (macOS version of setup-center-cli)"
$GITHUB_USER  = "priyanshusaleshandy"
$SOURCE_DIR   = "D:\ubuntu-setup"
$SCRIPT_FILE  = "setup-center-cli-mac.sh"
$REPO_DIR     = "D:\mac-setup-cli"   # New separate folder for this repo

# ── Step 1: Check Prerequisites ───────────────────────────────────────────────
Write-Host "[1/6] Checking prerequisites..." -ForegroundColor Cyan

# Check git
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "[ERR] git not found! Install from: https://git-scm.com/download/win" -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] git found: $(git --version)" -ForegroundColor Green

# Check gh (GitHub CLI)
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host "[WARN] GitHub CLI (gh) not found." -ForegroundColor Yellow
    Write-Host "  Installing via winget..." -ForegroundColor Gray
    winget install --id GitHub.cli -e --accept-package-agreements --accept-source-agreements
    # Refresh PATH
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Host "[ERR] gh install failed. Download from: https://cli.github.com" -ForegroundColor Red
        exit 1
    }
}
Write-Host "  [OK] GitHub CLI found: $(gh --version | Select-Object -First 1)" -ForegroundColor Green

# ── Step 2: GitHub Auth ───────────────────────────────────────────────────────
Write-Host ""
Write-Host "[2/6] Checking GitHub authentication..." -ForegroundColor Cyan
$authStatus = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "[WARN] Not logged in to GitHub. Running gh auth login..." -ForegroundColor Yellow
    Write-Host "  (Browser will open — log in with $GITHUB_USER account)" -ForegroundColor Gray
    gh auth login --web --git-protocol https
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERR] GitHub login failed." -ForegroundColor Red
        exit 1
    }
}
Write-Host "  [OK] GitHub authenticated." -ForegroundColor Green

# ── Step 3: Create Repo Directory ────────────────────────────────────────────
Write-Host ""
Write-Host "[3/6] Setting up local repo folder: $REPO_DIR" -ForegroundColor Cyan

if (Test-Path $REPO_DIR) {
    Write-Host "  [INFO] Folder exists — clearing it..." -ForegroundColor Yellow
    Remove-Item -Recurse -Force "$REPO_DIR\*" -ErrorAction SilentlyContinue
} else {
    New-Item -ItemType Directory -Path $REPO_DIR -Force | Out-Null
}

# Copy the mac setup script
$srcFile = Join-Path $SOURCE_DIR $SCRIPT_FILE
if (-not (Test-Path $srcFile)) {
    Write-Host "[ERR] Source file not found: $srcFile" -ForegroundColor Red
    Write-Host "  Make sure setup-center-cli-mac.sh is in D:\ubuntu-setup\" -ForegroundColor Gray
    exit 1
}
Copy-Item $srcFile "$REPO_DIR\$SCRIPT_FILE"
Write-Host "  [OK] Copied $SCRIPT_FILE to $REPO_DIR" -ForegroundColor Green

# ── Step 4: Create README ─────────────────────────────────────────────────────
Write-Host ""
Write-Host "[4/6] Creating README.md..." -ForegroundColor Cyan

$readmeContent = @"
# mac-setup-cli

**macOS terminal setup script** — ek hi script mein sab kuch install aur configure karo.

Ubuntu ke liye `setup-center-cli.sh` ka macOS version.

---

## Features

| Menu | Description |
|------|-------------|
| **[1] Install Packages** | Homebrew se tools select karke install karo |
| **[2] Uninstall Packages** | Select karke remove karo |
| **[3] System Status** | Kya installed hai, kya nahi — ek nazar mein |
| **[4] Update System** | `brew update + upgrade` + macOS software updates |
| **[5] Tailscale VPN** | Install / login / connect / diagnose / remove |
| **[6] System Config** | Hostname set, git config |
| **[7] Time Doctor** | Install, uninstall, status |
| **[8] macOS Settings** | Screen timeout, dark mode, Gatekeeper |
| **[9] Network/WiFi** | DNS flush, DHCP renew, ping test |

## Included Apps (via Homebrew)

- Core Utilities (git, curl, wget, htop, tmux, tree)
- Node.js LTS (via NVM)
- Google Chrome
- Visual Studio Code
- MySQL Workbench
- DBeaver Community
- Postman
- Redis Insight
- MongoDB Compass
- Tailscale VPN
- iTerm2
- Time Doctor
- ESET PROTECT Agent
- Action1 Agent (RMM)
- Rectangle (Window Manager)
- Screen Timeout config (14 min)

## Requirements

- macOS 12+ (Monterey or newer)
- Internet connection
- The script will auto-install **Xcode CLT** and **Homebrew** if missing

## Usage

``````bash
# Download
curl -O https://raw.githubusercontent.com/priyanshusaleshandy/mac-setup-cli/main/setup-center-cli-mac.sh

# Make executable
chmod +x setup-center-cli-mac.sh

# Run
./setup-center-cli-mac.sh
``````

Or from USB/pendrive (no chmod needed):
``````bash
bash setup-center-cli-mac.sh
``````

## Notes

- Script automatically copies itself to `~/.local/share/setup-center/` on first run (USB pendrive safe)
- Tailscale login link is auto-sent to admin ntfy channel (no manual copy-paste needed)
- All installs use Homebrew Cask — no manual `.dmg` hunting

---

*Maintained by: Priyanshu Suryavanshi / Saleshandy*
"@

Set-Content -Path "$REPO_DIR\README.md" -Value $readmeContent -Encoding UTF8
Write-Host "  [OK] README.md created." -ForegroundColor Green

# ── Step 5: Git Init & Commit ─────────────────────────────────────────────────
Write-Host ""
Write-Host "[5/6] Initializing git and committing..." -ForegroundColor Cyan

Set-Location $REPO_DIR

git init
git config user.email "priyanshusuryavanshi@saleshandy.com"
git config user.name "Priyanshu Kumar"
git add .
git commit -m "initial commit: macOS Setup Center CLI script (Homebrew edition)"

Write-Host "  [OK] Initial commit done." -ForegroundColor Green

# ── Step 6: Create GitHub Repo & Push ────────────────────────────────────────
Write-Host ""
Write-Host "[6/6] Creating GitHub repo and pushing..." -ForegroundColor Cyan

# Check if repo already exists
$repoExists = gh repo view "$GITHUB_USER/$REPO_NAME" 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  [WARN] Repo already exists on GitHub. Will push to existing repo." -ForegroundColor Yellow
    git remote remove origin 2>$null
    git remote add origin "https://github.com/$GITHUB_USER/$REPO_NAME.git"
} else {
    Write-Host "  Creating new repo: github.com/$GITHUB_USER/$REPO_NAME ..." -ForegroundColor Gray
    gh repo create $REPO_NAME `
        --public `
        --description $REPO_DESC `
        --source . `
        --remote origin `
        --push
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERR] Failed to create GitHub repo." -ForegroundColor Red
        exit 1
    }
}

git branch -M main
git push -u origin main --force

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║   SUCCESS! Repo created and pushed!                 ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  GitHub URL : https://github.com/$GITHUB_USER/$REPO_NAME" -ForegroundColor Cyan
Write-Host "  Local Dir  : $REPO_DIR" -ForegroundColor Gray
Write-Host ""
Write-Host "  macOS pe run karne ka command:" -ForegroundColor Yellow
Write-Host "  curl -O https://raw.githubusercontent.com/$GITHUB_USER/$REPO_NAME/main/setup-center-cli-mac.sh" -ForegroundColor White
Write-Host "  chmod +x setup-center-cli-mac.sh && ./setup-center-cli-mac.sh" -ForegroundColor White
Write-Host ""

# Open in browser
$open = Read-Host "  Browser mein repo open karein? (y/N)"
if ($open -match '^[Yy]$') {
    Start-Process "https://github.com/$GITHUB_USER/$REPO_NAME"
}
