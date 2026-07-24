# push-ubuntu-setup.ps1
# Automates cleaning secrets, committing and pushing setup script updates to GitHub

Write-Host "=== Pushing Ubuntu/Windows Setup Center Updates to GitHub ===" -ForegroundColor Cyan

Set-Location -Path "D:\ubuntu-setup"

# 1. Clean untracked secrets
Write-Host "[1/4] Ensuring secret files are un-tracked..." -ForegroundColor Yellow
git rm --cached credentials.json.json 2>$null
git rm --cached sheets-console/sheets-credentials.json 2>$null
git rm --cached Omada 2>$null

# 2. Configure Git identity
$gitEmail = git config --global user.email
$gitName = git config --global user.name

if ([string]::IsNullOrEmpty($gitEmail)) { git config --global user.email "priyanshusuryavanshi@saleshandy.com" }
if ([string]::IsNullOrEmpty($gitName)) { git config --global user.name "Priyanshu Kumar" }

# 3. Stage & Commit
Write-Host "[2/4] Staging updated scripts..." -ForegroundColor Yellow
git add .gitignore setup-center-cli.ps1 setup-center-cli.sh RUN-SETUP.bat push-ubuntu-setup.ps1 windows/ linux/ README.md

Write-Host "[3/4] Committing changes..." -ForegroundColor Yellow
git commit -m "fix(tailscale): fix tailscale options, service auto-start, complete uninstall cleanup, and sync linux script"

# 4. Push to GitHub
Write-Host "[4/4] Pushing to GitHub (origin main)..." -ForegroundColor Yellow
git push origin main --force

if ($LASTEXITCODE -eq 0) {
    Write-Host "`n[OK] Successfully pushed all setup scripts to GitHub!" -ForegroundColor Green
} else {
    Write-Host "`n[ERR] Push failed. Check terminal output." -ForegroundColor Red
}
