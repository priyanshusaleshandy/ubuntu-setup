# download-offline-installers.ps1
# Helper script to download standalone offline installers for large apps
# Supports downloading from standard web links or direct Google Drive File IDs

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("Web", "GDrive")]
    [string]$Source = "Web"
)

$destDir = Join-Path $PSScriptRoot "offline-installers"
if (-not (Test-Path $destDir)) {
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
}

# Standalone offline installer configurations
# Edit the GDriveID values with your own File IDs once uploaded to your folder!
$installers = @(
    @{ 
        Name = "Google Chrome"
        File = "google-chrome-stable.msi"
        WebURL = "https://dl.google.com/enterprise/installers/ChromeStandaloneSetup64.msi"
        GDriveID = "YOUR_CHROME_FILE_ID"
    },
    @{ 
        Name = "Brave Browser"
        File = "brave-browser-standalone.exe"
        WebURL = "https://laptop-updates.brave.com/latest/winx64"
        GDriveID = "YOUR_BRAVE_FILE_ID"
    },
    @{ 
        Name = "Visual Studio Code"
        File = "vscode-setup.exe"
        WebURL = "https://code.visualstudio.com/sha/download?build=stable&os=win32-x64-user"
        GDriveID = "YOUR_VSCODE_FILE_ID"
    },
    @{ 
        Name = "DBeaver Community Edition"
        File = "dbeaver-setup.exe"
        WebURL = "https://dbeaver.io/files/dbeaver-ce-latest-x86_64-setup.exe"
        GDriveID = "YOUR_DBEAVER_FILE_ID"
    },
    @{ 
        Name = "Postman"
        File = "postman-setup.exe"
        WebURL = "https://dl.pstmn.io/download/latest/win64"
        GDriveID = "YOUR_POSTMAN_FILE_ID"
    },
    @{ 
        Name = "MongoDB Compass"
        File = "mongodb-compass-setup.exe"
        WebURL = "https://downloads.mongodb.com/compass/mongodb-compass-1.43.0-win32-x64.exe"
        GDriveID = "YOUR_MONGODB_FILE_ID"
    },
    @{ 
        Name = "MySQL Workbench"
        File = "mysql-workbench.msi"
        WebURL = "https://dev.mysql.com/get/Downloads/MySQLGUITools/mysql-workbench-community-8.0.36-winx64.msi"
        GDriveID = "YOUR_MYSQL_FILE_ID"
    },
    @{ 
        Name = "Redis Insight"
        File = "redisinsight-setup.msi"
        WebURL = "https://download.redisinsight.redis.com/latest/RedisInsight-v2-win-x64.msi"
        GDriveID = "YOUR_REDIS_FILE_ID"
    }
)

function Get-GoogleDriveFile {
    param(
        [string]$FileId,
        [string]$OutputPath
    )
    $url = "https://docs.google.com/uc?export=download&id=$FileId"
    
    # Establish session
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    
    try {
        # Check if there is a virus scan warning/confirmation page
        $req = Invoke-WebRequest -Uri $url -WebSession $session -MaximumRedirection 0 -ErrorAction SilentlyContinue
        $downloadUrl = $url
        if ($req.Headers.Location -match "confirm=([a-zA-Z0-9_]+)") {
            $confirm = $matches[1]
            $downloadUrl = "https://docs.google.com/uc?export=download&confirm=$confirm&id=$FileId"
        }
        
        # Download the file
        Invoke-WebRequest -Uri $downloadUrl -WebSession $session -OutFile $OutputPath -TimeoutSec 300
        return $true
    } catch {
        Write-Error "Google Drive download failed for file ID $FileId : $_"
        return $false
    }
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "      OFFINE INSTALLERS DOWNLOADER        " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Source Option: $Source" -ForegroundColor Gray
Write-Host "Destination  : $destDir" -ForegroundColor Gray
Write-Host ""

$ProgressPreference = 'SilentlyContinue'

foreach ($item in $installers) {
    $filePath = Join-Path $destDir $item.File
    Write-Host "[*] Downloading $($item.Name) -> $($item.File)..." -ForegroundColor Yellow
    
    if ($Source -eq "GDrive") {
        if ($item.GDriveID -eq "YOUR_CHROME_FILE_ID" -or $item.GDriveID -like "YOUR_*") {
            Write-Host "    [!] Skipped: Google Drive File ID is not set for $($item.Name)." -ForegroundColor Red
            continue
        }
        $success = Get-GoogleDriveFile -FileId $item.GDriveID -OutputPath $filePath
    } else {
        try {
            Invoke-WebRequest -Uri $item.WebURL -OutFile $filePath -ErrorAction Stop -TimeoutSec 300
            $success = $true
        } catch {
            Write-Host "    [!] Error downloading $($item.Name) from standard web link: $_" -ForegroundColor Red
            $success = $false
        }
    }
    
    if ($success) {
        Write-Host "    [+] Success: $($item.Name) is ready." -ForegroundColor Green
    } else {
        Write-Host "    [-] Failed to download $($item.Name)." -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Downloads completed!" -ForegroundColor Green