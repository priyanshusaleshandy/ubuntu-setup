# .SYNOPSIS
#   Priyanshu Suryavanshi PC Setup Toolkit
# .DESCRIPTION
#   Automated PC setup with software installation and system activation
# .NOTES
#   - Clean UI Edition
#   - Work in progress.

# Force TLS 1.2 for all web requests (Fixes download errors)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# -------------------------------------------------------------------------
# Helper functions
# -------------------------------------------------------------------------
function Show-Header {
    Clear-Host
    $width = 70
    $line = "=" * $width
    
    Write-Host $line -ForegroundColor Cyan
    Write-Host "    ____  ______   _____ ______ ______  __  __  ____" -ForegroundColor Magenta
    Write-Host "   / __ \/ ____/  / ___// ____//_  __/ / / / / / __ \" -ForegroundColor Magenta
    Write-Host "  / /_/ / /       \__ \/ __/    / /   / / / / / /_/ /" -ForegroundColor Cyan
    Write-Host " / ____/ /___    ___/ / /___   / /   / /_/ / / ____/" -ForegroundColor Cyan
    Write-Host "/_/    \____/   /____/_____/  /_/    \____/ /_/     " -ForegroundColor Blue
    Write-Host ""
    Write-Host "      Priyanshu Suryavanshi PC Setup Toolkit" -ForegroundColor White -BackgroundColor DarkBlue
    Write-Host "      Automated Setup & Activation Utility" -ForegroundColor Gray
    Write-Host $line -ForegroundColor Cyan
    Write-Host ""
}

function Show-Menu {
    param (
        [string]$StatusMessage = "",
        [string]$StatusColor = "Yellow"
    )
    Show-Header
    
    # Status Section
    Write-Host " [ SYSTEM STATUS ]" -ForegroundColor Cyan
    if ($StatusMessage) {
        Write-Host "  >> $StatusMessage" -ForegroundColor $StatusColor
    }
    else {
        Write-Host "  >> System Ready. Waiting for input..." -ForegroundColor Green
    }
    Write-Host ""

    # Menu Section
    Write-Host " [ MAIN MENU ]" -ForegroundColor Yellow
    
    $menuItems = @(
        @{ Key = "1"; Label = "Install Essential Software"; Desc = "Browsers, Media, Utilities" },
        @{ Key = "2"; Label = "Install MS Office Suite"; Desc = "Office 2021 Pro Plus" },
        @{ Key = "3"; Label = "System Activation Toolkit"; Desc = "Windows & Office Activation" },
        @{ Key = "4"; Label = "Update All Software"; Desc = "Upgrade via Winget" },
        @{ Key = "5"; Label = "Advanced Toolkit"; Desc = "WinUtil by Chris Titus" },
        @{ Key = "6"; Label = "Ram Optimization"; Desc = "Global Ram Optimization Script" },
        @{ Key = "7"; Label = "Office Software"; Desc = "RabbitMQ & ElasticSearch" },
        @{ Key = "0"; Label = "Exit Application"; Desc = "Close the script" }
    )

    foreach ($item in $menuItems) {
        Write-Host "  [" -NoNewline -ForegroundColor DarkGray
        Write-Host "$($item.Key)" -NoNewline -ForegroundColor Cyan
        Write-Host "] " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($item.Label)" -NoNewline -ForegroundColor White
        if ($item.Desc) {
            Write-Host " - $($item.Desc)" -ForegroundColor DarkGray
        }
        else {
            Write-Host ""
        }
    }
    
    Write-Host ""
    Write-Host "  Tip: Enter the number corresponding to your choice." -ForegroundColor DarkCyan
    Write-Host " ======================================================================" -ForegroundColor Cyan
}

function Show-Loading {
    param([string]$Message = "Processing")
    $spinner = @('|', '/', '-', '\')
    Write-Host -NoNewline "  ⏳ $Message " -ForegroundColor Yellow
    
    for ($i = 0; $i -lt 15; $i++) {
        foreach ($char in $spinner) {
            Write-Host -NoNewline "`b$char" -ForegroundColor Cyan
            Start-Sleep -Milliseconds 100
        }
    }
    Write-Host "`b✅ Done!" -ForegroundColor Green
    Write-Host ""
}

# -------------------------------------------------------------------------
# Ensure package managers present
# -------------------------------------------------------------------------
function Ensure-PackageManagers {
    # Check winget
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "`n❌ Winget is not installed or not available in PATH!" -ForegroundColor Red
        Write-Host "➡️ Please install Winget from: https://aka.ms/getwinget" -ForegroundColor Yellow
        # Do not automatically exit — allow user to continue for tasks that don't need winget
    }
    else {
        Write-Host "`n✅ Winget detected." -ForegroundColor Green
    }

    # Check Chocolatey, install if missing
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Host "🍫 Chocolatey not found. Installing now..." -ForegroundColor Yellow
        try {
            Set-ExecutionPolicy Bypass -Scope Process -Force
            $chocoInstallScript = 'https://community.chocolatey.org/install.ps1'
            Invoke-Expression ((New-Object System.Net.WebClient).DownloadString($chocoInstallScript))
            Write-Host "✅ Chocolatey installation attempted. You may need to re-open shell." -ForegroundColor Green
        }
        catch {
            Write-Host "❌ Chocolatey install failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    else {
        Write-Host "✅ Chocolatey detected." -ForegroundColor Green
    }
}

# -------------------------------------------------------------------------
# Utility: Create Desktop Shortcut
# -------------------------------------------------------------------------
function New-DesktopShortcut {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$ShortcutName,
        [string]$Arguments = ""
    )
    try {
        $desktop = [Environment]::GetFolderPath("Desktop")
        $WshShell = New-Object -ComObject WScript.Shell
        $Shortcut = $WshShell.CreateShortcut("$desktop\$ShortcutName.lnk")
        $Shortcut.TargetPath = $TargetPath
        if ($Arguments) { $Shortcut.Arguments = $Arguments }
        $Shortcut.IconLocation = "$TargetPath,0"
        $Shortcut.Save()
        return $true
    }
    catch {
        return $false
    }
}

# -------------------------------------------------------------------------
# Software installation
# -------------------------------------------------------------------------
function Install-AnyDeskDirectly {
    $anydeskUrl = "https://download.anydesk.com/AnyDesk.exe"
    $installPath = "C:\AnyDesk"
    $exePath = Join-Path $installPath "AnyDesk.exe"

    Write-Host "`n [ INSTALLING ANYDESK ]" -ForegroundColor Cyan
    Write-Host " Target: $installPath" -ForegroundColor Gray
    try {
        if (-not (Test-Path $installPath)) {
            New-Item -ItemType Directory -Path $installPath -Force | Out-Null
        }
        Write-Host "⏬ Downloading AnyDesk..." -ForegroundColor Yellow
        Invoke-WebRequest -Uri $anydeskUrl -OutFile $exePath -UseBasicParsing -ErrorAction Stop

        Write-Host "🚀 Running AnyDesk installer (silent flags may vary)..." -ForegroundColor Yellow
        Start-Process -FilePath $exePath -ArgumentList "--install" -Wait -NoNewWindow -ErrorAction SilentlyContinue

        # Create shortcut (if executable exists)
        if (Test-Path $exePath) {
            if (New-DesktopShortcut -TargetPath $exePath -ShortcutName "AnyDesk") {
                Write-Host "✅ AnyDesk installed and shortcut created." -ForegroundColor Green
            }
            else {
                Write-Host "✅ AnyDesk downloaded. Shortcut creation failed or skipped." -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "❌ AnyDesk installer file not found after download." -ForegroundColor Red
        }
    }
    catch {
        Write-Host "❌ Error installing AnyDesk: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Install-UltraViewerDirectly {
    $uvUrl = "https://ultraviewer.net/UltraViewer_setup.exe"
    $installPath = "C:\UltraViewer"
    $exePath = Join-Path $installPath "UltraViewer_setup.exe"

    Write-Host "`n [ INSTALLING ULTRAVIEWER ]" -ForegroundColor Cyan
    Write-Host " Target: $installPath" -ForegroundColor Gray
    try {
        if (-not (Test-Path $installPath)) {
            New-Item -ItemType Directory -Path $installPath -Force | Out-Null
        }
        Write-Host "⏬ Downloading UltraViewer..." -ForegroundColor Yellow
        Invoke-WebRequest -Uri $uvUrl -OutFile $exePath -UseBasicParsing -ErrorAction Stop

        Write-Host "🚀 Running UltraViewer installer silently..." -ForegroundColor Yellow
        Start-Process -FilePath $exePath -ArgumentList "/VERYSILENT", "/NORESTART" -Wait -NoNewWindow -ErrorAction SilentlyContinue

        $installedPath = "C:\Program Files\UltraViewer\UltraViewer.exe"
        if (Test-Path $installedPath) {
            if (New-DesktopShortcut -TargetPath $installedPath -ShortcutName "UltraViewer") {
                Write-Host "✅ UltraViewer installed and shortcut created." -ForegroundColor Green
            }
            else {
                Write-Host "✅ UltraViewer installed. Shortcut creation failed or skipped." -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "⚠️ UltraViewer installer ran but expected EXE not found; verify install location." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "❌ Error installing UltraViewer: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# -------------------------------------------------------------------------
# Local Software Repository Helper
# -------------------------------------------------------------------------
# Maps winget package IDs / custom IDs to expected installer filenames on repo
$repoFileMap = @{
    "winget:Google.Chrome"              = @{ Pattern = "Chrome*";          Default = "Chrome.exe" }
    "winget:Brave.Brave"                = @{ Pattern = "Brave*";           Default = "BraveBrowserSetup-BRV011.exe" }
    "winget:ESET.NOD32Antivirus"        = @{ Pattern = "ESET*";            Default = "ESET.exe" }
    "winget:Tailscale.Tailscale"        = @{ Pattern = "Tailscale*";       Default = "Tailscale.exe" }
    "winget:RustDesk.RustDesk"          = @{ Pattern = "RustDesk*";        Default = "RustDesk.exe" }
    "winget:Microsoft.VisualStudioCode" = @{ Pattern = "VSCode*";          Default = "VSCode.exe" }
    "winget:Git.Git"                    = @{ Pattern = "Git*";             Default = "Git.exe" }
    "winget:Oracle.MySQLWorkbench"      = @{ Pattern = "MySQL-Workbench*"; Default = "MySQL-Workbench.exe" }
    "winget:dbeaver.dbeaver"            = @{ Pattern = "DBeaver*";         Default = "DBeaver.exe" }
    "winget:Postman.Postman"            = @{ Pattern = "Postman*";         Default = "Postman.exe" }
    "winget:RedisLabs.RedisInsight"     = @{ Pattern = "RedisInsight*";    Default = "RedisInsight.exe" }
    "winget:MongoDB.Compass.Full"       = @{ Pattern = "MongoDB-Compass*"; Default = "MongoDB-Compass.exe" }
    "custom:timedoctor"                 = @{ Pattern = "timedoctor*";      Default = "timedoctor2-setup-3.18.70-windows.msi" }
    "custom:basecamp"                   = @{ Pattern = "Basecamp*";        Default = "Basecamp-setup.exe" }
    "custom:sprinto"                    = @{ Pattern = "sfproc*";          Default = "sfproc-3.18.74-67ebb4c267041f1c3eb98aab.msi" }
    "custom:action1"                    = @{ Pattern = "Action1*";         Default = "Action1.exe" }
    "custom:nvm-node"                   = @{ Pattern = "NVM-Setup*";       Default = "NVM-Setup.exe" }
}

function Get-InstallerFromRepo {
    param([string]$AppID, [string]$AppName)

    if ([string]::IsNullOrWhiteSpace($softwareRepoUrl)) { return $null }
    if (-not $repoFileMap.ContainsKey($AppID))          { return $null }

    $map = $repoFileMap[$AppID]
    $pattern = $map.Pattern
    $defaultName = $map.Default

    try {
        if (Test-Path $softwareRepoUrl -ErrorAction SilentlyContinue) {
            # Directory path (local or UNC share)
            $file = Get-ChildItem -Path $softwareRepoUrl -Filter $pattern | Select-Object -First 1
            if ($file) {
                $fileName = $file.Name
                $dest = "$env:TEMP\repo-$fileName"
                $src = $file.FullName
                Write-Host "  📂 Copying $AppName from repo ($fileName)..." -ForegroundColor Yellow
                Copy-Item -Path $src -Destination $dest -Force -ErrorAction Stop
                Write-Host "  ✅ Downloaded from repo." -ForegroundColor Green
                return $dest
            } else {
                Write-Host "  ⚠️  File matching pattern '$pattern' not found in repo: $softwareRepoUrl" -ForegroundColor Yellow
            }
        } else {
            # HTTP/HTTPS URL
            $dest = "$env:TEMP\repo-$defaultName"
            $url = "$softwareRepoUrl/$defaultName"
            Write-Host "  ⏬ Downloading $AppName from repo URL: $url" -ForegroundColor Yellow
            (New-Object System.Net.WebClient).DownloadFile($url, $dest)
            if (Test-Path $dest) {
                Write-Host "  ✅ Downloaded from repo." -ForegroundColor Green
                return $dest
            }
        }
    } catch {
        Write-Host "  ⚠️  Repo download/copy failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "       Falling back to winget/internet..." -ForegroundColor Gray
    }
    return $null
}

function Install-LocalExe {
    param([string]$Path, [string]$AppName)

    if ($Path -like "*.msi") {
        Write-Host "🚀 Running MSI installer silently..." -ForegroundColor Yellow
        try {
            $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$Path`" /qn /norestart" -Wait -NoNewWindow -PassThru -ErrorAction Stop
            if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
                Write-Host "✅ $AppName installed successfully from local repo (MSI)." -ForegroundColor Green
                return $true
            } else {
                Write-Host "  ⚠️  Silent MSI install returned exit code $($proc.ExitCode). Launching interactive MSI..." -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  ⚠️  Silent MSI install failed. Launching interactive MSI..." -ForegroundColor Yellow
        }
        # Interactive fallback
        Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$Path`"" -Wait -NoNewWindow -ErrorAction SilentlyContinue
        Write-Host "✅ $AppName installer launched." -ForegroundColor Green
        return $true
    }

    # Otherwise it's an EXE
    # Try common silent install flags in order
    $silentFlags = @("/S", "/VERYSILENT", "/quiet", "/silent")
    foreach ($flag in $silentFlags) {
        try {
            $proc = Start-Process -FilePath $Path -ArgumentList $flag -Wait -NoNewWindow -PassThru -ErrorAction Stop
            if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
                Write-Host "✅ $AppName installed from local repo." -ForegroundColor Green
                return $true
            }
        } catch {}
    }
    # Last resort: run without silent flags
    Write-Host "  ⚠️  Silent install failed. Launching installer UI..." -ForegroundColor Yellow
    Start-Process -FilePath $Path -Wait -NoNewWindow -ErrorAction SilentlyContinue
    Write-Host "✅ $AppName installer launched." -ForegroundColor Green
    return $true
}

function Install-NormalSoftware {
    Ensure-PackageManagers

    $softwareList = @(
        # --- i3 Basic Office Tools ---
        @{Name = "Google Chrome";         ID = "winget:Google.Chrome" },
        @{Name = "Brave Browser";          ID = "winget:Brave.Brave" },
        @{Name = "Basecamp";               ID = "custom:basecamp" },
        @{Name = "Sprinto";                ID = "custom:sprinto" },
        @{Name = "ESET Antivirus";         ID = "winget:ESET.NOD32Antivirus" },
        @{Name = "Time Doctor";            ID = "custom:timedoctor" },
        @{Name = "Action1 RMM";            ID = "custom:action1" },
        @{Name = "Tailscale VPN";          ID = "winget:Tailscale.Tailscale" },
        @{Name = "RustDesk";               ID = "winget:RustDesk.RustDesk" },
        # --- i5/i7 Developer Tools ---
        @{Name = "Visual Studio Code";     ID = "winget:Microsoft.VisualStudioCode" },
        @{Name = "Git";                    ID = "winget:Git.Git" },
        @{Name = "Node.js v15.14 (NVM)";   ID = "custom:nvm-node" },
        @{Name = "MySQL Workbench";        ID = "winget:Oracle.MySQLWorkbench" },
        @{Name = "DBeaver";                ID = "winget:dbeaver.dbeaver" },
        @{Name = "Postman";                ID = "winget:Postman.Postman" },
        @{Name = "Redis Insight";          ID = "winget:RedisLabs.RedisInsight" },
        @{Name = "MongoDB Compass";        ID = "winget:MongoDB.Compass.Full" }
    )

    Write-Host "`n [ SOFTWARE SELECTION ]" -ForegroundColor Yellow
    Write-Host " Select software to install (e.g., 1,3,5 or 'all'):" -ForegroundColor Gray
    Write-Host ""
    for ($i = 0; $i -lt $softwareList.Count; $i++) {
        $num = $i + 1
        $name = $softwareList[$i].Name
        Write-Host "  [" -NoNewline -ForegroundColor DarkGray
        Write-Host "$num" -NoNewline -ForegroundColor Cyan
        Write-Host "] $name" -ForegroundColor White
    }

    $selection = Read-Host "Enter selection (e.g., 1,3,5). Or 'all' to install everything"
    if ($selection.Trim().ToLower() -eq 'all') {
        $selectedIndices = 1..$softwareList.Count
    }
    else {
        $selectedIndices = @()
        foreach ($token in ($selection -split ",")) {
            $t = $token.Trim()
            if ($t -match '^\d+$') {
                $selectedIndices += [int]$t
            }
        }
    }

    foreach ($index in $selectedIndices | Sort-Object -Unique) {
        if ($index -ge 1 -and $index -le $softwareList.Count) {
            $app = $softwareList[$index - 1]
            
            # 1. Try local repository check first for ALL apps
            $localInstaller = Get-InstallerFromRepo -AppID $app.ID -AppName $app.Name
            if ($localInstaller -and (Test-Path $localInstaller)) {
                Install-LocalExe -Path $localInstaller -AppName $app.Name
            }
            # 2. Fallback to normal method
            else {
                if ($app.ID -like "winget:*") {
                    $pkgId = $app.ID.Replace("winget:", "")
                    Write-Host "`n📦 Installing $($app.Name) via winget..." -ForegroundColor Gray
                    try {
                        if (Get-Command winget -ErrorAction SilentlyContinue) {
                            Start-Process -FilePath "winget" -ArgumentList "install --id $pkgId --silent --accept-source-agreements --accept-package-agreements" -Wait -NoNewWindow -ErrorAction Stop
                            Write-Host "✅ $($app.Name) installed via winget." -ForegroundColor Green
                        }
                        else {
                            Write-Host "⚠️ winget not available. Skipping $($app.Name)." -ForegroundColor Yellow
                        }
                    }
                    catch {
                        Write-Host "❌ Failed to install $($app.Name): $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
                elseif ($app.ID -like "shortcut:*") {
                    $parts = $app.ID.Replace("shortcut:", "") -split ":"
                    New-WebShortcut -Url $parts[0] -Name $parts[1]
                }
                elseif ($app.ID -eq "custom:timedoctor") {
                    Install-TimeDoctor
                }
                elseif ($app.ID -eq "custom:basecamp") {
                    Install-Basecamp
                }
                elseif ($app.ID -eq "custom:sprinto") {
                    Install-Sprinto
                }
                elseif ($app.ID -eq "custom:action1") {
                    Install-Action1
                }
                elseif ($app.ID -eq "custom:nvm-node") {
                    Install-NVMAndNode
                }
            }
        }
        else {
            Write-Host "  ⚠️ Invalid selection: $index" -ForegroundColor Red
        }
    }

    Read-Host "Press Enter to return to the menu..."
}

# -------------------------------------------------------------------------
# Office installation
# -------------------------------------------------------------------------
function Install-OfficeOnline {
    # --- CONFIGURATION ---
    # Updated Link (1.33.zip)
    $ZipUrl = "https://github.com/Priyanshu8494/my-choco-install-script/raw/refs/heads/main/Office%20Installer%201.33.zip"

    $BaseDir = "C:\Temp\Office_Auto_Install"
    $ZipPath = "$BaseDir\OfficeInstaller.zip"

    # Clear Screen
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "      OFFICE INSTALLER (UPDATED LINK)     " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    # --- STEP 0: PREPARE FOLDER & BYPASS DEFENDER ---
    Write-Host "[1/5] Preparing Security Exclusions..." -ForegroundColor Yellow

    if (-not (Test-Path $BaseDir)) { New-Item -Path $BaseDir -ItemType Directory -Force | Out-Null }

    try {
        # Defender exclusion to prevent antivirus from deleting the setup
        Add-MpPreference -ExclusionPath $BaseDir -ErrorAction SilentlyContinue
        Write-Host "      Defender Exclusion Added." -ForegroundColor Green
    }
    catch {
        Write-Host "      Warning: Admin rights needed for exclusion." -ForegroundColor Red
    }

    # --- STEP 1: DOWNLOAD ---
    Write-Host "[2/5] Downloading Installer..." -ForegroundColor Yellow
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipPath -ErrorAction Stop
        Write-Host "      Download Complete!" -ForegroundColor Green
    }
    catch {
        Write-Host "Error: Download Failed! Check your internet connection." -ForegroundColor Red
        Write-Host "Details: $_" -ForegroundColor DarkGray
        return
    }

    # --- STEP 2: UNBLOCK & EXTRACT ---
    Write-Host "[3/5] Unblocking & Extracting..." -ForegroundColor Yellow

    # SmartScreen Bypass
    Unblock-File -Path $ZipPath

    # Extract
    Expand-Archive -Path $ZipPath -DestinationPath $BaseDir -Force
    Write-Host "      Extraction Complete!" -ForegroundColor Green

    # --- STEP 3: IDENTIFY FILE ---
    Write-Host "[4/5] Selecting Installer..." -ForegroundColor Yellow

    $Installer64 = Get-ChildItem -Path $BaseDir -Filter "Office Installer.exe" -Recurse | Select-Object -First 1
    $Installer32 = Get-ChildItem -Path $BaseDir -Filter "Office Installer x86.exe" -Recurse | Select-Object -First 1

    $TargetFile = $null
    if ([Environment]::Is64BitOperatingSystem -and $Installer64) {
        $TargetFile = $Installer64
    }
    elseif ($Installer32) {
        $TargetFile = $Installer32
    }

    # --- STEP 4: RUN ---
    if ($TargetFile) {
        Write-Host "[5/5] Launching Installer..." -ForegroundColor Cyan
        
        # --- UPDATED ENGLISH MESSAGE ---
        Write-Host "      NOTE: A window will open. Click 'Install' to proceed." -ForegroundColor Magenta
        
        Start-Process -FilePath $TargetFile.FullName -WorkingDirectory $TargetFile.Directory.FullName -Wait
        
        Write-Host "      Process Finished." -ForegroundColor Green
    }
    else {
        Write-Host "Error: 'Office Installer.exe' not found in zip!" -ForegroundColor Red
    }

    # --- CLEANUP ---
    if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
}

function Install-MSOffice {
    Install-OfficeOnline
    Read-Host "Press Enter to return to the menu..."
}

# -------------------------------------------------------------------------
# Update all software
# -------------------------------------------------------------------------
function Update-AllSoftware {
    Ensure-PackageManagers
    Write-Host "`n [ SYSTEM UPDATE ]" -ForegroundColor Yellow
    Write-Host " Checking for software updates via winget..." -ForegroundColor Gray
    try {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Start-Process -FilePath "winget" -ArgumentList "upgrade --all --silent --accept-source-agreements --accept-package-agreements" -Wait -NoNewWindow -ErrorAction Stop
            Write-Host "✅ All installed software updated successfully (winget)." -ForegroundColor Green
        }
        else {
            Write-Host "❌ winget not available. Cannot perform updates." -ForegroundColor Red
        }
    }
    catch {
        Write-Host "❌ Failed to update some software: $($_.Exception.Message)" -ForegroundColor Red
    }
    Read-Host "Press Enter to return to the menu..."
}

# -------------------------------------------------------------------------
# Activation (remote)
# -------------------------------------------------------------------------
function Invoke-Activation {
    Write-Host "`n [ SYSTEM ACTIVATION ]" -ForegroundColor Yellow
    Write-Host " Running System Activation Toolkit (remote)... " -ForegroundColor Gray
    Write-Host "⚠️ This will execute a remote script. Ensure you trust the source before proceeding." -ForegroundColor Magenta

    try {
        # NOTE: Remote execution is potentially dangerous. Keep it as-is per original but wrapped.
        irm https://get.activated.win | iex
    }
    catch {
        Write-Host "❌ Activation script failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    Read-Host "Press Enter to return to the menu..."
}

# -------------------------------------------------------------------------
# Advanced Toolkit (remote)
# -------------------------------------------------------------------------
function Invoke-AdvancedToolkit {
    Write-Host "`n [ ADVANCED TOOLKIT ]" -ForegroundColor Yellow
    Write-Host " Running Advanced Toolkit (remote script)..." -ForegroundColor Gray
    Write-Host "⚠️ This will execute a remote script (irm https://christitus.com/win | iex)." -ForegroundColor Magenta

    try {
        irm https://christitus.com/win | iex
        Write-Host "✅ Advanced Toolkit execution finished." -ForegroundColor Green
    }
    catch {
        Write-Host "❌ Advanced Toolkit failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    Read-Host "Press Enter to return to the menu..."
}

# -------------------------------------------------------------------------
# Global RAM Optimizer (Embedded)
# -------------------------------------------------------------------------
function Launch-GlobalOptimizer {
    Write-Host "`n [ RAM OPTIMIZATION ]" -ForegroundColor Yellow
    Write-Host " Extracting Global Ram Optimization Suite..." -ForegroundColor Gray
    
    # Base64 Encoded Content of 'Global Ram Optimization.ps1'
    $b64 = "PCMNCi5TWU5PUFNJUw0KICAgIEdsb2JhbCAiU21hcnQiIFJBTSBPcHRpbWl6YXRpb24gTWFuYWdlbWVudCBTY3JpcHQuDQogICAgDQouREVTQ1JJUFRJT04NCiAgICBQcm92aWRlcyBhIG1lbnUgdG86DQogICAgMS4gUnVuIFNtYXJ0IEdsb2JhbCBPcHRpbWl6YXRpb24gKFRlc3QgTW9kZSAtIFZpc2libGUpLg0KICAgIDIuIEluc3RhbGwgUGVybWFuZW50IFNtYXJ0IE9wdGltaXphdGlvbiAoQmFja2dyb3VuZCBNb2RlIC0gU2lsZW50KS4NCiAgICAzLiBSZW1vdmUgR2xvYmFsIE9wdGltaXphdGlvbi4NCiAgICANCiAgICBGZWF0dXJlczoNCiAgICAtIFNjYW5zIGZvciBBTlkgcHJvY2VzcyB1c2luZyA+IDEwMCBNQiBSQU0uDQogICAgLSBTYWZlbHkgZXhjdWRlcyBjcml0aWNhbCBXaW5kb3dzIFN5c3RlbSBwcm9jZXNzZXMuDQogICAgLSBUcmltcyBtZW1vcnkgdXNpbmcgRW1wdHlXb3JraW5nU2V0IEFQSS4NCiAgICANCi5OT1RFUw0KICAgIEZpbGUgTmFtZTogR2xvYmFsIFJhbSBPcHRpbWl6YXRpb24ucHMxDQogICAgTXVzdCBiZSBydW4gYXMgQWRtaW5pc3RyYXRvci4NCiM+DQoNCiMgLS0tIEFkbWluIENoZWNrIC0tLQ0KJGN1cnJlbnRQcmluY2lwYWwgPSBOZXctT2JqZWN0IFNlY3VyaXR5LlByaW5jaXBhbC5XaW5kb3dzUHJpbmNpcGFsKFtTZWN1cml0eS5QcmluY2lwYWwuV2luZG93c0lkZW50aXR5XTo6R2V0Q3VycmVudCgpKQ0KaWYgKC1ub3QgJGN1cnJlbnRQcmluY2lwYWwuSXNJblJvbGUoW1NlY3VyaXR5LlByaW5jaXBhbC5XaW5kb3dzQnVpbHRJblJvbGVdOjpBZG1pbmlzdHJhdG9yKSkgew0KICAgICMgQWRkZWQgLU5vRXhpdCBzbyB0aGUgd2luZG93IHN0YXlzIG9wZW4gb24gV2luMTEgZXZlbiBpZiB0aGVyZSBpcyBhbiBlcnJvcg0KICAgIFN0YXJ0LVByb2Nlc3MgcG93ZXJzaGVsbC5leGUgLUFyZ3VtZW50TGlzdCAiLU5vUHJvZmlsZSAtTm9FeGl0IC1FeGVjdXRpb25Qb2xpY3kgQnlwYXNzIC1GaWxlIGAiJFBTQ29tbWFuZFBhdGhgIiIgLVZlcmIgUnVuQXMNCiAgICBFeGl0DQp9DQoNCiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09DQojICAgICAgRU1CRURERUQgU0NSSVBUUyAoU09VUkNFIENPREUpDQojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQ0KDQojIDEuIFNNQVJUIEdMT0JBTCBPUFRJTUlaRVIgKFRFU1QgTU9ERSAtIFZJU0lCTEUpDQokU2NyaXB0X1Rlc3RfR2xvYmFsID0gQCcNCiMgLS0tIEF1dG8tR2VuZXJhdGVkIFNtYXJ0IEdsb2JhbCBSQU0gT3B0aW1pemVyIC0tLQ0KaWYgKC1ub3QgKCJNZW1vcnlUcmltbWVyIiAtYXMgW3R5cGVdKSkgew0KICAgICRjb2RlID0gQCINCnVzaW5nIFN5c3RlbTsNCnVzaW5nIFN5c3RlbS5SdW50aW1lLkludGVyb3BTZXJ2aWNlczsNCnVzaW5nIFN5c3RlbS5EaWFnbm9zdGljczsNCnB1YmxpYyBjbGFzcyBNZW1vcnlUcmltbWVyIHsNCiAgICBbRGxsSW1wb3J0KCJwc2FwaS5kbGwiKV0NCiAgICBwdWJsaWMgc3RhdGljIGV4dGVybiBib29sIEVtcHR5V29ya2luZ1NldChJbnRQdHIgaFByb2Nlc3MpOw0KICAgIHB1YmxpYyBzdGF0aWMgdm9pZCBUcmltUHJvY2VzcyhpbnQgcGlkKSB7DQogICAgICAgIHRyeSB7DQogICAgICAgICAgICBQcm9jZXNzIHAgPSBQcm9jZXNzLkdldFByb2Nlc3NCeUlkKHBpZCk7DQogICAgICAgICAgICBFbXB0eVdvcmtpbmdTZXQocC5IYW5kbGUpOw0KICAgICAgICB9IGNhdGNoIHsgfQ0KICAgIH0NCn0NCiJADQogICAgQWRkLVR5cGUgLVR5cGVEZWZpbml0aW9uICRjb2RlDQp9DQoNCiRFeGNsdXNpb25zID0gQCgNCiAgICAiSWRsZSIsICJTeXN0ZW0iLCAiUmVnaXN0cnkiLCAic21zcyIsICJjc3JzcyIsICJ3aW5pbml0IiwgInNlcnZpY2VzIiwgImxzYXNzIiwgDQogICAgIndpbmxvZ29uIiwgImZvbnRkcnZob3N0IiwgImR3bSIsICJNZW1vcnkgQ29tcHJlc3Npb24iLCAiTXNNcEVuZyIsICJ0YXNrbWdyIg0KKQ0KDQpXcml0ZS1Ib3N0ICI9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0iIC1Gb3JlZ3JvdW5kQ29sb3IgQ3lhbg0KV3JpdGUtSG9zdCAiICAgR0xPQkFMIFNNQVJUIFJBTSBPUFRJTUlaRVIgKFRFU1RJTkcpICAgIiAtRm9yZWdyb3VuZENvbG9yIEN5YW4NCldyaXRlLUhvc3QgIj09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PSIgLUZvcmVncm91bmRDb2xvciBDeWFuDQpXcml0ZS1Ib3N0ICJUYXJnZXQ6IFByb2Nlc3NlcyA+IDEwMCBNQiAoVGVhbXMsIEJyb3dzZXJzLCBldGMuKSIgLUZvcmVncm91bmRDb2xvciBHcmVlbg0KV3JpdGUtSG9zdCAiQWN0aW9uOiBUcmltIFdvcmtpbmcgU2V0IiAtRm9yZWdyb3VuZENvbG9yIEdyZWVuDQpXcml0ZS1Ib3N0ICJFeGNsdWRpbmc6IFdpbmRvd3MgU3lzdGVtIFByb2Nlc3NlcyIgLUZvcmVncm91bmRDb2xvciBHcmF5DQpXcml0ZS1Ib3N0ICJQcmVzcyBDdHJsK0MgdG8gc3RvcC4iIC1Gb3JlZ3JvdW5kQ29sb3IgWWVsbG93DQpXcml0ZS1Ib3N0ICItLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0iIC1Gb3JlZ3JvdW5kQ29sb3IgR3JheQ0KDQp0cnkgew0KICAgIHdoaWxlICgkdHJ1ZSkgew0KICAgICAgICAkdGltZXN0YW1wID0gR2V0LURhdGUgLUZvcm1hdCAiSEg6bW06c3MiDQogICAgICAgICR0b3RhbEZyZWVkQ3ljbGUgPSAwDQogICAgICAgICR0cmltbWVkQXBwcyA9IEAoKQ0KDQogICAgICAgICMgRmluZCBIaWdoIE1lbW9yeSBQcm9jZXNzZXMNCiAgICAgICAgJHRhcmdldHMgPSBHZXQtUHJvY2VzcyAtRXJyb3JBY3Rpb24gU2lsZW50bHlDb250aW51ZSB8IFdoZXJlLU9iamVjdCB7IA0KICAgICAgICAgICAgJF8uV29ya2luZ1NldCAtZ3QgMTAwTUIgLWFuZCANCiAgICAgICAgICAgICRfLlByb2Nlc3NOYW1lIC1ub3RpbiAkRXhjbHVzaW9ucyANCiAgICAgICAgfQ0KDQogICAgICAgIGlmICgkdGFyZ2V0cykgew0KICAgICAgICAgICAgZm9yZWFjaCAoJHByb2MgaW4gJHRhcmdldHMpIHsNCiAgICAgICAgICAgICAgICAkYmVmb3JlID0gJHByb2MuV29ya2luZ1NldA0KICAgICAgICAgICAgICAgIA0KICAgICAgICAgICAgICAgICMgVFJJTQ0KICAgICAgICAgICAgICAgIFtNZW1vcnlUcmltbWVyXTo6VHJpbVByb2Nlc3MoJHByb2MuSWQpDQogICAgICAgICAgICAgICAgDQogICAgICAgICAgICAgICAgIyBNZWFzdXJlIFNhdmluZ3MNCiAgICAgICAgICAgICAgICB0cnkgeyAkcHJvYy5SZWZyZXNoKCk7ICRhZnRlciA9ICRwcm9jLldvcmtpbmdTZXQgfSBjYXRjaCB7ICRhZnRlciA9ICRiZWZvcmUgfQ0KICAgICAgICAgICAgICAgIA0KICAgICAgICAgICAgICAgICRzYXZlZCA9ICgkYmVmb3JlIC0gJGFmdGVyKSAvIDFNQg0KICAgICAgICAgICAgICAgIGlmICgkc2F2ZWQgLWd0IDEwKSB7DQogICAgICAgICAgICAgICAgICAgICR0b3RhbEZyZWVkQ3ljbGUgKz0gJHNhdmVkDQogICAgICAgICAgICAgICAgICAgICR0cmltbWVkQXBwcyArPSAiJCgkcHJvYy5Qcm9jZXNzTmFtZSkgKC0kKFttYXRoXTo6Um91bmQoJHNhdmVkLDApKU1CKSINCiAgICAgICAgICAgICAgICB9DQogICAgICAgICAgICB9DQogICAgICAgIH0NCg0KICAgICAgICBpZiAoJHRvdGFsRnJlZWRDeWNsZSAtZ3QgMCkgew0KICAgICAgICAgICAgV3JpdGUtSG9zdCAiWyR0aW1lc3RhbXBdIEZyZWVkICQoW21hdGhdOjpSb3VuZCgkdG90YWxGcmVlZEN5Y2xlLCAwKSkgTUIiIC1Gb3JlZ3JvdW5kQ29sb3IgR3JlZW4gLU5vTmV3bGluZQ0KICAgICAgICAgICAgaWYgKCR0cmltbWVkQXBwcy5Db3VudCAtZ3QgMCkgew0KICAgICAgICAgICAgICAgICBXcml0ZS1Ib3N0ICIgfCAkKCR0cmltbWVkQXBwcyAtam9pbiAnLCAnKSIgLUZvcmVncm91bmRDb2xvciBEYXJrR3JheQ0KICAgICAgICAgICAgfSBlbHNlIHsgV3JpdGUtSG9zdCAiIiB9DQogICAgICAgIH0NCiAgICAgICAgZWxzZSB7DQogICAgICAgICAgICAgIyBIZWFydGJlYXQgdG8gc2hvdyBpdCdzIG5vdCBzdHVjaw0KICAgICAgICAgICAgIFdyaXRlLUhvc3QgIi4iIC1Ob05ld2xpbmUgLUZvcmVncm91bmRDb2xvciBEYXJrR3JheQ0KICAgICAgICB9DQogICAgICAgIA0KICAgICAgICBTdGFydC1TbGVlcCAtU2Vjb25kcyAzDQogICAgfQ0KfQ0KY2F0Y2ggeyANCiAgICBXcml0ZS1Ib3N0ICJgbkVycm9yIGluIExvb3A6ICRfIiAtRm9yZWdyb3VuZENvbG9yIFJlZA0KICAgIFN0YXJ0LVNsZWVwIC1TZWNvbmRzIDUNCn0NCldyaXRlLUhvc3QgImBuUHJlc3MgRW50ZXIgdG8gZXhpdC4uLiIgLUZvcmVncm91bmRDb2xvciBZZWxsb3cNClJlYWQtSG9zdA0KJ0ANCg0KIyAyLiBTTUFSVCBHTE9CQUwgT1BUSU1JWkVSIChQRVJNQU5FTlQgLSBTSUxFTlQpDQokU2NyaXB0X1Blcm1fR2xvYmFsID0gQCcNCiMgR2xvYmFsIFNtYXJ0IE9wdGltaXplciAoU2lsZW50KQ0KaWYgKC1ub3QgKCJNZW1vcnlUcmltbWVyIiAtYXMgW3R5cGVdKSkgew0KICAgICRjb2RlID0gQCINCnVzaW5nIFN5c3RlbTsNCnVzaW5nIFN5c3RlbS5SdW50aW1lLkludGVyb3BTZXJ2aWNlczsNCnVzaW5nIFN5c3RlbS5EaWFnbm9zdGljczsNCnB1YmxpYyBjbGFzcyBNZW1vcnlUcmltbWVyIHsNCiAgICBbRGxsSW1wb3J0KCJwc2FwaS5kbGwiKV0NCiAgICBwdWJsaWMgc3RhdGljIGV4dGVybiBib29sIEVtcHR5V29ya2luZ1NldChJbnRQdHIgaFByb2Nlc3MpOw0KICAgIHB1YmxpYyBzdGF0aWMgdm9pZCBUcmltUHJvY2VzcyhpbnQgcGlkKSB7DQogICAgICAgIHRyeSB7DQogICAgICAgICAgICBQcm9jZXNzIHAgPSBQcm9jZXNzLkdldFByb2Nlc3NCeUlkKHBpZCk7DQogICAgICAgICAgICBFbXB0eVdvcmtpbmdTZXQocC5IYW5kbGUpOw0KICAgICAgICB9IGNhdGNoIHsgfQ0KICAgIH0NCn0NCiJADQogICAgQWRkLVR5cGUgLVR5cGVEZWZpbml0aW9uICRjb2RlDQp9DQoNCiMgU2VsZi1IaWRpbmcNCiR3Q29kZSA9IEAiDQp1c2luZyBTeXN0ZW07IHVzaW5nIFN5c3RlbS5SdW50aW1lLkludGVyb3BTZXJ2aWNlczsNCnB1YmxpYyBjbGFzcyBXaW5kb3dNYW5hZ2VyIHsNCiAgICBbRGxsSW1wb3J0KCJrZXJuZWwzMi5kbGwiKV0gcHVibGljIHN0YXRpYyBleHRlcm4gSW50UHRyIEdldENvbnNvbGVXaW5kb3coKTsNCiAgICBbRGxsSW1wb3J0KCJ1c2VyMzIuZGxsIildIHB1YmxpYyBzdGF0aWMgZXh0ZXJuIGJvb2wgU2hvd1dpbmRvdyhJbnRQdHIgaFduZCwgaW50IG5DbWRTaG93KTsNCn0NCiJADQppZiAoLW5vdCAoIldpbmRvd01hbmFnZXIiIC1hcyBbdHlwZV0pKSB7IEFkZC1UeXBlIC1UeXBlRGVmaW5pdGlvbiAkd0NvZGUgfQ0KW1dpbmRvd01hbmFnZXJdOjpTaG93V2luZG93KFtXaW5kb3dNYW5hZ2VyXTo6R2V0Q29uc29sZVdpbmRvdygpLCAwKQ0KDQokRXhjbHVzaW9ucyA9IEAoDQogICAgIklkbGUiLCAiU3lzdGVtIiwgIlJlZ2lzdHJ5IiwgInNtc3MiLCAiY3Nyc3MiLCAid2luaW5pdCIsICJzZXJ2aWNlcyIsIA0KICAgICJsc2FzcyIsICJ3aW5sb2dvbiIsICJmb250ZHJ2aG9zdCIsICJkd20iLCAiTWVtb3J5IENvbXByZXNzaW9uIiwgIk1zTXBFbmciDQopDQoNCndoaWxlICgkdHJ1ZSkgew0KICAgIHRyeSB7DQogICAgICAgICMgRmluZCBIaWdoIE1lbW9yeSBQcm9jZXNzZXMgKD4xMDBNQikNCiAgICAgICAgJHRhcmdldHMgPSBHZXQtUHJvY2VzcyAtRXJyb3JBY3Rpb24gU2lsZW50bHlDb250aW51ZSB8IFdoZXJlLU9iamVjdCB7IA0KICAgICAgICAgICAgJF8uV29ya2luZ1NldCAtZ3QgMTAwTUIgLWFuZCANCiAgICAgICAgICAgICRfLlByb2Nlc3NOYW1lIC1ub3RpbiAkRXhjbHVzaW9ucyANCiAgICAgICAgfQ0KICAgICAgICANCiAgICAgICAgaWYgKCR0YXJnZXRzKSB7DQogICAgICAgICAgICBmb3JlYWNoICgkcHJvYyBpbiAkdGFyZ2V0cykgew0KICAgICAgICAgICAgICAgIFtNZW1vcnlUcmltbWVyXTo6VHJpbVByb2Nlc3MoJHByb2MuSWQpDQogICAgICAgICAgICB9DQogICAgICAgIH0NCiAgICB9DQogICAgY2F0Y2ggeyB9DQogICAgDQogICAgU3RhcnQtU2xlZXAgLVNlY29uZHMgNQ0KfQ0KJ0ANCg0KIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0NCiMgICAgICAgICAgICAgTUFJTiBMT0dJQw0KIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0NCg0KZnVuY3Rpb24gU2hvdy1NZW51IHsNCiAgICBDbGVhci1Ib3N0DQogICAgV3JpdGUtSG9zdCAiPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09IiAtRm9yZWdyb3VuZENvbG9yIEN5YW4NCiAgICBXcml0ZS1Ib3N0ICIgICBHTE9CQUwgUkFNIE9QVElNSVpFUiAoU01BUlQgTU9ERSkiIC1Gb3JlZ3JvdW5kQ29sb3IgQ3lhbg0KICAgIFdyaXRlLUhvc3QgIj09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PSIgLUZvcmVncm91bmRDb2xvciBDeWFuDQogICAgV3JpdGUtSG9zdCAiMS4gVGVzdCBHbG9iYWwgT3B0aW1pemF0aW9uIChWaXNpYmxlKSIgLUZvcmVncm91bmRDb2xvciBZZWxsb3cNCiAgICBXcml0ZS1Ib3N0ICIyLiBJbnN0YWxsIEdsb2JhbCBQZXJtYW5lbnQgKFNpbGVudCkiIC1Gb3JlZ3JvdW5kQ29sb3IgR3JlZW4NCiAgICBXcml0ZS1Ib3N0ICIzLiBSZW1vdmUgR2xvYmFsIE9wdGltaXphdGlvbiIgLUZvcmVncm91bmRDb2xvciBSZWQNCiAgICBXcml0ZS1Ib3N0ICJRLiBRdWl0IiAtRm9yZWdyb3VuZENvbG9yIEdyYXkNCiAgICBXcml0ZS1Ib3N0ICI9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0iIC1Gb3JlZ3JvdW5kQ29sb3IgQ3lhbg0KfQ0KDQp3aGlsZSAoJHRydWUpIHsNCiAgICBTaG93LU1lbnUNCiAgICAkY2hvaWNlID0gUmVhZC1Ib3N0ICJTZWxlY3QgYW4gb3B0aW9uIg0KICAgIA0KICAgIHN3aXRjaCAoJGNob2ljZSkgew0KICAgICAgICAiMSIgew0KICAgICAgICAgICAgIyAtLS0gMS4gVEVTVCBNT0RFIC0tLQ0KICAgICAgICAgICAgV3JpdGUtSG9zdCAiYG5MYXVuY2hpbmcgR2xvYmFsIFRlc3QgU2NyaXB0Li4uIiAtRm9yZWdyb3VuZENvbG9yIFllbGxvdw0KICAgICAgICAgICAgJHRlbXBTY3JpcHQgPSBKb2luLVBhdGggJGVudjpURU1QICJHbG9iYWwtT3B0aW1pemUtVGVzdC5wczEiDQogICAgICAgICAgICAkU2NyaXB0X1Rlc3RfR2xvYmFsIHwgT3V0LUZpbGUgLUZpbGVQYXRoICR0ZW1wU2NyaXB0IC1FbmNvZGluZyBVVEY4IC1Gb3JjZQ0KICAgICAgICAgICAgU3RhcnQtUHJvY2VzcyBwb3dlcnNoZWxsLmV4ZSAtQXJndW1lbnRMaXN0ICItTm9FeGl0IC1FeGVjdXRpb25Qb2xpY3kgQnlwYXNzIC1GaWxlIGAiJHRlbXBTY3JpcHRgIiINCiAgICAgICAgICAgIFdyaXRlLUhvc3QgIkdsb2JhbCBPcHRpbWl6ZXIgcnVubmluZyBpbiBuZXcgd2luZG93LiIgLUZvcmVncm91bmRDb2xvciBHcmVlbg0KICAgICAgICAgICAgUGF1c2UNCiAgICAgICAgfQ0KICAgICAgICANCiAgICAgICAgIjIiIHsNCiAgICAgICAgICAgICMgLS0tIDIuIFBFUk1BTkVOVCBJTlNUQUxMQVRJT04gLS0tDQogICAgICAgICAgICBXcml0ZS1Ib3N0ICJgbkdlbmVyYXRpbmcgR2xvYmFsIE9wdGltaXphdGlvbiBTY3JpcHRzLi4uIiAtRm9yZWdyb3VuZENvbG9yIEN5YW4NCiAgICAgICAgICAgIA0KICAgICAgICAgICAgJEluc3RhbGxEaXIgPSAiQzpcR2xvYmFsUmFtT3B0aW1pemF0aW9uIg0KICAgICAgICAgICAgaWYgKC1ub3QgKFRlc3QtUGF0aCAkSW5zdGFsbERpcikpIHsgTmV3LUl0ZW0gLVBhdGggJEluc3RhbGxEaXIgLUl0ZW1UeXBlIERpcmVjdG9yeSAtRm9yY2UgfCBPdXQtTnVsbCB9DQogICAgICAgICAgICANCiAgICAgICAgICAgICRHbG9iYWxTY3JpcHQgPSAiJEluc3RhbGxEaXJcR2xvYmFsLU9wdGltaXplci5wczEiDQogICAgICAgICAgICAkU2NyaXB0X1Blcm1fR2xvYmFsIHwgT3V0LUZpbGUgLUZpbGVQYXRoICRHbG9iYWxTY3JpcHQgLUVuY29kaW5nIFVURjggLUZvcmNlDQogICAgICAgICAgICANCiAgICAgICAgICAgIFdyaXRlLUhvc3QgIkZpbGUgZ2VuZXJhdGVkIGluICRJbnN0YWxsRGlyIiAtRm9yZWdyb3VuZENvbG9yIEdyZWVuDQogICAgICAgICAgICANCiAgICAgICAgICAgICMgUmVnaXN0ZXIgVGFzaw0KICAgICAgICAgICAgV3JpdGUtSG9zdCAiUmVnaXN0ZXJpbmcgU2NoZWR1bGVkIFRhc2suLi4iIC1Gb3JlZ3JvdW5kQ29sb3IgQ3lhbg0KICAgICAgICAgICAgJFRhc2tOYW1lID0gIkdsb2JhbFJhbU9wdGltaXplciINCiAgICAgICAgICAgIA0KICAgICAgICAgICAgVW5yZWdpc3Rlci1TY2hlZHVsZWRUYXNrIC1UYXNrTmFtZSAkVGFza05hbWUgLUNvbmZpcm06JGZhbHNlIC1FcnJvckFjdGlvbiBTaWxlbnRseUNvbnRpbnVlDQogICAgICAgICAgICAgICAgDQogICAgICAgICAgICAkQWN0aW9uID0gTmV3LVNjaGVkdWxlZFRhc2tBY3Rpb24gLUV4ZWN1dGUgInBvd2Vyc2hlbGwuZXhlIiAtQXJndW1lbnQgIi1XaW5kb3dTdHlsZSBIaWRkZW4gLUV4ZWN1dGlvblBvbGljeSBCeXBhc3MgLUZpbGUgYCIkR2xvYmFsU2NyaXB0YCIiDQogICAgICAgICAgICAkVHJpZ2dlciA9IE5ldy1TY2hlZHVsZWRUYXNrVHJpZ2dlciAtQXRMb2dPbg0KICAgICAgICAgICAgDQogICAgICAgICAgICAjIEZpeCBmb3IgIlBhcmFtZXRlciBpcyBpbmNvcnJlY3QiOiBVc2UgZnVsbHkgcXVhbGlmaWVkIHVzZXIgbmFtZSAoRE9NQUlOXFVzZXIpDQogICAgICAgICAgICAkVXNlciA9IFtTeXN0ZW0uU2VjdXJpdHkuUHJpbmNpcGFsLldpbmRvd3NJZGVudGl0eV06OkdldEN1cnJlbnQoKS5OYW1lDQogICAgICAgICAgICAkUHJpbmNpcGFsID0gTmV3LVNjaGVkdWxlZFRhc2tQcmluY2lwYWwgLVVzZXJJZCAkVXNlciAtTG9nb25UeXBlIEludGVyYWN0aXZlIC1SdW5MZXZlbCBIaWdoZXN0DQogICAgICAgICAgICANCiAgICAgICAgICAgICRTZXR0aW5ncyA9IE5ldy1TY2hlZHVsZWRUYXNrU2V0dGluZ3NTZXQgLUFsbG93U3RhcnRJZk9uQmF0dGVyaWVzIC1Eb250U3RvcElmR29pbmdPbkJhdHRlcmllcyAtRXhlY3V0aW9uVGltZUxpbWl0IChbVGltZVNwYW5dOjpaZXJvKQ0KICAgICAgICAgICAgICAgIA0KICAgICAgICAgICAgdHJ5IHsNCiAgICAgICAgICAgICAgICBSZWdpc3Rlci1TY2hlZHVsZWRUYXNrIC1UYXNrTmFtZSAkVGFza05hbWUgLUFjdGlvbiAkQWN0aW9uIC1UcmlnZ2VyICRUcmlnZ2VyIC1QcmluY2lwYWwgJFByaW5jaXBhbCAtU2V0dGluZ3MgJFNldHRpbmdzIC1Gb3JjZSB8IE91dC1OdWxsDQogICAgICAgICAgICAgICAgDQogICAgICAgICAgICAgICAgIyBTVEFSVCBJTU1FRElBVEVMWQ0KICAgICAgICAgICAgICAgIFN0YXJ0LVNjaGVkdWxlZFRhc2sgLVRhc2tOYW1lICRUYXNrTmFtZQ0KICAgICAgICAgICAgICAgIFdyaXRlLUhvc3QgIlNVQ0NFU1M6IEdsb2JhbCBTbWFydCBPcHRpbWl6YXRpb24gSW5zdGFsbGVkICYgU3RhcnRlZCEiIC1Gb3JlZ3JvdW5kQ29sb3IgR3JlZW4NCiAgICAgICAgICAgIH0NCiAgICAgICAgICAgIGNhdGNoIHsNCiAgICAgICAgICAgICAgICBXcml0ZS1Ib3N0ICJFcnJvciByZWdpc3RlcmluZyB0YXNrOiAkXyIgLUZvcmVncm91bmRDb2xvciBSZWQNCiAgICAgICAgICAgIH0NCiAgICAgICAgICAgIFBhdXNlDQogICAgICAgIH0NCiAgICAgICAgDQogICAgICAgICIzIiB7DQogICAgICAgICAgICAjIC0tLSAzLiBSRU1PVkUgQUxMIC0tLQ0KICAgICAgICAgICAgV3JpdGUtSG9zdCAiYG5SZW1vdmluZyBHbG9iYWwgT3B0aW1pemF0aW9uLi4uIiAtRm9yZWdyb3VuZENvbG9yIFJlZA0KICAgICAgICAgICAgDQogICAgICAgICAgICAjIFN0b3AgUHJvY2Vzc2VzIChHbG9iYWwgKyBMZWdhY3kgU2NyaXB0cykNCiAgICAgICAgICAgIEdldC1XbWlPYmplY3QgV2luMzJfUHJvY2VzcyB8IFdoZXJlLU9iamVjdCB7ICRfLkNvbW1hbmRMaW5lIC1tYXRjaCAiR2xvYmFsLU9wdGltaXplcnxHbG9iYWwtT3B0aW1pemUtVGVzdHxPcHRpbWl6ZS1BbGx8T3B0aW1pemUtQ2hyb21lfE9wdGltaXplLVZTQ29kZXxPcHRpbWl6ZS1WaXN1YWxTdHVkaW8iIH0gfCBGb3JFYWNoLU9iamVjdCB7IA0KICAgICAgICAgICAgICAgIFN0b3AtUHJvY2VzcyAtSWQgJF8uUHJvY2Vzc0lkIC1Gb3JjZSAtRXJyb3JBY3Rpb24gU2lsZW50bHlDb250aW51ZSANCiAgICAgICAgICAgIH0NCiAgICAgICAgICAgIFdyaXRlLUhvc3QgIlN0b3BwZWQgcnVubmluZyBzY3JpcHRzIChHbG9iYWwgJiBMZWdhY3kpLiIgLUZvcmVncm91bmRDb2xvciBHcmF5DQogICAgICAgICAgICANCiAgICAgICAgICAgICMgVW5yZWdpc3RlciBUYXNrcw0KICAgICAgICAgICAgVW5yZWdpc3Rlci1TY2hlZHVsZWRUYXNrIC1UYXNrTmFtZSAiR2xvYmFsUmFtT3B0aW1pemVyIiAtQ29uZmlybTokZmFsc2UgLUVycm9yQWN0aW9uIFNpbGVudGx5Q29udGludWUNCiAgICAgICAgICAgIFdyaXRlLUhvc3QgIlVucmVnaXN0ZXJlZCB0YXNrcy4iIC1Gb3JlZ3JvdW5kQ29sb3IgR3JheQ0KDQogICAgICAgICAgICAjIERlbGV0ZSBGaWxlcw0KICAgICAgICAgICAgaWYgKFRlc3QtUGF0aCAiQzpcR2xvYmFsUmFtT3B0aW1pemF0aW9uIikgew0KICAgICAgICAgICAgICAgIFJlbW92ZS1JdGVtICJDOlxHbG9iYWxSYW1PcHRpbWl6YXRpb24iIC1SZWN1cnNlIC1Gb3JjZSAtRXJyb3JBY3Rpb24gU2lsZW50bHlDb250aW51ZQ0KICAgICAgICAgICAgICAgIFdyaXRlLUhvc3QgIkRlbGV0ZWQgQzpcR2xvYmFsUmFtT3B0aW1pemF0aW9uIiAtRm9yZWdyb3VuZENvbG9yIEdyZWVuDQogICAgICAgICAgICB9DQogICAgICAgICAgICANCiAgICAgICAgICAgIFdyaXRlLUhvc3QgIkNsZWFudXAgQ29tcGxldGUuIiAtRm9yZWdyb3VuZENvbG9yIEdyZWVuDQogICAgICAgICAgICBQYXVzZQ0KICAgICAgICB9DQogICAgICAgIA0KICAgICAgICAiUSIgeyBFeGl0IH0NCiAgICAgICAgInEiIHsgRXhpdCB9DQogICAgfQ0KfQ0K"
    
    # Check if script exists or matches (optional cache check could go here)
    $tempScript = Join-Path $env:TEMP "Global-Ram-Optimizer-Embedded.ps1"
    
    # Decode and Write
    try {
        $bytes = [System.Convert]::FromBase64String($b64)
        [System.IO.File]::WriteAllBytes($tempScript, $bytes)
        
        Write-Host "✅ Extracted to: $tempScript" -ForegroundColor DarkGray
        Write-Host "🚀 Launching..." -ForegroundColor Green
        
        # Run it
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tempScript`""
    }
    catch {
        Write-Host "❌ Error extracting/running script: $($_.Exception.Message)" -ForegroundColor Red
    }
    

    Read-Host "Press Enter to return to the menu..."
}

# -------------------------------------------------------------------------
# Office Software (Option 7) - RabbitMQ & ElasticSearch
# -------------------------------------------------------------------------
function Install-RabbitMQ {
    Write-Host "`n [ RABBITMQ INSTALLATION ]" -ForegroundColor Cyan
    $ErrorActionPreference = "Stop"

    # Parameters
    $NasPath = "\\174.156.4.3\fjt\Required softwares\Automation Software\Automations-Priyanshu\rabbitmq,elastic"
    $ErlangExe = "otp_win64_25.1.2.exe"
    $ErlangUrl = "https://github.com/erlang/otp/releases/download/OTP-25.1.2/otp_win64_25.1.2.exe"
    $RabbitExe = "rabbitmq-server-3.11.3.exe"
    $RabbitUrl = "https://github.com/rabbitmq/rabbitmq-server/releases/download/v3.11.3/rabbitmq-server-3.11.3.exe"
    $RabbitVersion = "3.11.3"

    # Helper
    function Download-Or-Copy-Ops {
        param($FileName, $NasSource, $WebUrl)
        $Dest = "$env:TEMP\$FileName"
        $NasFile = "$NasSource\$FileName"
        
        if (Test-Path $NasFile) {
            Write-Host "   Found $FileName on NAS. Copying..." -ForegroundColor Green
            try { Copy-Item -Path $NasFile -Destination $Dest -Force; return $Dest }
            catch { Write-Host "   Failed to copy from NAS: $($_.Exception.Message)" -ForegroundColor Yellow }
        }
        
        Write-Host "   Downloading $FileName from Web..." -ForegroundColor Yellow
        try { Invoke-WebRequest -Uri $WebUrl -OutFile $Dest; return $Dest }
        catch { throw "Failed to download $FileName." }
    }

    try {
        # Check Exists
        $RabbitSbin = "C:\Program Files\RabbitMQ Server\rabbitmq_server-$RabbitVersion\sbin"
        if (Test-Path "$RabbitSbin\rabbitmqctl.bat" -ErrorAction SilentlyContinue) {
            Write-Host "✅ RabbitMQ detected. Skipping install steps." -ForegroundColor Green
        }
        else {
            Write-Host "⏬ Getting Installers..." -ForegroundColor Yellow
            $LocalErlang = Download-Or-Copy-Ops $ErlangExe $NasPath $ErlangUrl
            $LocalRabbit = Download-Or-Copy-Ops $RabbitExe $NasPath $RabbitUrl

            Write-Host "🚀 Installing Erlang (Interactive)..." -ForegroundColor Yellow
            Write-Host "⚠️  Please verify and complete the installation in the opened window." -ForegroundColor Magenta
            Start-Process -FilePath $LocalErlang -Wait
            
            # ERLANG_HOME Fix
            $ErlangBase = "C:\Program Files"
            $ErlangDir = Get-ChildItem -Path $ErlangBase -Filter "erl*" -Directory | Sort-Object Name -Descending | Select-Object -First 1
            if ($ErlangDir) { $env:ERLANG_HOME = $ErlangDir.FullName; Write-Host "   Set ERLANG_HOME: $($ErlangDir.FullName)" -ForegroundColor Gray }
            
            Write-Host "🚀 Installing RabbitMQ (Interactive)..." -ForegroundColor Yellow
            Write-Host "⚠️  Please verify and complete the installation in the opened window." -ForegroundColor Magenta
            Start-Process -FilePath $LocalRabbit -Wait
        }

        # Path & Env
        if (Test-Path $RabbitSbin) {
            $CurrentPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
            if ($CurrentPath -notlike "*$RabbitSbin*") {
                [Environment]::SetEnvironmentVariable("Path", "$CurrentPath;$RabbitSbin", "Machine")
                $env:Path += ";$RabbitSbin"
                Write-Host "   Added RabbitMQ to PATH." -ForegroundColor Gray
            }
        }

        # Plugins
        if (Test-Path "$RabbitSbin\rabbitmq-plugins.bat") {
            Write-Host "🔌 Enabling Plugins..." -ForegroundColor Cyan
            Push-Location $RabbitSbin
            & .\rabbitmq-plugins.bat enable rabbitmq_management
            & .\rabbitmq-plugins.bat enable rabbitmq_shovel
            & .\rabbitmq-plugins.bat enable rabbitmq_shovel_management
            Pop-Location
        }

        # Firewall
        Write-Host "🛡️ Configuring Firewall..." -ForegroundColor Cyan
        $FirewallRules = @(@{Name = "RabbitMQ-AMQP"; Port = 5672 }, @{Name = "RabbitMQ-Mgmt"; Port = 15672 }, @{Name = "RabbitMQ-EPMD"; Port = 4369 }, @{Name = "RabbitMQ-Dist"; Port = 25672 })
        foreach ($Rule in $FirewallRules) {
            if (-not (Get-NetFirewallRule -DisplayName $Rule.Name -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $Rule.Name -Direction Inbound -LocalPort $Rule.Port -Protocol TCP -Action Allow | Out-Null
            }
        }

        # Admin User (Default: guest/guest)
        Write-Host "👤 Configuring Default User (guest/guest)..." -ForegroundColor Cyan
        $CtlPath = "$RabbitSbin\rabbitmqctl.bat"
        if (Test-Path $CtlPath) {
            # Method 1: Reset Password to Default
            Start-Process -FilePath $CtlPath -ArgumentList "change_password guest guest" -Wait -NoNewWindow -ErrorAction SilentlyContinue
            Start-Process -FilePath $CtlPath -ArgumentList "set_user_tags guest administrator" -Wait -NoNewWindow
            Start-Process -FilePath $CtlPath -ArgumentList "set_permissions -p / guest "".*"" "".*"" "".*""" -Wait -NoNewWindow
        }

        # Auto-Start
        Set-Service -Name "RabbitMQ" -StartupType Automatic -ErrorAction SilentlyContinue
        Write-Host "   Service Start Mode set to Automatic." -ForegroundColor Gray

        Write-Host "✅ RabbitMQ Setup Complete. Login: guest/guest" -ForegroundColor Green

    }
    catch {
        Write-Host "❌ RabbitMQ Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Get-RabbitMQStatus {
    Write-Host "`n [ RABBITMQ STATUS CHECK ]" -ForegroundColor Cyan
    
    # 1. Service Status
    $service = Get-Service -Name "RabbitMQ" -ErrorAction SilentlyContinue
    if ($service) {
        $statusColor = if ($service.Status -eq 'Running') { "Green" } else { "Red" }
        Write-Host "   Service: " -NoNewline
        Write-Host "$($service.Status)" -ForegroundColor $statusColor
    }
    else {
        Write-Host "   Service: " -NoNewline
        Write-Host "Not Installed / Not Found" -ForegroundColor Red
    }

    # 2. Port Checks
    Write-Host "`n   Checking Ports:" -ForegroundColor Gray
    $ports = @(
        @{ Port = 5672; Name = "AMQP" },
        @{ Port = 15672; Name = "Management" },
        @{ Port = 4369; Name = "Erlang Mapper" },
        @{ Port = 25672; Name = "Distribution" }
    )

    foreach ($p in $ports) {
        $msg = "   - Port $($p.Port) ($($p.Name))..."
        # Pad for alignment
        if ($msg.Length -lt 40) { $msg = $msg + " " * (40 - $msg.Length) }
        Write-Host $msg -NoNewline -ForegroundColor Gray

        $conn = Get-NetTCPConnection -LocalPort $p.Port -State Listen -ErrorAction SilentlyContinue
        if ($conn) {
            Write-Host "✅ LISTENING" -ForegroundColor Green
        }
        else {
            Write-Host "❌ CLOSED / UNUSED" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
}


function Repair-RabbitMQ {
    Write-Host "`n [ REPAIRING RABBITMQ ]" -ForegroundColor Yellow
    $ErrorActionPreference = "SilentlyContinue"

    # 1. Find sbin path
    $RabbitVersion = "3.11.3"
    $RabbitSbin = "C:\Program Files\RabbitMQ Server\rabbitmq_server-$RabbitVersion\sbin"

    if (-not (Test-Path $RabbitSbin)) {
        Write-Host "❌ RabbitMQ sbin directory not found at expected path: $RabbitSbin" -ForegroundColor Red
        Write-Host "   Repair cannot proceed if RabbitMQ is not installed in the default location." -ForegroundColor Gray
        return
    }

    # 2. Re-enable Plugins
    if (Test-Path "$RabbitSbin\rabbitmq-plugins.bat") {
        Write-Host "🔌 Re-enabling Plugins..." -ForegroundColor Cyan
        Push-Location $RabbitSbin
        & .\rabbitmq-plugins.bat enable rabbitmq_management
        & .\rabbitmq-plugins.bat enable rabbitmq_shovel
        & .\rabbitmq-plugins.bat enable rabbitmq_shovel_management
        Pop-Location
        Write-Host "   Plugins enabled command sent." -ForegroundColor Gray
    }
    else {
        Write-Host "⚠️  rabbitmq-plugins.bat not found." -ForegroundColor Yellow
    }

    # 3. Firewall Rules (Re-apply)
    Write-Host "🛡️  Refreshing Firewall Rules..." -ForegroundColor Cyan
    $FirewallRules = @(@{Name = "RabbitMQ-AMQP"; Port = 5672 }, @{Name = "RabbitMQ-Mgmt"; Port = 15672 }, @{Name = "RabbitMQ-EPMD"; Port = 4369 }, @{Name = "RabbitMQ-Dist"; Port = 25672 })
    foreach ($Rule in $FirewallRules) {
        if (-not (Get-NetFirewallRule -DisplayName $Rule.Name -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $Rule.Name -Direction Inbound -LocalPort $Rule.Port -Protocol TCP -Action Allow | Out-Null
            Write-Host "   Created rule for $($Rule.Name) ($($Rule.Port))" -ForegroundColor Gray
        }
    }

    # 4. Reset Default User (guest/guest)
    Write-Host "👤 Resetting Default User (guest/guest)..." -ForegroundColor Cyan
    $CtlPath = "$RabbitSbin\rabbitmqctl.bat"
    if (Test-Path $CtlPath) {
        # Method 2: Delete & Re-Create
        # 1. Stop App
        Start-Process -FilePath $CtlPath -ArgumentList "stop_app" -Wait -NoNewWindow -ErrorAction SilentlyContinue
        
        # 2. Delete guest
        Start-Process -FilePath $CtlPath -ArgumentList "delete_user guest" -Wait -NoNewWindow -ErrorAction SilentlyContinue
        
        # 3. Add guest
        Start-Process -FilePath $CtlPath -ArgumentList "add_user guest guest" -Wait -NoNewWindow -ErrorAction SilentlyContinue
        
        # 4. Set Tags & Perms
        Start-Process -FilePath $CtlPath -ArgumentList "set_user_tags guest administrator" -Wait -NoNewWindow
        Start-Process -FilePath $CtlPath -ArgumentList "set_permissions -p / guest "".*"" "".*"" "".*""" -Wait -NoNewWindow
        
        # 6. Start App
        Start-Process -FilePath $CtlPath -ArgumentList "start_app" -Wait -NoNewWindow -ErrorAction SilentlyContinue
        
        Write-Host "   Default credentials restored." -ForegroundColor Gray
    }

    # 5. Restart Service
    Write-Host "🔄 Restarting RabbitMQ Service..." -ForegroundColor Cyan
    $service = Get-Service -Name "RabbitMQ" -ErrorAction SilentlyContinue
    if ($service) {
        Set-Service -Name "RabbitMQ" -StartupType Automatic
        Restart-Service -Name "RabbitMQ" -Force
        Write-Host "✅ Service Restarted & Set to Automatic." -ForegroundColor Green
    }
    else {
        Write-Host "❌ RabbitMQ Service not found." -ForegroundColor Red
    }

    Write-Host "`n✅ Repair sequence finished. Please check status." -ForegroundColor Green
    Write-Host "   ℹ️  Login Details: http://localhost:15672 (guest / guest)" -ForegroundColor Gray
}

function Install-ElasticSearch {
    Write-Host "`n [ ELASTICSEARCH INSTALLATION ]" -ForegroundColor Cyan
    $ErrorActionPreference = "Stop"

    $ElasticVersion = "8.11.1"
    $ZipName = "elasticsearch-8.11.1-windows-x86_64.zip"
    $NasPath = "\\174.156.4.3\fjt\Required softwares\Automation Software\Automations-Priyanshu\rabbitmq,elastic"
    $WebUrl = "https://artifacts.elastic.co/downloads/elasticsearch/$ZipName"
    
    $InstallDirRoot = "C:\Program Files\Elastic\Elasticsearch"
    $ElasticInstallDir = "$InstallDirRoot\$ElasticVersion"
    $ProgramDataDir = "C:\ProgramData\Elastic\Elasticsearch"
    $JavaHome = "C:\Program Files\Java\jdk-17"
    $NetworkJdkPath = "\\174.156.4.3\fjt\Required softwares\Update - Dev System\jdk-17.0.6_windows-x64_bin.exe"

    try {
        # Check Exists
        if (Test-Path "$ElasticInstallDir\bin\elasticsearch-service.bat") {
            Write-Host "✅ ElasticSearch detected. Skipping install." -ForegroundColor Green
        }
        else {
            # Download
            if (-not (Test-Path $InstallDirRoot)) { New-Item -Path $InstallDirRoot -ItemType Directory -Force | Out-Null }
            $LocalZipPath = "$env:TEMP\$ZipName"
            $NasZipPath = "$NasPath\$ZipName"
            $FileReady = $false

            if (Test-Path $NasZipPath) {
                Write-Host "   Copying ZIP from NAS..." -ForegroundColor Green
                try { Copy-Item -Path $NasZipPath -Destination $LocalZipPath -Force; $FileReady = $true } catch {}
            }
            if (-not $FileReady) {
                Write-Host "   Downloading ZIP from Web..." -ForegroundColor Yellow
                Invoke-WebRequest -Uri $WebUrl -OutFile $LocalZipPath
            }

            Write-Host "📦 Extracting..." -ForegroundColor Yellow
            Expand-Archive -Path $LocalZipPath -DestinationPath $InstallDirRoot -Force
            $ExtractedFolder = "$InstallDirRoot\elasticsearch-$ElasticVersion"
            if (Test-Path $ExtractedFolder) { Rename-Item -Path $ExtractedFolder -NewName $ElasticVersion }
        }

        # JDK
        if (-not (Test-Path "$JavaHome\bin\java.exe")) {
            Write-Host "☕ Installing JDK (Interactive)..." -ForegroundColor Yellow
            $LocalJdkPath = "$env:TEMP\jdk-17-installer.exe"
            if (Test-Path $NetworkJdkPath) { Copy-Item -Path $NetworkJdkPath -Destination $LocalJdkPath -Force }
            if (Test-Path $LocalJdkPath) { Start-Process -FilePath $LocalJdkPath -Wait }
        }

        # Env Vars
        [System.Environment]::SetEnvironmentVariable("JAVA_HOME", $null, "User")
        [System.Environment]::SetEnvironmentVariable("ES_JAVA_HOME", $JavaHome, "Machine")
        [System.Environment]::SetEnvironmentVariable("ES_HOME", $ElasticInstallDir, "Machine")
        [System.Environment]::SetEnvironmentVariable("ES_PATH_CONF", "$ProgramDataDir\config", "Machine")
        [System.Environment]::SetEnvironmentVariable("ELASTIC_CLIENT_APIVERSIONING", "true", "Machine")

        # Config
        Write-Host "⚙️  Configuring..." -ForegroundColor Cyan
        New-Item -Path "$ProgramDataDir\config" -ItemType Directory -Force | Out-Null
        New-Item -Path "$ProgramDataDir\data" -ItemType Directory -Force | Out-Null
        New-Item -Path "$ProgramDataDir\logs" -ItemType Directory -Force | Out-Null

        $SourceConfig = "$ElasticInstallDir\config"
        if (Test-Path "$SourceConfig\elasticsearch.yml") { Copy-Item -Path "$SourceConfig\*" -Destination "$ProgramDataDir\config" -Recurse -Force }

        $ConfigContent = @"
bootstrap.memory_lock: false
cluster.name : elasticsearch
http.port: 9200
node.attr.data: true
node.name : $env:COMPUTERNAME
path.data: C:\ProgramData\Elastic\Elasticsearch\data
path.logs: C:\ProgramData\Elastic\Elasticsearch\logs
path.repo: C:\ProgramData\Elastic\Elasticsearch\backup
transport.port: 9300
xpack.license.self_generated.type: basic
xpack.security.enabled: true
action.auto_create_index: .monitoring*,.watches,.triggered_watches,.watcher-history*,.ml*
"@
        Set-Content -Path "$ProgramDataDir\config\elasticsearch.yml" -Value $ConfigContent
        if (Test-Path "$ProgramDataDir\config\jvm.options") { Copy-Item -Path "$ProgramDataDir\config\jvm.options" -Destination "$ProgramDataDir\config\jvm.options.d" -Force }

        # Firewall
        $FwRules = @(@{Name = "ElasticSearch-HTTP"; Port = 9200 }, @{Name = "ElasticSearch-Trans"; Port = 9300 })
        foreach ($Rule in $FwRules) {
            if (-not (Get-NetFirewallRule -DisplayName $Rule.Name -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $Rule.Name -Direction Inbound -LocalPort $Rule.Port -Protocol TCP -Action Allow | Out-Null
            }
        }

        # Service
        $ServiceBat = "$ElasticInstallDir\bin\elasticsearch-service.bat"
        $EsService = Get-Service "elasticsearch" -ErrorAction SilentlyContinue
        if (-not $EsService) {
            if (Test-Path $ServiceBat) { 
                Start-Process -FilePath $ServiceBat -ArgumentList "install elasticsearch" -Wait
                Set-Service -Name "elasticsearch" -StartupType Automatic
                Start-Service "elasticsearch" 
            }
        }
        else { 
            Set-Service -Name "elasticsearch" -StartupType Automatic
            if ($EsService.Status -ne "Running") { Start-Service "elasticsearch" } 
        }
        
        Write-Host "👤 Setting Up Admin (Triveni@123)..." -ForegroundColor Cyan
        Start-Sleep -Seconds 15
        
        $UsersTool = "$ElasticInstallDir\bin\elasticsearch-users.bat"
        if (Test-Path $UsersTool) {
            $P = Start-Process -FilePath $UsersTool -ArgumentList "useradd admin -p Triveni@123 -r superuser" -Wait -PassThru -NoNewWindow
            if ($P.ExitCode -ne 0) { Start-Process -FilePath $UsersTool -ArgumentList "passwd admin -p Triveni@123" -Wait -NoNewWindow }
        }

        Write-Host "✅ ElasticSearch Setup Complete. Login: admin/Triveni@123" -ForegroundColor Green

    }
    catch {
        Write-Host "❌ ElasticSearch Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Repair-ElasticSearch {
    Write-Host "`n [ REPAIRING ELASTICSEARCH ]" -ForegroundColor Yellow
    $ErrorActionPreference = "SilentlyContinue"

    $ElasticVersion = "8.11.1"
    $InstallDirRoot = "C:\Program Files\Elastic\Elasticsearch"
    $ElasticInstallDir = "$InstallDirRoot\$ElasticVersion"
    $UsersTool = "$ElasticInstallDir\bin\elasticsearch-users.bat"

    # 1. Validation
    if (-not (Test-Path $UsersTool)) {
        Write-Host "❌ ElasticSearch tool not found at: $UsersTool" -ForegroundColor Red
        Write-Host "   Cannot proceed with repair." -ForegroundColor Gray
        return
    }

    # 2. Reset Admin Credentials
    Write-Host "👤 Resetting Admin User (admin/Triveni@123)..." -ForegroundColor Cyan
    # Try adding user first
    $P = Start-Process -FilePath $UsersTool -ArgumentList "useradd admin -p Triveni@123 -r superuser" -Wait -PassThru -NoNewWindow
    if ($P.ExitCode -ne 0) {
        # If add failed (exists), update password
        Start-Process -FilePath $UsersTool -ArgumentList "passwd admin -p Triveni@123" -Wait -NoNewWindow
    }
    Write-Host "   Admin credentials updated." -ForegroundColor Gray

    # 3. Firewall Rules (Re-apply)
    Write-Host "🛡️  Refreshing Firewall Rules..." -ForegroundColor Cyan
    $FwRules = @(@{Name = "ElasticSearch-HTTP"; Port = 9200 }, @{Name = "ElasticSearch-Trans"; Port = 9300 })
    foreach ($Rule in $FwRules) {
        if (-not (Get-NetFirewallRule -DisplayName $Rule.Name -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $Rule.Name -Direction Inbound -LocalPort $Rule.Port -Protocol TCP -Action Allow | Out-Null
            Write-Host "   Created rule for $($Rule.Name) ($($Rule.Port))" -ForegroundColor Gray
        }
    }

    # 4. Service Auto-Start & Restart
    Write-Host "🔄 Restarting ElasticSearch Service..." -ForegroundColor Cyan
    $service = Get-Service -Name "elasticsearch" -ErrorAction SilentlyContinue
    if ($service) {
        Set-Service -Name "elasticsearch" -StartupType Automatic
        Restart-Service -Name "elasticsearch" -Force
        Write-Host "✅ Service Restarted & Set to Automatic." -ForegroundColor Green
    }
    else {
        Write-Host "❌ elasticsearch Service not found." -ForegroundColor Red
    }

    # 5. Port Check
    Write-Host "`n   Checking Ports:" -ForegroundColor Gray
    $ports = @(
        @{ Port = 9200; Name = "HTTP" },
        @{ Port = 9300; Name = "Transport" }
    )
    foreach ($p in $ports) {
        $msg = "   - Port $($p.Port) ($($p.Name))..."
        if ($msg.Length -lt 30) { $msg = $msg + " " * (30 - $msg.Length) }
        Write-Host $msg -NoNewline -ForegroundColor Gray
        if (Get-NetTCPConnection -LocalPort $p.Port -State Listen -ErrorAction SilentlyContinue) {
            Write-Host "✅ LISTENING" -ForegroundColor Green
        }
        else {
            Write-Host "❌ CLOSED" -ForegroundColor Red
        }
    }

    Write-Host "`n✅ Repair sequence finished." -ForegroundColor Green
    Write-Host "`n✅ Repair sequence finished." -ForegroundColor Green
    Write-Host "   ℹ️  Login Details: http://localhost:9200 (admin / Triveni@123)" -ForegroundColor Gray
}

function Install-OfficeSoftwareMenu {
    Write-Host "`n [ OFFICE SOFTWARE ]" -ForegroundColor Yellow
    Write-Host "   [1] Install RabbitMQ"
    Write-Host "   [2] Install ElasticSearch"
    Write-Host "   [3] Check RabbitMQ Status"
    Write-Host "   [4] Repair RabbitMQ (Enable Plugins & Restart)"
    Write-Host "   [5] Repair ElasticSearch (Reset Admin & Restart)"
    Write-Host "   [0] Go Back"
    
    $sub = Read-Host "Enter Choice"
    switch ($sub) {
        '1' { Install-RabbitMQ }
        '2' { Install-ElasticSearch }
        '3' { Get-RabbitMQStatus }
        '4' { Repair-RabbitMQ }
        '5' { Repair-ElasticSearch }
    }
    Read-Host "Press Enter to return..."
}

# -------------------------------------------------------------------------
# Custom install helpers
# -------------------------------------------------------------------------
function New-WebShortcut {
    param([string]$Url, [string]$Name)
    $desktop = [Environment]::GetFolderPath("Desktop")
    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut("$desktop\$Name.url")
    $Shortcut.TargetPath = $Url
    $Shortcut.Save()
    Write-Host "✅ Desktop shortcut created: $Name -> $Url" -ForegroundColor Green
}

function Install-Basecamp {
    Write-Host "`n [ SETTING UP BASECAMP ]" -ForegroundColor Cyan
    Write-Host "  Local installer not found in repo." -ForegroundColor Yellow
    # Create web shortcut as fallback
    New-WebShortcut -Url "https://basecamp.com" -Name "Basecamp Web"
    Write-Host "✅ Basecamp web shortcut created on Desktop." -ForegroundColor Green
}

function Install-Sprinto {
    Write-Host "`n [ SETTING UP SPRINTO ]" -ForegroundColor Cyan
    Write-Host "  Sprinto File Processor (sfproc) installer not found in repo." -ForegroundColor Yellow
    # Create web shortcut as fallback
    New-WebShortcut -Url "https://app.sprinto.com" -Name "Sprinto Dashboard"
    Write-Host "✅ Sprinto dashboard shortcut created on Desktop." -ForegroundColor Green
}

function Install-TimeDoctor {
    Write-Host "`n [ INSTALLING TIME DOCTOR ]" -ForegroundColor Cyan
    $url  = "https://updates.timedoctor.com/download/td2/windows/TimeDoctor.exe"
    $dest = "$env:TEMP\TimeDoctor-Setup.exe"
    try {
        Write-Host "⏬ Downloading Time Doctor installer..." -ForegroundColor Yellow
        (New-Object System.Net.WebClient).DownloadFile($url, $dest)
        Write-Host "🚀 Launching Time Doctor installer..." -ForegroundColor Yellow
        Start-Process -FilePath $dest -Wait -NoNewWindow -ErrorAction SilentlyContinue
        Write-Host "✅ Time Doctor installation complete." -ForegroundColor Green
    } catch {
        Write-Host "❌ Failed to download/install Time Doctor: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "   Please download manually from: https://www.timedoctor.com/download" -ForegroundColor Yellow
    }
}

function Install-Action1 {
    Write-Host "`n [ SETTING UP ACTION1 RMM ]" -ForegroundColor Cyan
    Write-Host "⚠️  Action1 requires an org-specific agent URL from your Action1 dashboard." -ForegroundColor Yellow
    New-WebShortcut -Url "https://app.action1.com" -Name "Action1 Dashboard"
    Write-Host "   Open the shortcut, log in, and download your org agent from:" -ForegroundColor Gray
    Write-Host "   Settings > Endpoints > Download Agent" -ForegroundColor Gray
    Write-Host "✅ Action1 dashboard shortcut created on Desktop." -ForegroundColor Green
}

function Install-NVMAndNode {
    Write-Host "`n [ INSTALLING NVM FOR WINDOWS + NODE.JS v15.14.0 ]" -ForegroundColor Cyan
    $nvmUrl       = "https://github.com/coreybutler/nvm-windows/releases/download/1.1.12/nvm-setup.exe"
    $nvmInstaller = "$env:TEMP\nvm-setup.exe"
    try {
        Write-Host "⏬ Downloading NVM for Windows..." -ForegroundColor Yellow
        (New-Object System.Net.WebClient).DownloadFile($nvmUrl, $nvmInstaller)
        Write-Host "🚀 Installing NVM silently..." -ForegroundColor Yellow
        Start-Process -FilePath $nvmInstaller -ArgumentList "/SILENT" -Wait -NoNewWindow -ErrorAction Stop
        Write-Host "✅ NVM installed." -ForegroundColor Green

        # Refresh NVM environment variables
        $nvmHome = "$env:APPDATA\nvm"
        if (Test-Path "$nvmHome\nvm.exe") {
            Write-Host "⏬ Installing Node.js v15.14.0 via NVM..." -ForegroundColor Yellow
            & "$nvmHome\nvm.exe" install 15.14.0
            & "$nvmHome\nvm.exe" use 15.14.0
            Write-Host "✅ Node.js v15.14.0 activated via NVM." -ForegroundColor Green
        } else {
            Write-Host "⚠️  NVM installed but nvm.exe not found at $nvmHome" -ForegroundColor Yellow
            Write-Host "   Please open a new terminal and run: nvm install 15.14.0 && nvm use 15.14.0" -ForegroundColor Gray
        }
    } catch {
        Write-Host "❌ Failed to install NVM: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# -------------------------------------------------------------------------
# System Setup functions
# -------------------------------------------------------------------------
function Get-NetworkInfo {
    Write-Host "`n [ NETWORK ADAPTER INFORMATION ]" -ForegroundColor Cyan
    Write-Host " ================================================================" -ForegroundColor DarkGray

    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
    if (-not $adapters) {
        Write-Host "  ⚠️  No active network adapters found." -ForegroundColor Yellow
        return
    }

    foreach ($adapter in $adapters) {
        $ipConfig = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $gateway  = (Get-NetRoute -InterfaceIndex $adapter.InterfaceIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
        $isDhcp   = ($ipConfig.PrefixOrigin -eq 'Dhcp') -or ($ipConfig.SuffixOrigin -eq 'Dhcp')

        Write-Host ""
        Write-Host "  Adapter   : $($adapter.Name)" -ForegroundColor Yellow
        Write-Host "  Type      : $($adapter.InterfaceDescription)" -ForegroundColor Gray
        Write-Host "  MAC Addr  : $($adapter.MacAddress)" -ForegroundColor Cyan
        Write-Host "  IP Addr   : $($ipConfig.IPAddress)" -ForegroundColor White
        Write-Host "  Subnet    : /$($ipConfig.PrefixLength)" -ForegroundColor White
        Write-Host "  Gateway   : $gateway" -ForegroundColor White
        Write-Host "  DHCP      : $(if ($isDhcp) { 'Yes' } else { 'No (Static)' })" -ForegroundColor White
        Write-Host " ----------------------------------------------------------------" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "✅ Network info retrieved. Use MAC address above for firewall binding." -ForegroundColor Green
}

function Set-PCHostname {
    Write-Host "`n [ CHANGE PC HOSTNAME ]" -ForegroundColor Cyan
    Write-Host "  Current Hostname: $env:COMPUTERNAME" -ForegroundColor Gray

    $newName = Read-Host "Enter new hostname"
    if ([string]::IsNullOrWhiteSpace($newName)) {
        Write-Host "⚠️  No hostname provided. Operation cancelled." -ForegroundColor Yellow
        return
    }

    try {
        Rename-Computer -NewName $newName -Force -ErrorAction Stop
        Write-Host "✅ Hostname changed to: $newName" -ForegroundColor Green
        Write-Host "⚠️  A restart is required for the new name to take effect." -ForegroundColor Yellow
    } catch {
        Write-Host "❌ Failed to change hostname: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function New-WorkUser {
    Write-Host "`n [ CREATE WORK USER ACCOUNT ]" -ForegroundColor Cyan

    $username = Read-Host "Enter username"
    if ([string]::IsNullOrWhiteSpace($username)) {
        Write-Host "⚠️  No username provided. Operation cancelled." -ForegroundColor Yellow
        return
    }

    $password      = "123456"
    $securePass    = ConvertTo-SecureString $password -AsPlainText -Force

    try {
        $existingUser = Get-LocalUser -Name $username -ErrorAction SilentlyContinue
        if ($existingUser) {
            Write-Host "⚠️  User '$username' already exists. Ensuring admin membership..." -ForegroundColor Yellow
        } else {
            New-LocalUser -Name $username -Password $securePass -FullName $username -Description "Work User Account" -ErrorAction Stop
            Write-Host "✅ User '$username' created." -ForegroundColor Green
        }
        Add-LocalGroupMember -Group "Administrators" -Member $username -ErrorAction SilentlyContinue
        Write-Host "✅ '$username' added to Administrators group." -ForegroundColor Green
        Write-Host "   Username : $username" -ForegroundColor Cyan
        Write-Host "   Password : $password" -ForegroundColor Cyan
    } catch {
        Write-Host "❌ Failed to create user: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# -------------------------------------------------------------------------
# Main program
# -------------------------------------------------------------------------
# Ensure package managers checked at start (non-fatal)
Ensure-PackageManagers

do {
    Show-Menu
    $choice = Read-Host "`nEnter your choice [0-6]"
    switch ($choice) {
        '1' { Install-NormalSoftware }
        '2' { Install-MSOffice }
        '3' { Invoke-Activation }
        '4' { Update-AllSoftware }
        '5' { Invoke-AdvancedToolkit }
        '6' { Launch-GlobalOptimizer }
        '7' { Install-OfficeSoftwareMenu }
        '0' {
            Write-Host "`n👋 Thank you for using Priyanshu Suryavanshi PC Setup Toolkit!" -ForegroundColor Cyan
            break
        }
        default {
            Show-Menu -StatusMessage "⚠️ Invalid selection! Please choose between 0-6." -StatusColor "Red"
        }
    }
} while ($true)

