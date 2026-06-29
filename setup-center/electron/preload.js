const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('electron', {
  getOS: () => ipcRenderer.invoke('get-os'),
  getMetrics: (callback) => {
    const subscription = (event, data) => callback(data);
    ipcRenderer.on('system-metrics', subscription);
    return () => ipcRenderer.removeListener('system-metrics', subscription);
  },
  runTask: (action, params) => ipcRenderer.invoke('run-task', { action, params }),
  cancelTask: () => ipcRenderer.invoke('cancel-task'),
  onLog: (callback) => {
    const subscription = (event, data) => callback(data);
    ipcRenderer.on('task-log', subscription);
    return () => ipcRenderer.removeListener('task-log', subscription);
  },
  onStatus: (callback) => {
    const subscription = (event, data) => callback(data);
    ipcRenderer.on('task-status', subscription);
    return () => ipcRenderer.removeListener('task-status', subscription);
  },
  getProfiles: () => ipcRenderer.invoke('get-profiles'),
  getConfig: () => ipcRenderer.invoke('get-config'),
  saveConfig: (config) => ipcRenderer.invoke('save-config', config),
});

