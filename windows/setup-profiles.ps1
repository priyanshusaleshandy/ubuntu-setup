# Requires -RunAsAdministrator
# setup-profiles.ps1
# Interactive profile-based software setup script for Windows

# Force TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$sharePath = "\\IKI-LP-80\Sofware"

# Helper: Show Banner
function Show-Banner {
    $line = "=" * 70
    Write-Host $line -ForegroundColor Cyan
    Write-Host "   ____  ______   _____ ______ ______  __  __  ____ " -ForegroundColor Magenta
    Write-Host "  / __ \/ ____/  / ___// ____//_  __/ / / / / / __ \" -ForegroundColor Magenta
    Write-Host " / /_/ / /       \__ \/ __/    / /   / / / / / /_/ /" -ForegroundColor Cyan
    Write-Host "/ ____/ /___    ___/ / /___   / /   / /_/ / / ____/ " -ForegroundColor Cyan
    Write-Host "/_/    \____/  /____/_____/  /_/    \____/ /_/      " -ForegroundColor Blue
    Write-Host ""
    Write-Host "            WORKSTATION PROFILE SETUP TOOLKIT (WINDOWS)" -ForegroundColor White -BackgroundColor DarkBlue
    Write-Host "            Source Share: $sharePath" -ForegroundColor Gray
    Write-Host $line -ForegroundColor Cyan
    Write-Host ""
}

# Helper: Check Admin Privileges (if run directly in PowerShell)
function Confirm-Admin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "[-] This script must be run as Administrator!" -ForegroundColor Red
        Write-Host "[*] Relaunching as Administrator..." -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
        Exit
    }
}

# Helper: Find file in Share or Local folder
function Get-InstallerPath {
    param (
        [string]$FilePattern,
        [string]$FriendlyName
    )
    
    # 1. Check share path
    if (Test-Path $sharePath) {
        $files = Get-ChildItem -Path $sharePath -Filter $FilePattern -ErrorAction SilentlyContinue
        if ($files) {
            # Sort descending to get the newest file if multiple matches exist
            $latest = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            return $latest.FullName
        }
    }
    
    # 2. Check local path (fallback to script's directory)
    $localDir = $PSScriptRoot
    if (-not $localDir) { $localDir = (Get-Location).Path }
    $files = Get-ChildItem -Path $localDir -Filter $FilePattern -ErrorAction SilentlyContinue
    if ($files) {
        $latest = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        return $latest.FullName
    }
    
    return $null
}

# Helper: Install application
function Install-AppInteractive {
    param (
        [string]$FilePattern,
        [string]$FriendlyName
    )
    
    Write-Host "[*] Searching for $FriendlyName installer (Pattern: $FilePattern)..." -ForegroundColor Yellow
    $filePath = Get-InstallerPath -FilePattern $FilePattern
    
    if ($filePath) {
        Write-Host "[+] Found installer at: $filePath" -ForegroundColor Cyan
        Write-Host "[*] Launching $FriendlyName installation wizard..." -ForegroundColor Cyan
        Write-Host "    --> Please complete the setup in the window that opens..." -ForegroundColor White
        
        try {
            if ($filePath.EndsWith(".msi")) {
                # Launch msi installer interactively
                Start-Process msiexec.exe -ArgumentList "/i `"$filePath`"" -Wait -NoNewWindow
            } else {
                # Launch EXE installer interactively
                Start-Process -FilePath $filePath -Wait -NoNewWindow
            }
            Write-Host "[+] Finished running $FriendlyName setup." -ForegroundColor Green
        } catch {
            Write-Host "[-] Error running installer: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "[-] Could not find installer for $FriendlyName in '$sharePath' or current directory." -ForegroundColor Red
        Write-Host "    Please ensure you have access to the share or place the file locally." -ForegroundColor Yellow
    }
    Write-Host ""
}

# Helper: Install Winget package
function Install-WingetPackage {
    param (
        [string]$PackageId,
        [string]$FriendlyName
    )
    Write-Host "[*] Installing $FriendlyName ($PackageId) via Winget..." -ForegroundColor Yellow
    winget install --id $PackageId --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[+] $FriendlyName installed successfully." -ForegroundColor Green
    } else {
        # Check if already installed
        $check = winget list --id $PackageId 2>$null
        if ($check -match $PackageId) {
            Write-Host "[+] $FriendlyName is already installed." -ForegroundColor Green
        } else {
            Write-Host "[-] Failed to install $FriendlyName via Winget (Exit Code: $LASTEXITCODE)." -ForegroundColor Red
        }
    }
    Write-Host ""
}

# Helper: Install Winget with fallback
function Ensure-Winget {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "[-] Winget is not installed. Installing App Installer package..." -ForegroundColor Yellow
        $url = "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
        $outFile = "$env:TEMP\winget.msixbundle"
        Write-Host "[*] Downloading Winget bundle..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing
        Write-Host "[*] Registering package..." -ForegroundColor Cyan
        Add-AppxPackage -Path $outFile
        Remove-Item -Path $outFile -ErrorAction SilentlyContinue
        Write-Host "[+] Winget installed successfully." -ForegroundColor Green
    } else {
        Write-Host "[+] Winget is available." -ForegroundColor Green
    }
    Write-Host ""
}

# Helper: Install NVM and Node
function Install-NvmAndNode {
    Write-Host "[*] Installing NVM (Node Version Manager)..." -ForegroundColor Yellow
    winget install --id CoreyButler.NVMForWindows --silent --accept-package-agreements --accept-source-agreements
    
    # Reload environment variables for the current PowerShell session to discover NVM
    Write-Host "[*] Loading environment variables to run NVM..." -ForegroundColor Cyan
    $env:NVM_HOME = [System.Environment]::GetEnvironmentVariable("NVM_HOME", "Machine")
    if (!$env:NVM_HOME) { $env:NVM_HOME = [System.Environment]::GetEnvironmentVariable("NVM_HOME", "User") }
    $env:NVM_SYMLINK = [System.Environment]::GetEnvironmentVariable("NVM_SYMLINK", "Machine")
    if (!$env:NVM_SYMLINK) { $env:NVM_SYMLINK = [System.Environment]::GetEnvironmentVariable("NVM_SYMLINK", "User") }
    
    if ($env:NVM_HOME -and (Test-Path $env:NVM_HOME)) {
        $env:PATH = "$env:PATH;$env:NVM_HOME;$env:NVM_SYMLINK"
        Write-Host "[+] NVM paths configured in current session." -ForegroundColor Green
        
        Write-Host "[*] Installing Node.js v15.14.0 via NVM..." -ForegroundColor Yellow
        cmd.exe /c "nvm install 15.14.0"
        cmd.exe /c "nvm use 15.14.0"
        
        # Verify Node
        if (Get-Command node -ErrorAction SilentlyContinue) {
            $nodeVer = node -v
            Write-Host "[+] Node.js installed successfully: $nodeVer" -ForegroundColor Green
        } else {
            Write-Host "[!] Node.js installed, but path is not refreshed yet. Please open a new shell and type: nvm use 15.14.0" -ForegroundColor Yellow
        }
    } else {
        Write-Host "[-] NVM was installed but path loading failed. Please restart terminal and run: nvm install 15.14.0" -ForegroundColor Red
    }
    Write-Host ""
}

# Profile Tasks
function Run-i3Profile {
    Write-Host "==============================================" -ForegroundColor Green
    Write-Host " Starting [i3 - Normal User Profile] Installation" -ForegroundColor Green
    Write-Host "==============================================" -ForegroundColor Green
    
    # 1. Connect to Share Check
    if (-not (Test-Path $sharePath)) {
        Write-Host "[!] Warning: Cannot reach network path '$sharePath'." -ForegroundColor Yellow
        Write-Host "    Make sure you are connected to the network/VPN. Fallback to current folder will be used." -ForegroundColor Yellow
        Write-Host ""
    }
    
    # 2. Chrome and Tailscale from winget
    Ensure-Winget
    Install-WingetPackage -PackageId "Google.Chrome" -FriendlyName "Google Chrome"
    Install-WingetPackage -PackageId "Tailscale.Tailscale" -FriendlyName "Tailscale"
    
    # 3. Share-based Interactive Installers (Action1 Agent, Brave, Basecamp, DrSprinto, Time Doctor)
    Install-AppInteractive -FilePattern "action1_agent*.msi" -FriendlyName "Action1 Agent"
    Install-AppInteractive -FilePattern "BraveBrowserSetup*.exe" -FriendlyName "Brave Browser"
    Install-AppInteractive -FilePattern "Basecamp-setup*.exe" -FriendlyName "Basecamp 3"
    Install-AppInteractive -FilePattern "DrSprinto Setup*.exe" -FriendlyName "Sprinto Compliance Agent"
    Install-AppInteractive -FilePattern "timedoctor2-setup*.msi" -FriendlyName "Time Doctor 2"
    
    Write-Host "`n[+] i3 Normal User Profile setup complete!" -ForegroundColor Green
}

function Run-i5Profile {
    Write-Host "==============================================" -ForegroundColor Green
    Write-Host " Starting [i5 - Developer User Profile] Installation" -ForegroundColor Green
    Write-Host "==============================================" -ForegroundColor Green
    
    # 1. Run base i3 profile
    Run-i3Profile
    
    Write-Host "`n==============================================" -ForegroundColor Cyan
    Write-Host " Installing Developer tools..." -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor Cyan
    
    # 2. Developer tools
    Install-WingetPackage -PackageId "Microsoft.VisualStudioCode" -FriendlyName "VS Code"
    Install-WingetPackage -PackageId "dbeaver.dbeaver" -FriendlyName "DBeaver Community Edition"
    Install-NvmAndNode
    
    Write-Host "`n[+] i5 Developer User Profile setup complete!" -ForegroundColor Green
}

# Main Script logic
Confirm-Admin
Show-Banner

Write-Host "Please select the workstation profile to install:" -ForegroundColor White
Write-Host " [1] i3 Profile - Normal User (Chrome, Tailscale, Action1 Agent, Brave, Basecamp, Sprinto, Time Doctor)" -ForegroundColor Cyan
Write-Host " [2] i5 Profile - Developer User (i3 Suite + VS Code, DBeaver, NVM + Node 15.14.0)" -ForegroundColor Cyan
Write-Host " [0] Exit Setup" -ForegroundColor Yellow
Write-Host ""
$choice = Read-Host "Enter your choice (1, 2, or 0)"

switch ($choice) {
    "1" {
        Run-i3Profile
    }
    "2" {
        Run-i5Profile
    }
    "0" {
        Write-Host "Exiting setup. No changes made." -ForegroundColor Gray
        Exit
    }
    Default {
        Write-Host "Invalid choice. Exiting setup." -ForegroundColor Red
        Exit
    }
}

Write-Host "`n[*] Execution finished. Press any key to exit..." -ForegroundColor Gray
[void][System.Console]::ReadKey($true)
