import React, { useState, useEffect, useRef } from 'react';

// =========================================================================
// CONSTANTS (SOFTWARE LISTS)
// =========================================================================
const WINDOWS_SOFTWARE = [
  { id: "1", name: "Google Chrome", desc: "Fast & secure web browser" },
  { id: "2", name: "Mozilla Firefox", desc: "Privacy-focused web browser" },
  { id: "3", name: "WinRAR Archiver", desc: "Archive compress & extraction tool" },
  { id: "4", name: "VLC Media Player", desc: "Multi-format open source media player" },
  { id: "5", name: "Sumatra PDF Reader", desc: "Lightweight document viewer" },
  { id: "6", name: "AnyDesk Remote Control", desc: "Desktop screen sharing client" },
  { id: "7", name: "UltraViewer Client", desc: "Helpdesk support connector" }
];

const LINUX_SOFTWARE = [
  { id: "1",  name: "Core Utilities & libfuse2",       desc: "Git, curl, build-essential, unzip, libfuse" },
  { id: "2",  name: "Node.js v15.14.0 (via NVM)",      desc: "LTS javascript runtime environment" },
  { id: "3",  name: "Google Chrome",                   desc: "Web browser (official .deb package)" },
  { id: "4",  name: "Brave Browser",                   desc: "Privacy-focused Chromium-based browser" },
  { id: "5",  name: "Visual Studio Code",              desc: "Microsoft script & code editor" },
  { id: "6",  name: "MySQL Workbench",                 desc: "Database designer & SQL client" },
  { id: "7",  name: "DBeaver Community Edition",       desc: "Universal database client manager (.deb)" },
  { id: "8",  name: "Postman API Platform",            desc: "API developer client (Snap)" },
  { id: "9",  name: "Redis Insight Manager",           desc: "Redis database UI (Snap)" },
  { id: "10", name: "MongoDB Compass Client",          desc: "Official graphical shell for MongoDB" },
  { id: "11", name: "Tailscale VPN Client",            desc: "Secure mesh-net tunnel client" },
  { id: "12", name: "GNOME Tweaks & Extension Manager",desc: "Desktop tweaks + Extension Manager from Store" },
  { id: "13", name: "ClamAV System Antivirus",         desc: "Malware scanner service & daemon" }
];

export default function App() {
  // Navigation & Platform States
  const [activeTab, setActiveTab] = useState('dashboard');
  const [os, setOS] = useState('win32'); // win32, linux
  const [profiles, setProfiles] = useState([]);
  
  // Telemetry & Task Execution States
  const [cpu, setCpu] = useState(0);
  const [ram, setRam] = useState(0);
  const [taskRunning, setTaskRunning] = useState(false);
  const [activeTaskName, setActiveTaskName] = useState('');
  const [logs, setLogs] = useState([]);
  
  // Form Selections
  const [checkedSoftware, setCheckedSoftware] = useState({});
  const [officeMethod, setOfficeMethod] = useState('1'); // 1 = Online, 2 = Offline
  const [installMode, setInstallMode] = useState('online'); // online or offline
  
  // UI Helpers
  const [autoScroll, setAutoScroll] = useState(true);
  const [toast, setToast] = useState('');
  
  const terminalRef = useRef(null);

  // =========================================================================
  // LIFE CYCLE HOOKS
  // =========================================================================
  useEffect(() => {
    // 1. Fetch current Host Operating System
    if (window.electron && window.electron.getOS) {
      window.electron.getOS().then(platform => {
        setOS(platform);
        // Default check all software
        const initialChecks = {};
        const activeList = platform === 'win32' ? WINDOWS_SOFTWARE : LINUX_SOFTWARE;
        activeList.forEach(app => {
          initialChecks[app.id] = true;
        });
        setCheckedSoftware(initialChecks);
      });
    }

    // 2. Fetch Profiles presets
    if (window.electron && window.electron.getProfiles) {
      window.electron.getProfiles().then(data => {
        setProfiles(data);
      });
    }

    // 3. Listen to telemetry stats
    let unsubscribeMetrics = () => {};
    if (window.electron && window.electron.getMetrics) {
      unsubscribeMetrics = window.electron.getMetrics(metrics => {
        setCpu(metrics.cpu);
        setRam(metrics.ram);
      });
    }

    // 4. Listen to stdout logs stream
    let unsubscribeLogs = () => {};
    if (window.electron && window.electron.onLog) {
      unsubscribeLogs = window.electron.onLog(line => {
        appendLog(line);
      });
    }

    // 5. Listen to task running status updates
    let unsubscribeStatus = () => {};
    if (window.electron && window.electron.onStatus) {
      unsubscribeStatus = window.electron.onStatus(status => {
        setTaskRunning(status.running);
        setActiveTaskName(status.taskName);
      });
    }

    return () => {
      unsubscribeMetrics();
      unsubscribeLogs();
      unsubscribeStatus();
    };
  }, []);

  // Auto-scroll handler
  useEffect(() => {
    if (autoScroll && terminalRef.current) {
      terminalRef.current.scrollTop = terminalRef.current.scrollHeight;
    }
  }, [logs, autoScroll]);

  // =========================================================================
  // HELPER UTILITIES
  // =========================================================================
  const showToast = (msg) => {
    setToast(msg);
    setTimeout(() => setToast(''), 4000);
  };

  const appendLog = (text) => {
    const lines = text.split('\n');
    if (lines.length > 1 && lines[lines.length - 1] === '') {
      lines.pop();
    }
    
    setLogs(prev => {
      const newLines = lines.map(line => {
        if (!line && line !== '') return null;
        let type = 'normal';
        const cleaned = line.replace(/\r/g, '');
        
        if (cleaned.startsWith('[SYSTEM]')) type = 'system';
        else if (cleaned.includes('✅') || cleaned.includes('SUCCESS')) type = 'success';
        else if (cleaned.includes('⚠️') || cleaned.includes('Warning')) type = 'warning';
        else if (cleaned.includes('❌') || cleaned.includes('Error') || cleaned.includes('Failed')) type = 'error';
        else if (cleaned.includes('⏬') || cleaned.includes('Downloading') || cleaned.includes('Installing') || cleaned.startsWith('[RUNNING')) type = 'info';
        else if (cleaned.startsWith('  >>') || cleaned.includes('⏳')) type = 'verbose';

        return { text: cleaned, type };
      }).filter(l => l !== null);
      
      return [...prev, ...newLines];
    });
  };

  const clearLogs = () => {
    setLogs([]);
    showToast("Terminal screen cleared.");
  };

  const toggleScroll = () => {
    setAutoScroll(!autoScroll);
    showToast(autoScroll ? "Auto-scroll disabled." : "Auto-scroll enabled.");
  };

  // =========================================================================
  // ACTIONS / TASK HANDLERS
  // =========================================================================
  const runTask = async (action, params = {}) => {
    if (taskRunning) {
      showToast("A setup process is already active. Please wait.");
      return;
    }
    setLogs([]); // Clear logs before task start
    setActiveTab('logs'); // Redirect to logs screen to see progress
    
    // Inject the global installMode parameter
    const taskParams = {
      ...params,
      offline: installMode === 'offline'
    };

    try {
      if (window.electron && window.electron.runTask) {
        await window.electron.runTask(action, taskParams);
      }
    } catch (err) {
      appendLog(`[SYSTEM] FAILED to spawn automation backend: ${err.message}\n`);
    }
  };

  const cancelTask = async () => {
    if (window.electron && window.electron.cancelTask) {
      await window.electron.cancelTask();
      showToast("Task termination command sent.");
    }
  };

  // Checkboxes
  const handleCheckboxChange = (id) => {
    setCheckedSoftware(prev => ({
      ...prev,
      [id]: !prev[id]
    }));
  };

  const selectAllSoftware = (state) => {
    const list = os === 'win32' ? WINDOWS_SOFTWARE : LINUX_SOFTWARE;
    const next = {};
    list.forEach(app => {
      next[app.id] = state;
    });
    setCheckedSoftware(next);
  };

  const installSelectedSoftware = () => {
    const selected = Object.keys(checkedSoftware).filter(id => checkedSoftware[id]);
    if (selected.length === 0) {
      showToast("Please check at least one application to deploy.");
      return;
    }
    runTask("software", { selections: selected.join(',') });
  };

  const applyProfilePreset = (profile) => {
    const initialChecks = {};
    const list = os === 'win32' ? WINDOWS_SOFTWARE : LINUX_SOFTWARE;
    const targetKeys = os === 'win32' ? profile.windowsSoftware : profile.linuxSoftware;
    
    list.forEach(app => {
      initialChecks[app.id] = targetKeys.includes(app.id);
    });
    setCheckedSoftware(initialChecks);
    setActiveTab('catalog');
    showToast(`Loaded checked software presets from ${profile.name}`);
  };

  // =========================================================================
  // RENDER SECTIONS
  // =========================================================================
  return (
    <div className="app-layout">
      <div className="bg-blobs">
        <div className="blob blob-1"></div>
        <div className="blob blob-2"></div>
      </div>

      {/* SIDEBAR NAVIGATION */}
      <aside className="sidebar">
        <div className="branding">
          <div className="brand-logo">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
              <polygon points="12 2 2 7 12 12 22 7 12 2"></polygon>
              <polyline points="2 17 12 22 22 17"></polyline>
              <polyline points="2 12 12 17 22 12"></polyline>
            </svg>
          </div>
          <span className="brand-title">Setup Center</span>
        </div>

        <div className="mode-selector-card">
          <span className="mode-label">DEPLOYMENT MODE</span>
          <div className="mode-options">
            <button 
              className={`mode-btn ${installMode === 'online' ? 'active' : ''}`}
              onClick={() => {
                setInstallMode('online');
                showToast("ONLINE deployment mode active.");
              }}
              disabled={taskRunning}
              title="Downloads software packages via active internet connection"
            >
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="mode-icon"><path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"></path></svg>
              <span>Online</span>
            </button>
            <button 
              className={`mode-btn ${installMode === 'offline' ? 'active' : ''}`}
              onClick={() => {
                setInstallMode('offline');
                showToast("OFFLINE deployment mode active.");
              }}
              disabled={taskRunning}
              title="Deploys pre-bundled offline zip archives from local storage"
            >
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="mode-icon"><path d="M18.36 6.64a9 9 0 1 1-12.73 0"></path><line x1="12" y1="2" x2="12" y2="12"></line></svg>
              <span>Offline</span>
            </button>
          </div>
        </div>

        <nav className="nav-menu">
          <button className={`nav-item ${activeTab === 'dashboard' ? 'active' : ''}`} onClick={() => setActiveTab('dashboard')}>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><rect x="3" y="3" width="7" height="9"></rect><rect x="14" y="3" width="7" height="5"></rect><rect x="14" y="12" width="7" height="9"></rect><rect x="3" y="16" width="7" height="5"></rect></svg>
            Dashboard
          </button>
          
          <button className={`nav-item ${activeTab === 'catalog' ? 'active' : ''}`} onClick={() => setActiveTab('catalog')}>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"></path><polyline points="3.27 6.96 12 12.01 20.73 6.96"></polyline><line x1="12" y1="22.08" x2="12" y2="12"></line></svg>
            Software Catalog
          </button>

          <button className={`nav-item ${activeTab === 'profiles' ? 'active' : ''}`} onClick={() => setActiveTab('profiles')}>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"></path><circle cx="9" cy="7" r="4"></circle><path d="M23 21v-2a4 4 0 0 0-3-3.87"></path><path d="M16 3.13a4 4 0 0 1 0 7.75"></path></svg>
            Deployment Profiles
          </button>

          {os === 'win32' && (
            <button className={`nav-item ${activeTab === 'utilities' ? 'active' : ''}`} onClick={() => setActiveTab('utilities')}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"></rect><path d="M7 11V7a5 5 0 0 1 10 0v4"></path></svg>
              Activation & Utilities
            </button>
          )}

          <button className={`nav-item ${activeTab === 'dev' ? 'active' : ''}`} onClick={() => setActiveTab('dev')}>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><polyline points="16 18 22 12 16 6"></polyline><polyline points="8 6 2 12 8 18"></polyline></svg>
            Dev Stack
          </button>

          <button className={`nav-item ${activeTab === 'logs' ? 'active' : ''}`} onClick={() => setActiveTab('logs')}>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><polyline points="4 7 4 4 20 4 20 20 4 20 4 17"></polyline><path d="M9 9h6"></path><path d="M9 13h6"></path><path d="M9 17h3"></path></svg>
            Live Terminal Logs
          </button>
        </nav>
      </aside>

      {/* VIEWPORT CONTROLLER */}
      <div className="main-content">
        <header className="app-header">
          <div className="header-title">
            <h2>{activeTab.charAt(0).toUpperCase() + activeTab.slice(1).replace('-', ' ')}</h2>
          </div>
          
          <div className="header-status">
            <div className="stat-badge">
              <div className="stat-info">
                <span class="stat-label">CPU LOAD</span>
                <span className="stat-value">{cpu}%</span>
              </div>
              <div className="stat-progress"><div className="stat-bar" style={{ width: `${cpu}%` }}></div></div>
            </div>
            
            <div className="stat-badge">
              <div className="stat-info">
                <span class="stat-label">RAM USAGE</span>
                <span className="stat-value">{ram}%</span>
              </div>
              <div className="stat-progress"><div className="stat-bar" style={{ width: `${ram}%` }}></div></div>
            </div>
            
            <div className={`status-indicator ${taskRunning ? 'running' : 'idle'}`}>
              <span className="status-dot"></span>
              <span>{taskRunning ? 'Task in progress' : 'System Ready'}</span>
            </div>
          </div>
        </header>

        {/* CONTENT RENDER PANELS */}
        <div className="page-container">
          
          {/* TAB 1: DASHBOARD */}
          {activeTab === 'dashboard' && (
            <div className="preset-grid">
              <div className="card">
                <div className="card-title-row">
                  <div className="card-icon icon-cyan">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><rect x="2" y="2" width="20" height="8" rx="2" ry="2"></rect><rect x="2" y="14" width="20" height="8" rx="2" ry="2"></rect><line x1="6" y1="6" x2="6.01" y2="6"></line><line x1="6" y1="18" x2="6.01" y2="18"></line></svg>
                  </div>
                  <h3>System Inventory</h3>
                </div>
                <p className="card-desc">Local device configuration parameters.</p>
                <div className="sys-list">
                  <div className="sys-row"><span className="sys-key">Operating System</span><span className="sys-val">{os === 'win32' ? 'Windows OS (10/11)' : 'Linux/Ubuntu OS'}</span></div>
                  <div className="sys-row"><span className="sys-key">Architecture</span><span className="sys-val">x86_64</span></div>
                  <div className="sys-row"><span className="sys-key">Host Machine</span><span className="sys-val">Local Provisioned Node</span></div>
                  <div className="sys-row"><span className="sys-key">Provisioning Mode</span><span className="sys-val">{os === 'win32' ? 'Chocolatey & Winget API' : 'Apt & Snap Core'}</span></div>
                </div>
              </div>

              <div className="card">
                <div className="card-title-row">
                  <div className="card-icon icon-green">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><polygon points="5 3 19 12 5 21 5 3"></polygon></svg>
                  </div>
                  <h3>Toolkit Overview</h3>
                </div>
                <p className="card-desc">Welcome to Setup Center desktop automation portal.</p>
                <div className="sys-list" style={{ fontSize: '0.8rem', lineHeight: '1.4', color: 'var(--text-muted)' }}>
                  <p>Choose <strong>Software Catalog</strong> to install custom app bundles silently on this PC.</p>
                  <p>Load <strong>Deployment Profiles</strong> to auto-apply developer workstation templates instantly.</p>
                  <p>Execute diagnostics on <strong>Dev Stack</strong> to set up RabbitMQ servers, ElasticSearch instances, and config Tailscale VPN meshes.</p>
                </div>
              </div>
            </div>
          )}

          {/* TAB 2: SOFTWARE CATALOG */}
          {activeTab === 'catalog' && (
            <div className="page-split-layout">
              <div className="left-panel">
                <section className="card">
                  <div className="card-title-row">
                    <div className="card-icon icon-primary">
                      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"></path></svg>
                    </div>
                    <h3>Silent App Installer</h3>
                  </div>
                  <p className="card-desc">Check the software packages to deploy silently on this machine.</p>

                  {installMode === 'offline' && (
                    <div style={{
                      background: 'rgba(249, 115, 22, 0.1)',
                      border: '1px solid rgba(249, 115, 22, 0.2)',
                      borderRadius: 'var(--radius-md)',
                      padding: '10px 14px',
                      fontSize: '0.78rem',
                      color: 'var(--orange)',
                      display: 'flex',
                      alignItems: 'center',
                      gap: '8px',
                      marginBottom: '16px'
                    }}>
                      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" style={{ width: 16, height: 16, flexShrink: 0 }}><path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"></path><line x1="12" y1="9" x2="12" y2="13"></line><line x1="12" y1="17" x2="12.01" y2="17"></line></svg>
                      <span>Offline mode is active. Package manager installs still require internet. Office suite can be installed fully offline.</span>
                    </div>
                  )}

                  <div className="software-list-grid">
                    {(os === 'win32' ? WINDOWS_SOFTWARE : LINUX_SOFTWARE).map(app => (
                      <label key={app.id} className="software-item">
                        <input type="checkbox" checked={!!checkedSoftware[app.id]} onChange={() => handleCheckboxChange(app.id)} disabled={taskRunning} />
                        <span className="checkbox-custom"></span>
                        <div>
                          <span className="software-name">{app.name}</span>
                        </div>
                      </label>
                    ))}
                  </div>

                  <div className="flex-row">
                    <button className="btn btn-primary" onClick={installSelectedSoftware} disabled={taskRunning}>Install Selected</button>
                    <button className="btn btn-outline" onClick={() => selectAllSoftware(true)} disabled={taskRunning}>All</button>
                    <button className="btn btn-outline" onClick={() => selectAllSoftware(false)} disabled={taskRunning}>None</button>
                  </div>
                </section>

                {os === 'win32' && (
                  <section className="card">
                    <div className="card-title-row">
                      <div className="card-icon icon-orange">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path></svg>
                      </div>
                      <h3>Microsoft Office Suite</h3>
                    </div>
                    <p className="card-desc">Deploy Microsoft Office Pro Plus 2021 Volume License.</p>
                    
                    {installMode === 'offline' ? (
                      <div style={{
                        background: 'rgba(16, 185, 129, 0.1)',
                        border: '1px solid rgba(16, 185, 129, 0.2)',
                        borderRadius: 'var(--radius-md)',
                        padding: '12px 14px',
                        fontSize: '0.8rem',
                        color: 'var(--green)',
                        marginBottom: '20px',
                        display: 'flex',
                        flexDirection: 'column',
                        gap: '6px'
                      }}>
                        <span style={{ fontWeight: '700' }}>📦 Local Installer Bundle Ready</span>
                        <span style={{ color: 'var(--text-muted)', fontSize: '0.74rem' }}>
                          Office Installer 1.33.zip is pre-packaged. Extraction and installation will be executed fully offline.
                        </span>
                      </div>
                    ) : (
                      <div className="radio-list">
                        <label className="radio-item">
                          <input type="radio" name="office" value="1" checked={officeMethod === '1'} onChange={() => setOfficeMethod('1')} disabled={taskRunning} />
                          <span className="radio-custom"></span>
                          <div className="radio-text">
                            <span className="radio-title">Online Installer</span>
                            <span className="radio-desc">Downloads directly from official Office CDN</span>
                          </div>
                        </label>
                        <label className="radio-item">
                          <input type="radio" name="office" value="2" checked={officeMethod === '2'} onChange={() => setOfficeMethod('2')} disabled={taskRunning} />
                          <span className="radio-custom"></span>
                          <div className="radio-text">
                            <span className="radio-title">Create Offline Installer folder</span>
                            <span className="radio-desc">Saves installation pack files directly to disk path</span>
                          </div>
                        </label>
                      </div>
                    )}

                    <button 
                      className="btn btn-primary btn-full" 
                      onClick={() => runTask('office', { choice: installMode === 'offline' ? '1' : officeMethod })} 
                      disabled={taskRunning}
                    >
                      {installMode === 'offline' ? 'Install Office Offline' : 'Install Office'}
                    </button>
                  </section>
                )}
              </div>

              {/* QUICK LOG SIDEBAR */}
              <div className="terminal-card" style={{ height: 'calc(100vh - 200px)', minHeight: 'auto' }}>
                <div className="terminal-header">
                  <div className="window-dots"><span className="dot dot-1"></span><span className="dot dot-2"></span><span className="dot dot-3"></span></div>
                  <span className="terminal-title">quick_monitor.log</span>
                </div>
                <div className="terminal-body" style={{ fontSize: '0.75rem' }}>
                  {logs.slice(-30).map((l, i) => (
                    <div key={i} className={`term-line term-${l.type}`}>{l.text}</div>
                  ))}
                  {logs.length === 0 && <div className="term-line term-verbose">No active logs. Start a task to monitor progress here.</div>}
                </div>
              </div>
            </div>
          )}

          {/* TAB 3: PROFILES */}
          {activeTab === 'profiles' && (
            <div className="preset-grid">
              {profiles.map(profile => (
                <div key={profile.id} className="preset-card">
                  <span className="preset-title">{profile.name}</span>
                  <p className="preset-desc">{profile.description}</p>
                  <button className="btn btn-primary btn-sm" onClick={() => applyProfilePreset(profile)} disabled={taskRunning}>Apply Preset</button>
                </div>
              ))}
              {profiles.length === 0 && (
                <div className="card btn-full" style={{ gridColumn: '1/-1', textAlign: 'center' }}>
                  <p style={{ color: 'var(--text-muted)' }}>No pre-configured presets found in profiles folder.</p>
                </div>
              )}
            </div>
          )}

          {/* TAB 4: UTILITIES */}
          {activeTab === 'utilities' && os === 'win32' && (
            <div className="preset-grid">
              <section className="card">
                <div className="card-title-row">
                  <div className="card-icon icon-green">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"></rect><path d="M7 11V7a5 5 0 0 1 10 0v4"></path></svg>
                  </div>
                  <h3>System Activation</h3>
                </div>
                <p className="card-desc">Execute system registry triggers to activate Windows and MS Office.</p>
                <button className="btn btn-green btn-full" onClick={() => runTask('activate')} disabled={taskRunning}>Run Activation</button>
              </section>

              <section class="card">
                <div className="card-title-row">
                  <div className="card-icon icon-purple">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="23 4 23 10 17 10"></polyline><polyline points="1 20 1 14 7 14"></polyline><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"></path></svg>
                  </div>
                  <h3>System Package Updates</h3>
                </div>
                <p className="card-desc">Runs updates against all installed third party software packages using winget.</p>
                <button className="btn btn-purple btn-full" onClick={() => runTask('update')} disabled={taskRunning}>Upgrade Software Packages</button>
              </section>

              <section className="card">
                <div className="card-title-row">
                  <div className="card-icon icon-cyan">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3"></circle><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"></path></svg>
                  </div>
                  <h3>Advanced WinUtil Toolkit</h3>
                </div>
                <p className="card-desc">Execute the custom WinUtil configuration tool by Chris Titus Tech.</p>
                <button className="btn btn-cyan btn-full" onClick={() => runTask('winutil')} disabled={taskRunning}>Launch WinUtil</button>
              </section>

              <section className="card">
                <div className="card-title-row">
                  <div className="card-icon icon-amber">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="2" width="20" height="8" rx="2" ry="2"></rect><rect x="2" y="14" width="20" height="8" rx="2" ry="2"></rect></svg>
                  </div>
                  <h3>Smart RAM Optimizer</h3>
                </div>
                <p className="card-desc">Global smart optimizer to trim process memory footprints.</p>
                <div style={{ display: 'flex', flexDirection: 'column', gap: '8px' }}>
                  <button className="btn btn-amber btn-sm" onClick={() => runTask('ramopt', { mode: '1' })} disabled={taskRunning}>Run Optimizer (Test Mode)</button>
                  <button className="btn btn-outline btn-sm" onClick={() => runTask('ramopt', { mode: '2' })} disabled={taskRunning}>Install Permanent (Silent)</button>
                  <button className="btn btn-danger-outline btn-sm" onClick={() => runTask('ramopt', { mode: '3' })} disabled={taskRunning}>Remove RAM Optimizer</button>
                </div>
              </section>
            </div>
          )}

          {/* TAB 5: DEV STACK */}
          {activeTab === 'dev' && (
            <section className="card">
              <div className="card-title-row">
                <div className="card-icon icon-purple">
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="16 18 22 12 16 6"></polyline><polyline points="8 6 2 12 8 18"></polyline></svg>
                </div>
                <h3>Developer Services Deployment</h3>
              </div>
              <p className="card-desc">Provision server databases, brokers, and VPN routers for internal workstations.</p>
              
              {os === 'win32' ? (
                <div className="dev-list">
                  <div className="dev-row">
                    <span className="dev-row-title">RabbitMQ Server & Erlang Stack</span>
                    <div className="dev-row-btns">
                      <button className="btn btn-primary btn-sm" onClick={() => runTask('dev', { mode: '1', label: 'Install RabbitMQ' })} disabled={taskRunning}>Install</button>
                      <button className="btn btn-outline btn-sm" onClick={() => runTask('dev', { mode: '3', label: 'Check RabbitMQ Status' })} disabled={taskRunning}>Status</button>
                      <button className="btn btn-danger-outline btn-sm" onClick={() => runTask('dev', { mode: '4', label: 'Repair RabbitMQ' })} disabled={taskRunning}>Repair</button>
                    </div>
                  </div>
                  <div className="dev-row">
                    <span className="dev-row-title">ElasticSearch 8.11.1 Engine</span>
                    <div className="dev-row-btns">
                      <button className="btn btn-primary btn-sm" onClick={() => runTask('dev', { mode: '2', label: 'Install ElasticSearch' })} disabled={taskRunning}>Install</button>
                      <button className="btn btn-danger-outline btn-sm" onClick={() => runTask('dev', { mode: '5', label: 'Repair ElasticSearch' })} disabled={taskRunning}>Repair</button>
                    </div>
                  </div>
                </div>
              ) : (
                <div className="dev-list">
                  <div className="dev-row">
                    <span className="dev-row-title">Tailscale VPN Services</span>
                    <div className="dev-row-btns">
                      <button className="btn btn-primary btn-sm" onClick={() => runTask('dev', { mode: '1', label: 'Install Tailscale' })} disabled={taskRunning}>Install</button>
                      <button className="btn btn-outline btn-sm" onClick={() => runTask('dev', { mode: '6', label: 'Run Diagnostics' })} disabled={taskRunning}>Diagnostics</button>
                      <button className="btn btn-outline btn-sm" onClick={() => runTask('dev', { mode: '2', label: 'Tailscale Login' })} disabled={taskRunning}>Login</button>
                      <button className="btn btn-outline btn-sm" onClick={() => runTask('dev', { mode: '3', label: 'Tailscale Up' })} disabled={taskRunning}>Up</button>
                      <button className="btn btn-danger-outline btn-sm" onClick={() => runTask('dev', { mode: '7', label: 'Uninstall Tailscale' })} disabled={taskRunning}>Uninstall</button>
                    </div>
                  </div>
                </div>
              )}
            </section>
          )}

          {/* TAB 6: LOGS SCREEN */}
          {activeTab === 'logs' && (
            <div className="terminal-card">
              <div className="terminal-header">
                <div className="window-dots"><span className="dot dot-1"></span><span className="dot dot-2"></span><span className="dot dot-3"></span></div>
                <span className="terminal-title">provision_session.log</span>
                <div className="terminal-actions">
                  <button className="term-btn" onClick={clearLogs} title="Clear Terminal Log">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><polyline points="3 6 5 6 21 6"></polyline><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path></svg>
                  </button>
                  <button className={`term-btn ${autoScroll ? 'active' : ''}`} onClick={toggleScroll} title="Toggle Auto-Scroll">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><line x1="12" y1="5" x2="12" y2="19"></line><polyline points="19 12 12 19 5 12"></polyline></svg>
                  </button>
                </div>
              </div>

              <div className="terminal-body" ref={terminalRef}>
                {logs.map((l, i) => (
                  <div key={i} className={`term-line term-${l.type}`}>{l.text}</div>
                ))}
                {logs.length === 0 && <div className="term-line term-verbose">Ready. Launch an action trigger to view execution log output streams.</div>}
              </div>

              {taskRunning && (
                <div className="terminal-footer">
                  <div className="running-tag">
                    <span className="pulse"></span>
                    <span>Running: {activeTaskName}</span>
                  </div>
                  <button className="btn btn-danger btn-sm" onClick={cancelTask}>Cancel Task</button>
                </div>
              )}
            </div>
          )}

        </div>
      </div>

      {/* TOAST MESSAGE */}
      <div className={`toast-msg ${toast ? 'visible' : ''}`}>{toast}</div>
    </div>
  );
}
