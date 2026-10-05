# Convert line endings to LF for both scripts and push to GitHub
$files = @("setup-center-cli-mac.sh", "core-mac-setup.sh")

foreach ($f in $files) {
    $src = "D:\ubuntu-setup\$f"
    $dst = "D:\mac-setup-cli\$f"
    $text = [System.IO.File]::ReadAllText($src)
    $text = $text -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($dst, $text, [System.Text.Encoding]::UTF8)
    Write-Host "Prepared $f with LF endings" -ForegroundColor Gray
}

Set-Location "D:\mac-setup-cli"
git add .
git commit -m "feat: add full Tailscale login, Headscale, ntfy admin auto-login link menu to macOS script"
git push origin main
Write-Host "`n[OK] Tailscale login features pushed to GitHub!" -ForegroundColor Green
