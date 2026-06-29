// electron/main.js
const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('path');
const fs = require('fs');
const { spawn, exec } = require('child_process');
const os = require('os');

let mainWindow = null;
let activeChildProcess = null;
let telemetryInterval = null;

// Fix GPU process crash (exit code 0xC0000135 - missing DLL) on Windows
// Must be called before app.whenReady() to prevent GPU process from spawning
app.disableHardwareAcceleration();
app.commandLine.appendSwitch('no-sandbox');
app.commandLine.appendSwitch('disable-gpu');
app.commandLine.appendSwitch('disable-gpu-sandbox');
app.commandLine.appendSwitch('in-process-gpu');

const baseResourcesPath = app.isPackaged 
  ? process.resourcesPath 
  : path.join(__dirname, '../..');

// Ensure temp directory exists
const tempDir = path.join(os.tmpdir(), 'setup-center');
if (!fs.existsSync(tempDir)) {
  fs.mkdirSync(tempDir, { recursive: true });
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 850,
    minWidth: 1000,
    minHeight: 700,
    title: "Setup Center",
    backgroundColor: '#0b0f19',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: true
    }
  });

  // Load production build or fallback to source directory index.html
  const distPath = path.join(__dirname, '../frontend/dist/index.html');
  if (fs.existsSync(distPath)) {
    mainWindow.loadFile(distPath);
  } else {
    mainWindow.loadFile(path.join(__dirname, '../frontend/index.html'));
  }

  mainWindow.on('closed', () => {
    mainWindow = null;
    cleanup();
  });

  // Start system telemetry broadcast
  startTelemetry();
}

app.whenReady().then(() => {
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

function cleanup() {
  if (telemetryInterval) {
    clearInterval(telemetryInterval);
    telemetryInterval = null;
  }
  if (activeChildProcess) {
    try {
      activeChildProcess.kill();
    } catch (e) {}
    activeChildProcess = null;
  }
}

// =========================================================================
// SYSTEM TELEMETRY
// =========================================================================
let telemetryBusy = false;

function startTelemetry() {
  telemetryInterval = setInterval(() => {
    if (!mainWindow || telemetryBusy) return;
    telemetryBusy = true;

    if (process.platform === 'win32') {
      // Use wmic — much faster than spawning powershell + CimInstance every tick
      exec('wmic cpu get LoadPercentage /value & wmic OS get FreePhysicalMemory,TotalVisibleMemorySize /value', { timeout: 4000 }, (err, stdout) => {
        telemetryBusy = false;
        if (err || !stdout || !mainWindow) return;
        let cpu = 0, ram = 0;
        const cpuMatch = stdout.match(/LoadPercentage=(\d+)/);
        const freeMatch = stdout.match(/FreePhysicalMemory=(\d+)/);
        const totalMatch = stdout.match(/TotalVisibleMemorySize=(\d+)/);
        if (cpuMatch) cpu = parseInt(cpuMatch[1]) || 0;
        if (freeMatch && totalMatch) {
          const free = parseInt(freeMatch[1]);
          const total = parseInt(totalMatch[1]);
          if (total > 0) ram = Math.round(((total - free) / total) * 100);
        }
        mainWindow.webContents.send('system-metrics', { cpu, ram });
      });
    } else {
      // Query stats on Linux
      exec("free | grep Mem | awk '{print $3/$2 * 100.0}'", { timeout: 4000 }, (err, ramStdout) => {
        let ram = 0;
        if (!err && ramStdout) {
          ram = Math.round(parseFloat(ramStdout)) || 0;
        }
        exec("top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\\([0-9.]*\\)%* id.*/\\1/' | awk '{print 100 - $1}'", { timeout: 4000 }, (err, cpuStdout) => {
          telemetryBusy = false;
          let cpu = 0;
          if (!err && cpuStdout) {
            cpu = Math.round(parseFloat(cpuStdout)) || 0;
          }
          if (mainWindow) mainWindow.webContents.send('system-metrics', { cpu, ram });
        });
      });
    }
  }, 5000); // 5s interval — avoids overlapping wmic/ps queries
}

// =========================================================================
// IPC HANDLERS
// =========================================================================

ipcMain.handle('get-os', () => {
  return process.platform; // 'win32' or 'linux'
});

ipcMain.handle('get-profiles', () => {
  const profilesDir = path.join(__dirname, '../profiles');
  if (!fs.existsSync(profilesDir)) {
    return [];
  }
  const files = fs.readdirSync(profilesDir);
  const profiles = [];
  files.forEach(file => {
    if (file.endsWith('.json')) {
      try {
        const filePath = path.join(profilesDir, file);
        const data = JSON.parse(fs.readFileSync(filePath, 'utf8'));
        profiles.push(data);
      } catch (err) {
        console.error(`Error loading profile ${file}:`, err);
      }
    }
  });
  return profiles;
});

// Config: save/load repo URL from userData
const configPath = path.join(app.getPath('userData'), 'setup-center-config.json');

ipcMain.handle('get-config', () => {
  try {
    if (fs.existsSync(configPath)) {
      return JSON.parse(fs.readFileSync(configPath, 'utf8'));
    }
  } catch (e) {}
  return { repoUrl: '' };
});

ipcMain.handle('save-config', (event, config) => {
  try {
    fs.writeFileSync(configPath, JSON.stringify(config, null, 2), 'utf8');
    return { ok: true };
  } catch (e) {
    return { ok: false, error: e.message };
  }
});

ipcMain.handle('cancel-task', () => {
  if (activeChildProcess) {
    try {
      activeChildProcess.kill();
      mainWindow.webContents.send('task-log', "\n⚠️ Task cancelled by user (Process terminated).\n");
    } catch (err) {}
    activeChildProcess = null;
    mainWindow.webContents.send('task-status', { running: false, taskName: '' });
  }
  return { status: 'cancelled' };
});

ipcMain.handle('run-task', async (event, { action, params }) => {
  if (activeChildProcess) {
    return { error: 'A task is already running' };
  }

  mainWindow.webContents.send('task-status', { running: true, taskName: action.toUpperCase() });
  mainWindow.webContents.send('task-log', `[SYSTEM] Scaffolding automation environment for ${action.toUpperCase()}...\n`);

  if (process.platform === 'win32') {
    // =========================================================================
    // WINDOWS EXECUTION PATH
    // =========================================================================
    const originalScript = path.join(baseResourcesPath, 'windows/my-choco-install-script/setup-new-pc.ps1');
    if (!fs.existsSync(originalScript)) {
      mainWindow.webContents.send('task-log', `❌ Error: Setup script not found at ${originalScript}\n`);
      mainWindow.webContents.send('task-status', { running: false, taskName: '' });
      return { error: 'Script not found' };
    }

    try {
      const scriptBuffer = fs.readFileSync(originalScript);
      let scriptText = "";
      if (scriptBuffer[0] === 0xFF && scriptBuffer[1] === 0xFE) {
        scriptText = scriptBuffer.toString('utf16le');
      } else if (scriptBuffer[0] === 0xFE && scriptBuffer[1] === 0xFF) {
        scriptText = scriptBuffer.toString('utf16be');
      } else {
        // Check for null bytes to detect UTF-16 without BOM
        let hasNulls = false;
        for (let i = 0; i < Math.min(scriptBuffer.length, 1000); i++) {
          if (scriptBuffer[i] === 0x00) {
            hasNulls = true;
            break;
          }
        }
        if (hasNulls) {
          scriptText = scriptBuffer.toString('utf16le');
        } else {
          scriptText = scriptBuffer.toString('utf8');
        }
      }
      // Strip BOM character if present after decode
      if (scriptText.charCodeAt(0) === 0xFEFF) {
        scriptText = scriptText.slice(1);
      }
      // Remove any embedded null bytes that may still be present
      scriptText = scriptText.replace(/\x00/g, '');
      
      // Strip trailing main menu do-while loop
      const mainProgramIndex = scriptText.indexOf('# Main program');
      if (mainProgramIndex >= 0) {
        scriptText = scriptText.substring(0, mainProgramIndex);
      }

      // Configure overrides and action commands
      let inputQueue = [];
      let startCmd = "";
      let taskName = "";

      switch (action) {
        case "software":
          inputQueue.push(params.selections);
          inputQueue.push(""); // return trigger
          startCmd = "Install-NormalSoftware";
          taskName = "Installing Essential Software";
          break;
        case "office":
          inputQueue.push(""); // return trigger
          startCmd = "Install-MSOffice";
          taskName = "Installing MS Office";
          break;
        case "activate":
          inputQueue.push("");
          startCmd = "Invoke-Activation";
          taskName = "System Activation";
          break;
        case "update":
          inputQueue.push("");
          startCmd = "Update-AllSoftware";
          taskName = "Software Updates";
          break;
        case "winutil":
          inputQueue.push("");
          startCmd = "Invoke-AdvancedToolkit";
          taskName = "Chris Titus WinUtil";
          break;
        case "ramopt":
          inputQueue.push(params.mode);
          inputQueue.push("");
          startCmd = "Launch-GlobalOptimizer";
          taskName = "RAM Optimizer Setup";
          break;
        case "dev":
          inputQueue.push(params.mode);
          inputQueue.push("");
          startCmd = "Install-OfficeSoftwareMenu";
          taskName = `Dev Stack: ${params.label}`;
          break;
        case "syssetup":
          if (params.mode === 'netinfo') {
            startCmd = "Get-NetworkInfo";
            taskName = "Network Information";
          } else if (params.mode === 'hostname') {
            inputQueue.push(params.hostname);
            inputQueue.push("");
            startCmd = "Set-PCHostname";
            taskName = "Change PC Hostname";
          } else if (params.mode === 'createuser') {
            inputQueue.push(params.username);
            inputQueue.push("");
            startCmd = "New-WorkUser";
            taskName = "Create Work User";
          }
          break;
      }

      mainWindow.webContents.send('task-status', { running: true, taskName });

      const isOffline = !!(params && params.offline);
      const resPathEscaped = baseResourcesPath.replace(/\\/g, '\\\\');

      // Load repo URL from saved config
      let repoUrl = '';
      try {
        if (fs.existsSync(configPath)) {
          const cfg = JSON.parse(fs.readFileSync(configPath, 'utf8'));
          repoUrl = (cfg.repoUrl || '').trim().replace(/\/+$/, '').replace(/\\/g, '\\\\');
        }
      } catch (e) {}

      // Generate helper input overrides code
      const inputsStr = inputQueue.map(i => `"${i.replace(/"/g, '`"')}"`).join(', ');
      
      const overrideCode = `
$syncInputs = [System.Collections.Generic.List[string]]::new()
$syncInputs.AddRange([string[]]@(${inputsStr}))
$baseResourcesPath = "${resPathEscaped}"
$isOffline = ${isOffline ? '$true' : '$false'}
$softwareRepoUrl = "${repoUrl}"

# Redefine Write-Host to stream out to standard output immediately
function Write-Host {
    param(
        [Parameter(ValueFromRemainingArguments)]
        $Object,
        [Switch]$NoNewline,
        $ForegroundColor,
        $BackgroundColor
    )
    # Output to stdout stream
    [Console]::WriteLine("$Object")
}

# Redefine Read-Host to pop from inputs queue
function Read-Host {
    param($Prompt)
    if ($syncInputs.Count -gt 0) {
        $val = $syncInputs[0]
        $syncInputs.RemoveAt(0)
        [Console]::WriteLine("   >> [AUTO-INPUT]: $val")
        return $val
    }
    return ""
}

# Redefine Invoke-WebRequest to intercept downloads in offline mode
function Invoke-WebRequest {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Uri,
        [Parameter(Mandatory=$true)]
        [string]$OutFile,
        [switch]$UseBasicParsing,
        $ErrorAction
    )
    
    # Check if we are doing offline install of Office zip
    if ($isOffline -and ($Uri -like "*Office%20Installer%201.33.zip*" -or $Uri -like "*OfficeInstaller.zip*")) {
        [Console]::WriteLine("[OFFLINE DETECTED] Intercepting network request for Office Installer zip...")
        $localZip = Join-Path "$baseResourcesPath" "windows/my-choco-install-script/Office Installer 1.33.zip"
        if (Test-Path $localZip) {
            [Console]::WriteLine("[OFFLINE] Copying local pre-bundled Office zip archive to: $OutFile")
            Copy-Item -Path $localZip -Destination $OutFile -Force
            [Console]::WriteLine("✅ [OFFLINE] File copy completed successfully.")
            return
        } else {
            [Console]::WriteLine("❌ [OFFLINE] Error: Local pre-bundled Office zip not found at: $localZip")
            [Console]::WriteLine("⚠️ [OFFLINE] Falling back to remote network download...")
        }
    }
    
    # Fallback to standard network request
    Microsoft.PowerShell.Utility\\Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing:$UseBasicParsing -ErrorAction:$ErrorAction
}

# Redefine Start-Process to stream silent installers outputs
function Start-Process {
    param(
        [string]$FilePath,
        $ArgumentList,
        [string]$WorkingDirectory,
        [switch]$Wait,
        [switch]$NoNewWindow,
        $ErrorAction,
        $Verb
    )
    if ($NoNewWindow -or $FilePath -eq "winget" -or $FilePath -like "*setup.exe" -or $FilePath -like "*.bat" -or $FilePath -eq "choco") {
        [Console]::WriteLine("[RUNNING PROCESS] $FilePath $([string]::Join(' ', $ArgumentList))")
        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = $FilePath
        $pinfo.Arguments = [string]::Join(" ", $ArgumentList)
        if ($WorkingDirectory) { $pinfo.WorkingDirectory = $WorkingDirectory }
        $pinfo.RedirectStandardOutput = $true
        $pinfo.RedirectStandardError = $true
        $pinfo.UseShellExecute = $false
        $pinfo.CreateNoWindow = $true
        
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $pinfo
        $process.Start() | Out-Null
        
        while (-not $process.HasExited) {
            $line = $process.StandardOutput.ReadLine()
            if ($line) { [Console]::WriteLine($line) }
            $err = $process.StandardError.ReadLine()
            if ($err) { [Console]::WriteLine("⚠️ $err") }
            Start-Sleep -Milliseconds 50
        }
        $rem = $process.StandardOutput.ReadToEnd()
        if ($rem) { [Console]::WriteLine($rem) }
        $process.WaitForExit()
    } else {
        [Console]::WriteLine("[LAUNCHING WINDOW] $FilePath")
        Microsoft.PowerShell.Management\\Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -Wait:$Wait -Verb:$Verb
    }
}
`;

      const finalScript = overrideCode + "\n\n" + scriptText + "\n\n" + `Ensure-PackageManagers\n` + startCmd + "\n";
      const tempScriptPath = path.join(tempDir, 'runner.ps1');
      // Write with UTF-8 BOM so PowerShell parses it cleanly
      const bom = Buffer.from([0xEF, 0xBB, 0xBF]);
      const scriptBytes = Buffer.from(finalScript, 'utf8');
      fs.writeFileSync(tempScriptPath, Buffer.concat([bom, scriptBytes]));

      // Spawn PowerShell child process
      activeChildProcess = spawn('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', tempScriptPath
      ]);

    } catch (err) {
      mainWindow.webContents.send('task-log', `❌ Error preparing script: ${err.message}\n`);
      mainWindow.webContents.send('task-status', { running: false, taskName: '' });
      return { error: err.message };
    }

  } else {
    // =========================================================================
    // LINUX EXECUTION PATH
    // =========================================================================
    const originalScript = path.join(baseResourcesPath, 'install.sh');
    if (!fs.existsSync(originalScript)) {
      mainWindow.webContents.send('task-log', `❌ Error: Setup script not found at ${originalScript}\n`);
      mainWindow.webContents.send('task-status', { running: false, taskName: '' });
      return { error: 'Script not found' };
    }

    try {
      let scriptText = fs.readFileSync(originalScript, 'utf8');
      
      // Strip interactive console main loop at the bottom
      const mainLoopIndex = scriptText.indexOf('# --- Interactive Main Console Loop ---');
      if (mainLoopIndex >= 0) {
        scriptText = scriptText.substring(0, mainLoopIndex);
      }

      // Configure targets to run
      let startCmd = "";
      let taskName = "";

      switch (action) {
        case "software":
          // selections is a comma separated string of index numbers, e.g. "1,4"
          // In Bash script, SELECTIONS is an array of 0s and 1s: SELECTIONS=(1 1 0 1...)
          // We can configure the SELECTIONS array dynamically
          const indices = params.selections.split(',').map(n => parseInt(n) - 1);
          let selectionsArr = Array(13).fill(0);
          indices.forEach(idx => {
            if (idx >= 0 && idx < 13) selectionsArr[idx] = 1;
          });
          startCmd = `
SELECTIONS=(${selectionsArr.join(' ')})
run_installation
`;
          taskName = "Installing Selected Software (Apt/Snap)";
          break;
        case "office":
          // Linux does not support MS Office installation
          startCmd = 'log_error "MS Office installation is only supported on Windows OS."';
          taskName = "Installing MS Office";
          break;
        case "activate":
          startCmd = 'log_error "Activation is only supported on Windows OS."';
          taskName = "System Activation";
          break;
        case "update":
          // Run system check or upgrade packages
          startCmd = 'log_info "Upgrading software packages..." && sudo apt-get update -y && sudo apt-get upgrade -y';
          taskName = "Software Updates";
          break;
        case "winutil":
          startCmd = 'log_error "WinUtil is only supported on Windows OS."';
          taskName = "Chris Titus WinUtil";
          break;
        case "ramopt":
          startCmd = 'log_error "RAM Optimizer is only supported on Windows OS."';
          taskName = "RAM Optimizer Setup";
          break;
        case "dev":
          // Trigger Tailscale console options
          const mode = params.mode;
          if (mode === "6") {
            startCmd = "diagnose_tailscale";
          } else if (mode === "1") {
            startCmd = "install_tailscale";
          } else if (mode === "2") {
            startCmd = "sudo tailscale login --login-server https://bifrost.saleshandy.com";
          } else if (mode === "3") {
            startCmd = "sudo tailscale up --accept-routes --login-server=https://bifrost.saleshandy.com";
          } else if (mode === "4") {
            startCmd = "sudo tailscale up --login-server=https://bifrost.saleshandy.com --reset --accept-dns --accept-routes";
          } else if (mode === "5") {
            startCmd = "sudo tailscale up --login-server=https://bifrost.saleshandy.com --accept-dns --accept-routes --exit-node=100.64.0.7";
          } else if (mode === "7") {
            startCmd = "uninstall_tailscale";
          }
          taskName = `Dev Stack: Tailscale VPN (${params.label})`;
          break;
      }

      mainWindow.webContents.send('task-status', { running: true, taskName });

      // Generate temporary bash script
      const finalScript = `#!/usr/bin/env bash\n\n${scriptText}\n\n${startCmd}\n`;
      const tempScriptPath = path.join(tempDir, 'runner.sh');
      fs.writeFileSync(tempScriptPath, finalScript, 'utf8');
      fs.chmodSync(tempScriptPath, '755');

      // Spawn bash process (passes password check, etc.)
      activeChildProcess = spawn('bash', [tempScriptPath]);

    } catch (err) {
      mainWindow.webContents.send('task-log', `❌ Error preparing script: ${err.message}\n`);
      mainWindow.webContents.send('task-status', { running: false, taskName: '' });
      return { error: err.message };
    }
  }

  // Handle Standard Output and Standard Error streams
  activeChildProcess.stdout.on('data', (data) => {
    if (mainWindow) {
      mainWindow.webContents.send('task-log', data.toString());
    }
  });

  activeChildProcess.stderr.on('data', (data) => {
    if (mainWindow) {
      mainWindow.webContents.send('task-log', data.toString());
    }
  });

  activeChildProcess.on('close', (code) => {
    activeChildProcess = null;
    if (mainWindow) {
      mainWindow.webContents.send('task-log', `\n[SYSTEM] Execution finished (Exit Code: ${code}).\n`);
      mainWindow.webContents.send('task-status', { running: false, taskName: '' });
    }
  });

  return { status: 'started' };
});
