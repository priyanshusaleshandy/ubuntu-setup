# push-repos.ps1
# Automates pushing both new repositories to GitHub

Write-Host "=== GitHub Repository Push Automation ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Step 1: Please ensure you have created two blank repositories on your GitHub account:" -ForegroundColor Yellow
Write-Host " - Name: setup-center-desktop  -> (URL: https://github.com/priyanshusaleshandy/setup-center-desktop.git)" -ForegroundColor Gray
Write-Host " - Name: mac-mini-ai-stack     -> (URL: https://github.com/priyanshusaleshandy/mac-mini-ai-stack.git)" -ForegroundColor Gray
Write-Host ""
Write-Host "Please do NOT add README, LICENSE, or gitignore when creating them on GitHub." -ForegroundColor Yellow
Write-Host ""
$confirm = Read-Host "Have you created both repositories on GitHub? (y/N)"
if ($confirm -notmatch '^[Yy]$') {
    Write-Host "Cancelled. Please run the script again after creating the repositories on GitHub." -ForegroundColor Red
    exit
}

# Ensure Git User configuration is set (using your identity)
$gitEmail = git config --global user.email
$gitName = git config --global user.name

if ([string]::IsNullOrEmpty($gitEmail)) {
    git config --global user.email "priyanshusuryavanshi@saleshandy.com"
}
if ([string]::IsNullOrEmpty($gitName)) {
    git config --global user.name "Priyanshu Kumar"
}

# 1. Push setup-center-desktop
Write-Host "`n=== [1/2] Pushing GUI Desktop App to setup-center-desktop ===" -ForegroundColor Cyan
if (Test-Path "D:\setup-center-desktop") {
    cd "D:\setup-center-desktop"
    git init
    git add .
    git commit -m "initial commit: Setup Center GUI Desktop application (Electron + React)"
    git remote remove origin 2>$null
    git remote add origin "https://github.com/priyanshusaleshandy/setup-center-desktop.git"
    git branch -M main
    git push -u origin main -f
    Write-Host "[OK] setup-center-desktop pushed successfully!" -ForegroundColor Green
} else {
    Write-Host "[ERR] D:\setup-center-desktop folder not found!" -ForegroundColor Red
}

# 2. Push mac-mini-ai-stack
Write-Host "`n=== [2/2] Pushing Mac Mini AI files to mac-mini-ai-stack ===" -ForegroundColor Cyan
if (Test-Path "D:\mac-mini-ai-stack") {
    cd "D:\mac-mini-ai-stack"
    git init
    git add .
    git commit -m "initial commit: local GPU accelerated LLM stack for Mac Mini"
    git remote remove origin 2>$null
    git remote add origin "https://github.com/priyanshusaleshandy/mac-mini-ai-stack.git"
    git branch -M main
    git push -u origin main -f
    Write-Host "[OK] mac-mini-ai-stack pushed successfully!" -ForegroundColor Green
} else {
    Write-Host "[ERR] D:\mac-mini-ai-stack folder not found!" -ForegroundColor Red
}

Write-Host "`n=== All done! Both repositories have been successfully pushed to GitHub! ===" -ForegroundColor Green
