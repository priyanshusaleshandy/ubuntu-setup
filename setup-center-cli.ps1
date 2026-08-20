# =============================================================================
# SETUP CENTER CLI - Windows PowerShell Edition
# =============================================================================
# All features from the Setup Center EXE, in a lightweight CLI:
#   [1] Install Essential Software  (Chrome, Firefox, WinRAR, VLC, Sumatra, AnyDesk, UltraViewer)
#   [2] Install MS Office 2021 Pro Plus
#   [3] System Activation Toolkit  (get.activated.win)
#   [4] Update All Software        (winget upgrade --all)
#   [5] Advanced Toolkit           (Chris Titus WinUtil)
#   [6] RAM Optimizer              (Test / Install Permanent / Remove)
#   [7] Office Software            (RabbitMQ & ElasticSearch - install/repair)
#   [8] System Setup               (Network Info / Change Hostname / Create User)
#   [0] Exit
# =============================================================================
# Usage:
#   Just double-click RUN-SETUP.bat (handles everything automatically)
# =============================================================================

Set-StrictMode -Off
$ErrorActionPreference = "Continue"
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# ── Tailscale Auto-Send Config ───────────────────────────────────────────────
# Change these if you ever move to a different Admin channel or server.
# No need to type it every time - the script uses this automatically.
$NtfyServer = "http://192.168.126.101:8080"   # Private self-hosted ntfy (Mac Mini via Docker)
$NtfyAdminChannel = "priyanshu-setup"

# ── Local NAS app cache ──────────────────────────────────────────────────────
# Some installers are large and their upstream hosts are occasionally flaky.
# If the office NAS is reachable, pull from its local cache instead - falls
# straight through to the original web URL if it isn't (laptop off-site, NAS
# down, etc).
$LocalAppsBase = "http://192.168.126.21:8001/windows/apps"

function Get-LocalOrWebFile {
    param([string]$Name, [string]$WebUrl, [string]$OutFile)
    try {
        Invoke-WebRequest -Uri "$LocalAppsBase/$Name" -OutFile $OutFile -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        return
    } catch { }
    Invoke-WebRequest -Uri $WebUrl -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
}

# ── Helpers ──────────────────────────────────────────────────────────────────
function Write-Sep  { param([string]$c="=",[int]$w=70) Write-Host ($c*$w) -ForegroundColor Cyan }
function Write-OK   { param([string]$m) Write-Host "  [OK]  $m" -ForegroundColor Green }
function Write-ERR  { param([string]$m) Write-Host "  [ERR] $m" -ForegroundColor Red }
function Write-WARN { param([string]$m) Write-Host "  [!]   $m" -ForegroundColor Yellow }
function Write-INFO { param([string]$m) Write-Host "  [*]   $m" -ForegroundColor Cyan }
function Pause-Menu { Read-Host "`n  Press Enter to return to menu" | Out-Null }

function Show-Header {
    Clear-Host
    Write-Sep "="
    Write-Host "   SETUP CENTER CLI  --  Priyanshu Suryavanshi PC Setup Toolkit" -ForegroundColor Magenta
    Write-Host "   Automated Setup & Activation Utility  |  PowerShell Edition"  -ForegroundColor DarkGray
    Write-Sep "="
    Write-Host ""
}

# ── Self-unblock (fixes "downloaded from internet" security block) ────────────
# Any .ps1 downloaded via a browser or curl/iwr gets a hidden "Mark of the Web"
# tag, which makes Windows refuse to run it ("cannot be loaded... digitally
# signed" or similar). This strips that tag from ourselves automatically,
# every single time, so it never blocks execution again.
try {
    if ($PSCommandPath) { Unblock-File -Path $PSCommandPath -ErrorAction SilentlyContinue }
} catch { }

# ── Self-elevate to Administrator (fixes "forgot Run as Administrator") ───
# Relaunches elevated via UAC prompt - handles both script files and inline execution (irm | iex).
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "  Requesting Administrator privileges (a UAC popup will appear - click Yes)..." -ForegroundColor Yellow
    try {
        $scriptToRun = $PSCommandPath
        if (-not $scriptToRun) {
            # Running inline (irm ... | iex) -> write scriptblock to temp file to elevate
            $scriptToRun = Join-Path $env:TEMP "setup-center-cli.ps1"
            $MyInvocation.MyCommand.ScriptBlock.ToString() | Out-File -FilePath $scriptToRun -Encoding UTF8 -Force
        }
        Start-Process powershell -Verb RunAs -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$scriptToRun`""
        )
        exit 0
    } catch {
        Write-Host ""
        Write-Host "  Could not elevate automatically (UAC was cancelled or blocked)." -ForegroundColor Red
        Write-Host "  Please open PowerShell as Administrator and run the command again." -ForegroundColor DarkGray
        Read-Host "  Press Enter to exit"
        exit 1
    }
}

# ── Package manager check ──────────────────────────────────────────────────
function Ensure-PackageManagers {
    Write-INFO "Checking package managers..."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-OK "winget detected."
    } else {
        Write-WARN "winget not found. Software installs will fall back to Chocolatey."
    }
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-OK "Chocolatey detected."
    } else {
        Write-WARN "Chocolatey not found - installing now..."
        try {
            Set-ExecutionPolicy Bypass -Scope Process -Force
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
            Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
            Write-OK "Chocolatey installed."
        } catch {
            Write-ERR "Chocolatey install failed: $($_.Exception.Message)"
        }
    }
}

# ─── Desktop shortcut helper ────────────────────────────────────────────────
function New-DesktopShortcut {
    param([string]$TargetPath,[string]$ShortcutName,[string]$Arguments="")
    try {
        $d = [Environment]::GetFolderPath("Desktop")
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut("$d\$ShortcutName.lnk")
        $s.TargetPath = $TargetPath
        if ($Arguments) { $s.Arguments = $Arguments }
        $s.IconLocation = "$TargetPath,0"
        $s.Save(); return $true
    } catch { return $false }
}

# =============================================================================
# [1] INSTALL ESSENTIAL SOFTWARE
# =============================================================================
function Install-AnyDeskDirectly {
    $dir = "C:\AnyDesk"; $exe = "$dir\AnyDesk.exe"
    Write-INFO "Installing AnyDesk..."
    try {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Get-LocalOrWebFile -Name "AnyDesk.exe" -WebUrl "https://download.anydesk.com/AnyDesk.exe" -OutFile $exe
        Start-Process -FilePath $exe -ArgumentList "--install" -Wait -NoNewWindow -ErrorAction SilentlyContinue
        if (Test-Path $exe) { New-DesktopShortcut $exe "AnyDesk" | Out-Null; Write-OK "AnyDesk installed." }
    } catch { Write-ERR "AnyDesk: $($_.Exception.Message)" }
}

function Install-UltraViewerDirectly {
    $dir = "C:\UltraViewer"; $setup = "$dir\UltraViewer_setup.exe"
    Write-INFO "Installing UltraViewer..."
    try {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Get-LocalOrWebFile -Name "UltraViewer_setup.exe" -WebUrl "https://ultraviewer.net/UltraViewer_setup.exe" -OutFile $setup
        Start-Process -FilePath $setup -ArgumentList "/VERYSILENT","/NORESTART" -Wait -NoNewWindow -ErrorAction SilentlyContinue
        $inst = "C:\Program Files\UltraViewer\UltraViewer.exe"
        if (Test-Path $inst) { New-DesktopShortcut $inst "UltraViewer" | Out-Null; Write-OK "UltraViewer installed." }
        else { Write-WARN "UltraViewer ran - verify install location." }
    } catch { Write-ERR "UltraViewer: $($_.Exception.Message)" }
}

function Install-NormalSoftware {
    Show-Header
    Write-Host "  [1] INSTALL ESSENTIAL SOFTWARE" -ForegroundColor Yellow
    Write-Host ""
    $list = @(
        @{N="Google Chrome";        ID="Google.Chrome";          Choco="googlechrome"},
        @{N="Mozilla Firefox";      ID="Mozilla.Firefox";        Choco="firefox"},
        @{N="WinRAR";              ID="RARLab.WinRAR";          Choco="winrar"},
        @{N="VLC Player";           ID="VideoLAN.VLC";           Choco="vlc"},
        @{N="PDF Reader (Sumatra)"; ID="SumatraPDF.SumatraPDF"; Choco="sumatrapdf"},
        @{N="AnyDesk";             ID="custom-anydesk"},
        @{N="UltraViewer";         ID="custom-ultraviewer"}
    )
    for ($i=0;$i -lt $list.Count;$i++) { Write-Host "  [$($i+1)] $($list[$i].N)" -ForegroundColor White }
    Write-Host ""
    $sel = Read-Host "  Selection (e.g. 1,3,5 or 'all')"
    $indices = @()
    if ($sel.Trim().ToLower() -eq 'all') {
        $indices = 1..$list.Count
    } else {
        foreach ($token in ($sel -split ",")) {
            $t = $token.Trim()
            if ($t -match '^\d+$') { $indices += [int]$t }
        }
    }
    Ensure-PackageManagers
    $hasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
    $hasChoco  = [bool](Get-Command choco -ErrorAction SilentlyContinue)
    foreach ($idx in ($indices|Sort-Object -Unique)) {
        if ($idx -lt 1 -or $idx -gt $list.Count) { Write-WARN "Invalid: $idx"; continue }
        $app = $list[$idx-1]
        switch ($app.ID) {
            "custom-anydesk"     { Install-AnyDeskDirectly }
            "custom-ultraviewer" { Install-UltraViewerDirectly }
            default {
                $installed = $false
                if ($hasWinget) {
                    Write-INFO "Installing $($app.N) via winget..."
                    try {
                        winget install --id $app.ID --silent --accept-source-agreements --accept-package-agreements
                        if ($LASTEXITCODE -eq 0) { Write-OK "$($app.N) done."; $installed = $true }
                    } catch { }
                }
                if (-not $installed -and $hasChoco -and $app.Choco) {
                    Write-INFO "Installing $($app.N) via Chocolatey..."
                    try {
                        choco install $app.Choco -y
                        Write-OK "$($app.N) done."
                        $installed = $true
                    } catch { Write-ERR "$($_.Exception.Message)" }
                }
                if (-not $installed -and -not $hasWinget -and -not $hasChoco) {
                    Write-ERR "Neither winget nor choco is available to install $($app.N)."
                }
            }
        }
    }
    Pause-Menu
}

# =============================================================================
# [2] INSTALL MS OFFICE 2021
# =============================================================================
function Install-MSOffice {
    Show-Header
    Write-Host "  [2] INSTALL MS OFFICE 2021 PRO PLUS" -ForegroundColor Yellow
    Write-Host ""
    $ZipUrl = "https://github.com/Priyanshu8494/my-choco-install-script/raw/refs/heads/main/Office%20Installer%201.33.zip"
    $BaseDir = "C:\Temp\Office_Auto_Install"
    $ZipPath = "$BaseDir\OfficeInstaller.zip"

    Write-Host "  [1/5] Preparing directories & exclusions..." -ForegroundColor Yellow
    if (-not (Test-Path $BaseDir)) { New-Item -Path $BaseDir -ItemType Directory -Force | Out-Null }
    try { Add-MpPreference -ExclusionPath $BaseDir -ErrorAction SilentlyContinue; Write-OK "Defender exclusion added." }
    catch { Write-WARN "Defender exclusion skipped." }

    Write-Host "  [2/5] Downloading Office zip..." -ForegroundColor Yellow
    try {
        $ProgressPreference='SilentlyContinue'
        Get-LocalOrWebFile -Name "Office Installer 1.33.zip" -WebUrl $ZipUrl -OutFile $ZipPath
        Write-OK "Download complete."
    } catch { Write-ERR "Download failed: $($_.Exception.Message)"; Pause-Menu; return }

    Write-Host "  [3/5] Extracting..." -ForegroundColor Yellow
    Unblock-File -Path $ZipPath -ErrorAction SilentlyContinue
    Expand-Archive -Path $ZipPath -DestinationPath $BaseDir -Force
    Write-OK "Extracted."

    Write-Host "  [4/5] Locating installer..." -ForegroundColor Yellow
    $i64 = Get-ChildItem -Path $BaseDir -Filter "Office Installer.exe"    -Recurse | Select-Object -First 1
    $i32 = Get-ChildItem -Path $BaseDir -Filter "Office Installer x86.exe" -Recurse | Select-Object -First 1
    $target = if ([Environment]::Is64BitOperatingSystem -and $i64) { $i64 } elseif ($i32) { $i32 } else { $null }

    if ($target) {
        Write-Host "  [5/5] Launching installer - follow on-screen steps..." -ForegroundColor Cyan
        Start-Process -FilePath $target.FullName -WorkingDirectory $target.Directory.FullName -Wait
        Write-OK "Office installer finished."
    } else { Write-ERR "Installer EXE not found in zip." }

    if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
    Pause-Menu
}

# =============================================================================
# [3] SYSTEM ACTIVATION
# =============================================================================
function Invoke-Activation {
    Show-Header
    Write-Host "  [3] SYSTEM ACTIVATION TOOLKIT" -ForegroundColor Yellow
    Write-Host ""
    Write-WARN "Runs remote script from https://get.activated.win"
    Write-Host "  Ensure you trust the source before continuing." -ForegroundColor DarkGray
    Write-Host ""
    $c = Read-Host "  Continue? (y/N)"
    if ($c -notmatch '^[Yy]$') { Pause-Menu; return }
    try { irm https://get.activated.win | iex; Write-OK "Activation finished." }
    catch { Write-ERR "Activation failed: $($_.Exception.Message)" }
    Pause-Menu
}

# =============================================================================
# [4] UPDATE ALL SOFTWARE
# =============================================================================
function Update-AllSoftware {
    Show-Header
    Write-Host "  [4] UPDATE ALL SOFTWARE" -ForegroundColor Yellow
    Write-Host ""
    Ensure-PackageManagers
    Write-INFO "Running: winget upgrade --all ..."
    try {
        winget upgrade --all --silent --accept-source-agreements --accept-package-agreements
        Write-OK "All software updated."
    } catch { Write-ERR "$($_.Exception.Message)" }
    Pause-Menu
}

# =============================================================================
# [5] ADVANCED TOOLKIT (WINUTIL)
# =============================================================================
function Invoke-AdvancedToolkit {
    Show-Header
    Write-Host "  [5] ADVANCED TOOLKIT - Chris Titus WinUtil" -ForegroundColor Yellow
    Write-Host ""
    Write-WARN "Runs: irm https://christitus.com/win | iex"
    $c = Read-Host "  Continue? (y/N)"
    if ($c -notmatch '^[Yy]$') { Pause-Menu; return }
    try { irm https://christitus.com/win | iex; Write-OK "WinUtil finished." }
    catch { Write-ERR "$($_.Exception.Message)" }
    Pause-Menu
}

# =============================================================================
# [6] SYSTEM PERFORMANCE SUITE (RAM, CPU & SSD UNIFIED OPTIMIZER)
# =============================================================================
function Launch-PerformanceSuite {
    $script = "$PSScriptRoot\Performance.ps1"
    if (-not (Test-Path $script)) { $script = "d:\core-labs\windows\Performance.ps1" }
    if (Test-Path $script) {
        & $script
    } else {
        Write-ERR "Script Performance.ps1 not found."
        Pause-Menu
    }
}

# =============================================================================
# [7] OFFICE SOFTWARE - RabbitMQ & ElasticSearch
# =============================================================================

function Install-RabbitMQ {
    Show-Header; Write-Host "  [7.1] INSTALL RABBITMQ" -ForegroundColor Cyan; Write-Host ""
    $NasPath   = "\\174.156.4.3\fjt\Required softwares\Automation Software\Automations-Priyanshu\rabbitmq,elastic"
    $ErlangExe = "otp_win64_25.1.2.exe"
    $ErlangUrl = "https://github.com/erlang/otp/releases/download/OTP-25.1.2/otp_win64_25.1.2.exe"
    $RabbitExe = "rabbitmq-server-3.11.3.exe"
    $RabbitUrl = "https://github.com/rabbitmq/rabbitmq-server/releases/download/v3.11.3/rabbitmq-server-3.11.3.exe"
    $ver       = "3.11.3"
    $sbin      = "C:\Program Files\RabbitMQ Server\rabbitmq_server-$ver\sbin"

    function Get-Installer($Name,$NasDir,$WebUrl) {
        $dest = "$env:TEMP\$Name"; $nas = "$NasDir\$Name"
        if (Test-Path $nas) { try{Copy-Item $nas $dest -Force; return $dest}catch{} }
        Invoke-WebRequest -Uri $WebUrl -OutFile $dest -UseBasicParsing; return $dest
    }

    try {
        if (Test-Path "$sbin\rabbitmqctl.bat") { Write-OK "RabbitMQ already installed." }
        else {
            $erl = Get-Installer $ErlangExe $NasPath $ErlangUrl
            $rmq = Get-Installer $RabbitExe $NasPath $RabbitUrl
            Write-WARN "Complete Erlang installer in the opened window..."
            Start-Process $erl -Wait
            $erlDir = Get-ChildItem "C:\Program Files" -Filter "erl*" -Directory | Sort-Object Name -Descending | Select-Object -First 1
            if ($erlDir) { $env:ERLANG_HOME = $erlDir.FullName }
            Write-WARN "Complete RabbitMQ installer in the opened window..."
            Start-Process $rmq -Wait
        }
        $cur = [Environment]::GetEnvironmentVariable("Path","Machine")
        if ($cur -notlike "*$sbin*" -and (Test-Path $sbin)) {
            [Environment]::SetEnvironmentVariable("Path","$cur;$sbin","Machine"); $env:Path += ";$sbin"
            Write-OK "RabbitMQ sbin added to PATH."
        }
        if (Test-Path "$sbin\rabbitmq-plugins.bat") {
            Push-Location $sbin
            & .\rabbitmq-plugins.bat enable rabbitmq_management
            & .\rabbitmq-plugins.bat enable rabbitmq_shovel
            & .\rabbitmq-plugins.bat enable rabbitmq_shovel_management
            Pop-Location
        }
        $fw = @(@{N="RabbitMQ-AMQP";P=5672},@{N="RabbitMQ-Mgmt";P=15672},@{N="RabbitMQ-EPMD";P=4369},@{N="RabbitMQ-Dist";P=25672})
        foreach ($r in $fw) {
            if (-not (Get-NetFirewallRule -DisplayName $r.N -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $r.N -Direction Inbound -LocalPort $r.P -Protocol TCP -Action Allow | Out-Null
            }
        }
        $ctl = "$sbin\rabbitmqctl.bat"
        if (Test-Path $ctl) {
            Start-Process $ctl -ArgumentList "change_password guest guest" -Wait -NoNewWindow -ErrorAction SilentlyContinue
            Start-Process $ctl -ArgumentList "set_user_tags guest administrator" -Wait -NoNewWindow
            Start-Process $ctl -ArgumentList 'set_permissions -p / guest ".*" ".*" ".*"' -Wait -NoNewWindow
        }
        Set-Service -Name "RabbitMQ" -StartupType Automatic -ErrorAction SilentlyContinue
        Write-OK "RabbitMQ ready. Login: guest/guest -> http://localhost:15672"
    } catch { Write-ERR "$($_.Exception.Message)" }
    Pause-Menu
}

function Get-RabbitMQStatus {
    Show-Header; Write-Host "  [7.3] RABBITMQ STATUS" -ForegroundColor Cyan; Write-Host ""
    $svc = Get-Service -Name "RabbitMQ" -ErrorAction SilentlyContinue
    if ($svc) { $c=if($svc.Status -eq 'Running'){"Green"}else{"Red"}; Write-Host "  Service: " -NoNewline; Write-Host $svc.Status -ForegroundColor $c }
    else { Write-ERR "RabbitMQ service not found." }
    Write-Host ""; Write-Host "  Ports:" -ForegroundColor Gray
    @(@{P=5672;N="AMQP"},@{P=15672;N="Management"},@{P=4369;N="Erlang"},@{P=25672;N="Distribution"}) | ForEach-Object {
        $label = "  - $($_.P) ($($_.N))".PadRight(35)
        Write-Host $label -NoNewline -ForegroundColor Gray
        if (Get-NetTCPConnection -LocalPort $_.P -State Listen -ErrorAction SilentlyContinue) { Write-Host "LISTENING" -ForegroundColor Green }
        else { Write-Host "CLOSED" -ForegroundColor DarkGray }
    }
    Pause-Menu
}

function Repair-RabbitMQ {
    Show-Header; Write-Host "  [7.4] REPAIR RABBITMQ" -ForegroundColor Yellow; Write-Host ""
    $ver="3.11.3"; $sbin="C:\Program Files\RabbitMQ Server\rabbitmq_server-$ver\sbin"
    if (-not (Test-Path $sbin)) { Write-ERR "RabbitMQ not found at expected path."; Pause-Menu; return }
    if (Test-Path "$sbin\rabbitmq-plugins.bat") {
        Push-Location $sbin
        & .\rabbitmq-plugins.bat enable rabbitmq_management
        & .\rabbitmq-plugins.bat enable rabbitmq_shovel
        & .\rabbitmq-plugins.bat enable rabbitmq_shovel_management
        Pop-Location
    }
    @(@{N="RabbitMQ-AMQP";P=5672},@{N="RabbitMQ-Mgmt";P=15672},@{N="RabbitMQ-EPMD";P=4369},@{N="RabbitMQ-Dist";P=25672}) | ForEach-Object {
        if (-not (Get-NetFirewallRule -DisplayName $_.N -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $_.N -Direction Inbound -LocalPort $_.P -Protocol TCP -Action Allow | Out-Null
        }
    }
    $ctl = "$sbin\rabbitmqctl.bat"
    if (Test-Path $ctl) {
        Start-Process $ctl -ArgumentList "stop_app" -Wait -NoNewWindow -ErrorAction SilentlyContinue
        Start-Process $ctl -ArgumentList "delete_user guest" -Wait -NoNewWindow -ErrorAction SilentlyContinue
        Start-Process $ctl -ArgumentList "add_user guest guest" -Wait -NoNewWindow -ErrorAction SilentlyContinue
        Start-Process $ctl -ArgumentList "set_user_tags guest administrator" -Wait -NoNewWindow
        Start-Process $ctl -ArgumentList 'set_permissions -p / guest ".*" ".*" ".*"' -Wait -NoNewWindow
        Start-Process $ctl -ArgumentList "start_app" -Wait -NoNewWindow -ErrorAction SilentlyContinue
    }
    $svc = Get-Service "RabbitMQ" -ErrorAction SilentlyContinue
    if ($svc) { Set-Service "RabbitMQ" -StartupType Automatic; Restart-Service "RabbitMQ" -Force; Write-OK "Service restarted." }
    else { Write-ERR "RabbitMQ service not found." }
    Write-OK "Repair done. -> http://localhost:15672  (guest/guest)"
    Pause-Menu
}

function Read-ESAdminPassword {
    $sec = Read-Host "  ElasticSearch admin password (blank = cancel)" -AsSecureString
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    if ([string]::IsNullOrWhiteSpace($plain)) { return $null }
    if ($plain.Length -lt 8) { Write-WARN "Password must be at least 8 characters."; return $null }
    return $plain
}

function Install-ElasticSearch {
    Show-Header; Write-Host "  [7.2] INSTALL ELASTICSEARCH 8.11.1" -ForegroundColor Cyan; Write-Host ""
    $ver="8.11.1"; $zip="elasticsearch-8.11.1-windows-x86_64.zip"
    $nas="\\174.156.4.3\fjt\Required softwares\Automation Software\Automations-Priyanshu\rabbitmq,elastic"
    $url="https://artifacts.elastic.co/downloads/elasticsearch/$zip"
    $root="C:\Program Files\Elastic\Elasticsearch"; $dir="$root\$ver"
    $data="C:\ProgramData\Elastic\Elasticsearch"; $java="C:\Program Files\Java\jdk-17"
    $jdkNas="\\174.156.4.3\fjt\Required softwares\Update - Dev System\jdk-17.0.6_windows-x64_bin.exe"

    $esPass = Read-ESAdminPassword
    if (-not $esPass) { Write-WARN "Cancelled."; Pause-Menu; return }

    try {
        if (Test-Path "$dir\bin\elasticsearch-service.bat") { Write-OK "Elasticsearch already installed." }
        else {
            if (-not (Test-Path $root)) { New-Item $root -ItemType Directory -Force | Out-Null }
            $local = "$env:TEMP\$zip"; $nasZ = "$nas\$zip"; $ok=$false
            if (Test-Path $nasZ) { try{Copy-Item $nasZ $local -Force; $ok=$true}catch{} }
            if (-not $ok) { Write-INFO "Downloading (may take several minutes)..."; Invoke-WebRequest -Uri $url -OutFile $local -UseBasicParsing }
            Write-INFO "Extracting..."; Expand-Archive $local $root -Force
            $ex="$root\elasticsearch-$ver"; if(Test-Path $ex){Rename-Item $ex $ver}
        }
        if (-not (Test-Path "$java\bin\java.exe")) {
            $jdkLocal="$env:TEMP\jdk-17-installer.exe"
            if (Test-Path $jdkNas) { Copy-Item $jdkNas $jdkLocal -Force }
            if (Test-Path $jdkLocal) { Write-WARN "Complete JDK installer..."; Start-Process $jdkLocal -Wait }
        }
        [System.Environment]::SetEnvironmentVariable("JAVA_HOME",$null,"User")
        [System.Environment]::SetEnvironmentVariable("ES_JAVA_HOME",$java,"Machine")
        [System.Environment]::SetEnvironmentVariable("ES_HOME",$dir,"Machine")
        [System.Environment]::SetEnvironmentVariable("ES_PATH_CONF","$data\config","Machine")
        [System.Environment]::SetEnvironmentVariable("ELASTIC_CLIENT_APIVERSIONING","true","Machine")
        New-Item "$data\config" -ItemType Directory -Force | Out-Null
        New-Item "$data\data"   -ItemType Directory -Force | Out-Null
        New-Item "$data\logs"   -ItemType Directory -Force | Out-Null
        $src="$dir\config"; if(Test-Path "$src\elasticsearch.yml"){Copy-Item "$src\*" "$data\config" -Recurse -Force}
        "bootstrap.memory_lock: false`ncluster.name : elasticsearch`nhttp.port: 9200`nnode.name : $env:COMPUTERNAME`npath.data: $data\data`npath.logs: $data\logs`npath.repo: $data\backup`ntransport.port: 9300`nxpack.license.self_generated.type: basic`nxpack.security.enabled: true`naction.auto_create_index: .monitoring*,.watches,.triggered_watches,.watcher-history*,.ml*" | Set-Content "$data\config\elasticsearch.yml"
        @(@{N="ElasticSearch-HTTP";P=9200},@{N="ElasticSearch-Trans";P=9300}) | ForEach-Object {
            if (-not (Get-NetFirewallRule -DisplayName $_.N -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $_.N -Direction Inbound -LocalPort $_.P -Protocol TCP -Action Allow | Out-Null
            }
        }
        $bat="$dir\bin\elasticsearch-service.bat"
        $es=Get-Service "elasticsearch" -ErrorAction SilentlyContinue
        if (-not $es) { if(Test-Path $bat){Start-Process $bat -ArgumentList "install elasticsearch" -Wait; Set-Service "elasticsearch" -StartupType Automatic; Start-Service "elasticsearch"} }
        else { Set-Service "elasticsearch" -StartupType Automatic; if($es.Status -ne "Running"){Start-Service "elasticsearch"} }
        Write-INFO "Waiting 15s for ES to start..."; Start-Sleep -Seconds 15
        $ut="$dir\bin\elasticsearch-users.bat"
        if (Test-Path $ut) {
            $p=Start-Process $ut -ArgumentList "useradd admin -p `"$esPass`" -r superuser" -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -ne 0) { Start-Process $ut -ArgumentList "passwd admin -p `"$esPass`"" -Wait -NoNewWindow }
        }
        $esPass = $null
        Write-OK "Elasticsearch ready. -> http://localhost:9200  (admin / the password you just set)"
    } catch { Write-ERR "$($_.Exception.Message)" }
    Pause-Menu
}

function Repair-ElasticSearch {
    Show-Header; Write-Host "  [7.5] REPAIR ELASTICSEARCH" -ForegroundColor Yellow; Write-Host ""
    $ver="8.11.1"; $dir="C:\Program Files\Elastic\Elasticsearch\$ver"
    $ut="$dir\bin\elasticsearch-users.bat"
    if (-not (Test-Path $ut)) { Write-ERR "ES tool not found. Is Elasticsearch installed?"; Pause-Menu; return }
    $esPass = Read-ESAdminPassword
    if (-not $esPass) { Write-WARN "Cancelled."; Pause-Menu; return }
    $p=Start-Process $ut -ArgumentList "useradd admin -p `"$esPass`" -r superuser" -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { Start-Process $ut -ArgumentList "passwd admin -p `"$esPass`"" -Wait -NoNewWindow }
    $esPass = $null
    Write-OK "Admin credentials reset."
    @(@{N="ElasticSearch-HTTP";P=9200},@{N="ElasticSearch-Trans";P=9300}) | ForEach-Object {
        if (-not (Get-NetFirewallRule -DisplayName $_.N -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $_.N -Direction Inbound -LocalPort $_.P -Protocol TCP -Action Allow | Out-Null
        }
    }
    $svc=Get-Service "elasticsearch" -ErrorAction SilentlyContinue
    if ($svc) { Set-Service "elasticsearch" -StartupType Automatic; Restart-Service "elasticsearch" -Force; Write-OK "Service restarted." }
    else { Write-ERR "elasticsearch service not found." }
    Write-Host ""; Write-Host "  Ports:" -ForegroundColor Gray
    @(@{P=9200;N="HTTP"},@{P=9300;N="Transport"}) | ForEach-Object {
        $l="  - $($_.P) ($($_.N))".PadRight(30)
        Write-Host $l -NoNewline -ForegroundColor Gray
        if (Get-NetTCPConnection -LocalPort $_.P -State Listen -ErrorAction SilentlyContinue) { Write-Host "LISTENING" -ForegroundColor Green }
        else { Write-Host "CLOSED" -ForegroundColor Red }
    }
    Write-OK "Repair done. -> http://localhost:9200  (admin / the password you just set)"
    Pause-Menu
}

function Show-OfficeSoftwareMenu {
    while ($true) {
        Show-Header
        Write-Host "  [7] OFFICE SOFTWARE - RabbitMQ & ElasticSearch" -ForegroundColor Yellow; Write-Host ""
        Write-Host "  [1] Install RabbitMQ"                              -ForegroundColor White
        Write-Host "  [2] Install ElasticSearch"                         -ForegroundColor White
        Write-Host "  [3] RabbitMQ Status"                               -ForegroundColor Cyan
        Write-Host "  [4] Repair RabbitMQ  (plugins + user + restart)"   -ForegroundColor Yellow
        Write-Host "  [5] Repair ElasticSearch  (user + restart)"        -ForegroundColor Yellow
        Write-Host "  [0] Back"                                           -ForegroundColor DarkGray
        Write-Host ""
        $sub = (Read-Host "  Choice").Trim()
        switch ($sub) {
            '1' { Install-RabbitMQ }
            '2' { Install-ElasticSearch }
            '3' { Get-RabbitMQStatus }
            '4' { Repair-RabbitMQ }
            '5' { Repair-ElasticSearch }
            '0' { return }
        }
    }
}

# =============================================================================
# [8] SYSTEM SETUP - Network Info / Hostname / Create User
# =============================================================================
function Get-NetworkInfo {
    Show-Header; Write-Host "  [8.1] NETWORK INFORMATION" -ForegroundColor Cyan; Write-Host ""
    Get-NetAdapter | Where-Object Status -eq "Up" | ForEach-Object {
        Write-Host "  -- $($_.Name) ($($_.InterfaceDescription))" -ForegroundColor White
        Get-NetIPAddress -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Host ("    " + $_.AddressFamily.ToString().PadRight(8) + ": $($_.IPAddress)/$($_.PrefixLength)") -ForegroundColor Gray
        }
        $gw  = (Get-NetRoute -InterfaceIndex $_.InterfaceIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
        $dns = (Get-DnsClientServerAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses -join ", "
        $mac = $_.MacAddress
        if ($gw)  { Write-Host "    Gateway : $gw"  -ForegroundColor DarkGray }
        if ($dns) { Write-Host "    DNS     : $dns" -ForegroundColor DarkGray }
        Write-Host "    MAC     : $mac" -ForegroundColor DarkGray; Write-Host ""
    }
    Write-Host "  Hostname : $env:COMPUTERNAME" -ForegroundColor Cyan
    try { Write-Host "  Public IP: $(Invoke-RestMethod https://api.ipify.org -ErrorAction Stop)" -ForegroundColor Cyan }
    catch { Write-WARN "Could not fetch public IP." }
    Pause-Menu
}

function Set-PCHostname {
    Show-Header; Write-Host "  [8.2] CHANGE PC HOSTNAME" -ForegroundColor Cyan; Write-Host ""
    Write-Host "  Current hostname: $env:COMPUTERNAME" -ForegroundColor White; Write-Host ""
    $n = Read-Host "  New hostname (blank = cancel)"
    if ([string]::IsNullOrWhiteSpace($n)) { Write-WARN "Cancelled."; Pause-Menu; return }
    try {
        Rename-Computer -NewName $n -Force
        Write-OK "Hostname set to '$n'. Restart required."
        if ((Read-Host "  Restart now? (y/N)") -match '^[Yy]$') { Restart-Computer -Force }
    } catch { Write-ERR "$($_.Exception.Message)" }
    Pause-Menu
}

function New-WorkUser {
    Show-Header; Write-Host "  [8.3] CREATE WORK USER" -ForegroundColor Cyan; Write-Host ""
    $uname = Read-Host "  Username (blank = cancel)"
    if ([string]::IsNullOrWhiteSpace($uname)) { Write-WARN "Cancelled."; Pause-Menu; return }
    $pass    = Read-Host "  Password" -AsSecureString
    $full    = Read-Host "  Full name (optional)"
    $isAdmin = Read-Host "  Administrator? (y/N)"
    try {
        $p = @{Name=$uname; Password=$pass; AccountNeverExpires=$true; PasswordNeverExpires=$true}
        if ($full) { $p.FullName = $full }
        New-LocalUser @p
        Add-LocalGroupMember -Group "Users" -Member $uname -ErrorAction SilentlyContinue
        if ($isAdmin -match '^[Yy]$') { Add-LocalGroupMember -Group "Administrators" -Member $uname; Write-OK "Admin user '$uname' created." }
        else { Write-OK "Standard user '$uname' created." }
    } catch { Write-ERR "$($_.Exception.Message)" }
    Pause-Menu
}

function Show-SystemSetupMenu {
    while ($true) {
        Show-Header
        Write-Host "  [8] SYSTEM SETUP" -ForegroundColor Yellow; Write-Host ""
        Write-Host "  [1] Network Information"    -ForegroundColor White
        Write-Host "  [2] Change PC Hostname"     -ForegroundColor White
        Write-Host "  [3] Create Work User"       -ForegroundColor White
        Write-Host "  [0] Back"                   -ForegroundColor DarkGray
        Write-Host ""
        $sub = (Read-Host "  Choice").Trim()
        switch ($sub) {
            '1' { Get-NetworkInfo }
            '2' { Set-PCHostname }
            '3' { New-WorkUser }
            '0' { return }
        }
    }
}

# =============================================================================
# [9] TAILSCALE VPN
# =============================================================================
# On Windows there is no sudo - tailscale.exe is added to PATH by the installer.
# Commands are run directly as the logged-in (admin) user.

function Install-Tailscale {
    Show-Header; Write-Host "  [9.1] INSTALL TAILSCALE" -ForegroundColor Cyan; Write-Host ""
    Write-INFO "Installing Tailscale via winget..."
    try {
        winget install --id Tailscale.Tailscale --silent --accept-source-agreements --accept-package-agreements
        Write-OK "Tailscale installed. PATH will be available after restarting the shell."
    } catch { Write-ERR "Install failed: $($_.Exception.Message)" }
    Pause-Menu
}

function Invoke-TailscaleLogin {
    Show-Header; Write-Host "  [9.2] TAILSCALE LOGIN / REGISTER" -ForegroundColor Cyan; Write-Host ""
    Write-Host "  [1] Auto-send Login Link to Admin (no typing)" -ForegroundColor White
    Write-Host "  [2] Auth Key Login    (Use pre-authorized key from Admin)" -ForegroundColor Green
    Write-Host "  [0] Back" -ForegroundColor DarkGray
    Write-Host ""
    $subChoice = Read-Host "  Select Login Method"

    if ($subChoice -eq '1') {
        $topic = $NtfyAdminChannel
        # Auto-clean: strip any accidental full-URL prefix
        $topic = $topic -replace [regex]::Escape("$NtfyServer/"), '' -replace '^https?://ntfy\.sh/', '' -replace '^ntfy\.sh/', '' -replace '/$', ''
        Write-INFO "Requesting login link (will auto-send to '$topic')..."
        Write-WARN "This forces a fresh login even if already connected."
        $logFile = [System.IO.Path]::GetTempFileName()
        $errFile = [System.IO.Path]::GetTempFileName()
        try {
            $proc = Start-Process -FilePath "tailscale" -ArgumentList @(
                "up","--login-server=https://bifrost.saleshandy.com","--accept-routes","--accept-dns","--force-reauth"
            ) -NoNewWindow -RedirectStandardOutput $logFile -RedirectStandardError $errFile -PassThru

            $loginUrl = $null
            for ($i = 0; $i -lt 30; $i++) {
                Start-Sleep -Seconds 1
                $combined = (Get-Content $logFile -ErrorAction SilentlyContinue) + (Get-Content $errFile -ErrorAction SilentlyContinue) | Out-String
                $match = [regex]::Match($combined, 'https://\S+')
                if ($match.Success) { $loginUrl = $match.Value; break }
                if ($proc.HasExited) { break }
            }
            Get-Content $logFile, $errFile -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }

            if ($loginUrl) {
                Write-INFO "Sending link to Admin channel '$topic'..."
                try {
                    Invoke-RestMethod -Uri "$NtfyServer/$topic" -Method Post -Body "New PC ($env:COMPUTERNAME) Tailscale login: $loginUrl" -TimeoutSec 10 | Out-Null
                    Write-OK "Link sent! Admin should open $NtfyServer/$topic in a browser tab (once, keep it open) to see it arrive instantly."
                } catch {
                    Write-WARN "Auto-send failed (server unreachable - check VPN/Tailscale connection to $NtfyServer). Admin can still use the URL printed above."
                }
            } else {
                Write-OK "Already logged in - no link needed."
            }
            if (-not $proc.HasExited) { $proc.WaitForExit() }
        } catch { Write-ERR "Login failed: $($_.Exception.Message)" }
        finally { Remove-Item $logFile, $errFile -ErrorAction SilentlyContinue }
    }
    elseif ($subChoice -eq '2') {
        $authKey = Read-Host "  Enter Tailscale Auth Key (tskey-auth-...)"
        if ([string]::IsNullOrWhiteSpace($authKey)) { Write-WARN "Cancelled."; Pause-Menu; return }
        Write-INFO "Registering node using Auth Key..."
        try {
            tailscale up --authkey=$authKey --login-server=https://bifrost.saleshandy.com --accept-routes --accept-dns
            Write-OK "Node successfully registered with Auth Key!"
        } catch { Write-ERR "Registration failed: $($_.Exception.Message)" }
    }
    Pause-Menu
}

function Invoke-TailscaleConnect {
    Show-Header; Write-Host "  [9.3] TAILSCALE CONNECT (Accept Routes)" -ForegroundColor Cyan; Write-Host ""
    Write-INFO "Connecting to Tailscale with --accept-routes..."
    try {
        tailscale up --accept-routes --login-server=https://bifrost.saleshandy.com
        Write-OK "Connected."
    } catch { Write-ERR "Connect failed: $($_.Exception.Message)" }
    Pause-Menu
}

function Invoke-TailscaleFullReset {
    Show-Header; Write-Host "  [9.4] TAILSCALE FULL RESET + CONNECT" -ForegroundColor Cyan; Write-Host ""
    Write-INFO "Resetting state and reconnecting (accept-dns + accept-routes)..."
    try {
        tailscale up --login-server=https://bifrost.saleshandy.com --reset --accept-dns --accept-routes
        Write-OK "Reset & reconnected."
    } catch { Write-ERR "Failed: $($_.Exception.Message)" }
    Pause-Menu
}

function Invoke-TailscaleExitNode {
    Show-Header; Write-Host "  [9.5] TAILSCALE CONNECT WITH EXIT NODE" -ForegroundColor Cyan; Write-Host ""
    Write-INFO "Connecting via exit node 100.64.0.7 (accept-dns + accept-routes)..."
    try {
        tailscale up --login-server=https://bifrost.saleshandy.com --accept-dns --accept-routes --exit-node=100.64.0.7
        Write-OK "Connected through exit node."
    } catch { Write-ERR "Failed: $($_.Exception.Message)" }
    Pause-Menu
}

function Get-TailscaleStatus {
    Show-Header; Write-Host "  [9.6] TAILSCALE STATUS / DIAGNOSTICS" -ForegroundColor Cyan; Write-Host ""
    try {
        Write-Host "  --- Status ---" -ForegroundColor Yellow
        tailscale status
        Write-Host ""
        Write-Host "  --- IP Address ---" -ForegroundColor Yellow
        tailscale ip
        Write-Host ""
        Write-Host "  --- Ping (VPN gateway 100.64.0.1) ---" -ForegroundColor Yellow
        tailscale ping 100.64.0.1
    } catch { Write-ERR "Diagnostics error: $($_.Exception.Message)" }
    Pause-Menu
}

function Uninstall-Tailscale {
    Show-Header; Write-Host "  [9.7] UNINSTALL TAILSCALE" -ForegroundColor Red; Write-Host ""
    $c = Read-Host "  Confirm uninstall Tailscale? (y/N)"
    if ($c -notmatch '^[Yy]$') { Pause-Menu; return }
    try {
        tailscale logout 2>$null
        winget uninstall --id Tailscale.Tailscale --silent
        Write-OK "Tailscale uninstalled."
    } catch { Write-ERR "Uninstall failed: $($_.Exception.Message)" }
    Pause-Menu
}

function Show-TailscaleMenu {
    while ($true) {
        Show-Header
        Write-Host "  [9] TAILSCALE VPN" -ForegroundColor Yellow
        Write-Host "  Login Server: https://bifrost.saleshandy.com" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  [1] Install Tailscale                   (via winget)"                        -ForegroundColor White
        Write-Host "  [2] Login                               (auto-sent to Admin)"                 -ForegroundColor Cyan
        Write-Host "  [3] Connect                             (--accept-routes)"                    -ForegroundColor Green
        Write-Host "  [4] Full Reset + Connect                (--reset --accept-dns --accept-routes)" -ForegroundColor Yellow
        Write-Host "  [5] Connect via Exit Node               (--exit-node=100.64.0.7)"             -ForegroundColor Magenta
        Write-Host "  [6] Status / Diagnostics"                                                     -ForegroundColor Cyan
        Write-Host "  [7] Uninstall Tailscale"                                                      -ForegroundColor Red
        Write-Host "  [0] Back"                                                                     -ForegroundColor DarkGray
        Write-Host ""
        $sub = (Read-Host "  Choice").Trim()
        switch ($sub) {
            '1' { Install-Tailscale }
            '2' { Invoke-TailscaleLogin }
            '3' { Invoke-TailscaleConnect }
            '4' { Invoke-TailscaleFullReset }
            '5' { Invoke-TailscaleExitNode }
            '6' { Get-TailscaleStatus }
            '7' { Uninstall-Tailscale }
            '0' { return }
            default { Write-WARN "Invalid choice."; Start-Sleep -Seconds 1 }
        }
    }
}

function Show-BlockchainMenu {
    while ($true) {
        Show-Header
        Write-Host "  [10] BLOCKCHAIN & ETHEREUM DEVELOPER TOOLKIT" -ForegroundColor Yellow; Write-Host ""
        Write-Host "  [1] Install Node.js & npm (via winget)" -ForegroundColor White
        Write-Host "  [2] Install Ganache CLI (npm install -g ganache-cli)" -ForegroundColor White
        Write-Host "  [3] Install Truffle Framework (npm install -g truffle)" -ForegroundColor White
        Write-Host "  [4] Open Geth Ethereum Client Download Page" -ForegroundColor White
        Write-Host "  [0] Back" -ForegroundColor DarkGray; Write-Host ""
        $ch = (Read-Host "  Choice").Trim()
        switch ($ch) {
            '1' { winget install --id OpenJS.NodeJS -e --source winget; Pause-Menu }
            '2' { npm install -g ganache-cli; Write-OK "Ganache CLI installed."; Pause-Menu }
            '3' { npm install -g truffle; Write-OK "Truffle installed."; Pause-Menu }
            '4' { Start-Process "https://geth.ethereum.org/downloads"; Write-OK "Opened Geth download page."; Pause-Menu }
            '0' { return }
            default { Write-WARN "Invalid choice."; Start-Sleep -Seconds 1 }
        }
    }
}

function Show-Win11BypassMenu {
    Show-Header
    Write-Host "  [11] WINDOWS 11 SETUP & OOBE BYPASS HELPERS" -ForegroundColor Yellow; Write-Host ""
    Write-Host "  1. Bypass Network Requirement during Windows 11 Initial Setup (OOBE):" -ForegroundColor Cyan
    Write-Host "     Press Shift + F10 on setup screen, type:  oobe\BypassNRO  and press Enter." -ForegroundColor White
    Write-Host ""
    Write-Host "  2. Bypass Microsoft Account Requirement (Local Account Only):" -ForegroundColor Cyan
    Write-Host "     Use Email: no@thanks.com  and Password: nothanks" -ForegroundColor White
    Write-Host ""
    Pause-Menu
}

# =============================================================================
# MAIN MENU LOOP
# =============================================================================
Ensure-PackageManagers

while ($true) {
    Show-Header
    Write-Host "  [ MAIN MENU ]" -ForegroundColor Yellow; Write-Host ""
    @(
        @{K="1";L="Install Essential Software"; D="Chrome, Firefox, WinRAR, VLC, Sumatra, AnyDesk, UltraViewer"},
        @{K="2";L="Install MS Office Suite";    D="Office 2021 Pro Plus (auto-download + install)"},
        @{K="3";L="System Activation";          D="Windows & Office Activation (get.activated.win)"},
        @{K="4";L="Update All Software";        D="winget upgrade --all"},
        @{K="5";L="Advanced Toolkit";           D="Chris Titus WinUtil"},
        @{K="6";L="Performance Suite";         D="Unified RAM, CPU & SSD Optimizer Toolkit"},
        @{K="7";L="Office Software";            D="RabbitMQ & ElasticSearch install / repair"},
        @{K="8";L="System Setup";              D="Network info / Hostname / Create user"},
        @{K="9";L="Tailscale VPN";             D="Install / Login / Connect / Status / Remove"},
        @{K="10";L="Blockchain Dev Toolkit";    D="Ganache CLI, Truffle, Geth & Node.js"},
        @{K="11";L="Win 11 Setup & OOBE Bypass";D="BypassNRO & Microsoft Account bypass tips"},
        @{K="0";L="Exit";                       D=""}
    ) | ForEach-Object {
        Write-Host "  [" -NoNewline -ForegroundColor DarkGray
        Write-Host $_.K  -NoNewline -ForegroundColor Cyan
        Write-Host "] "  -NoNewline -ForegroundColor DarkGray
        Write-Host $_.L.PadRight(28) -NoNewline -ForegroundColor White
        if ($_.D) { Write-Host " - $($_.D)" -ForegroundColor DarkGray } else { Write-Host "" }
    }
    Write-Host ""; Write-Sep "-"

    $opt = (Read-Host "`n  Enter choice [0-11]").Trim()
    switch ($opt) {
        '1' { Install-NormalSoftware }
        '2' { Install-MSOffice }
        '3' { Invoke-Activation }
        '4' { Update-AllSoftware }
        '5' { Invoke-AdvancedToolkit }
        '6' { Launch-PerformanceSuite }
        '7' { Show-OfficeSoftwareMenu }
        '8' { Show-SystemSetupMenu }
        '9' { Show-TailscaleMenu }
        '10' { Show-BlockchainMenu }
        '11' { Show-Win11BypassMenu }
        '0' { Write-Host "`n  Goodbye!`n" -ForegroundColor Cyan; exit 0 }
        default { Write-WARN "Invalid choice - enter 0-11."; Start-Sleep -Seconds 1 }
    }
}
