// Subconscious extension entry point. popup.html and sidepanel.html both load
// this module; they differ only in <body data-mode="popup|panel">.
// The UI lives in ./ui/*.js (see README.md).
import { applyStoredConfig, startup } from './ui/connection.js';
import { mountShell } from './ui/shell.js';
import { STORAGE_KEY, state } from './ui/state.js';

mountShell(document.getElementById('root'));

// Keep a popup and a side panel open at the same time in sync.
chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== 'local' || !changes[STORAGE_KEY]) return;
  const next = changes[STORAGE_KEY].newValue || {};
  if (next.url === state.config.url && next.token === state.config.token) return;
  applyStoredConfig(next);
});

startup().catch((error) => console.error('Subconscious startup failed', error));
