// Shared UI state with a minimal event bus. Modules read `state` directly and
// call `set()` / `emit()` to tell the rest of the UI something changed.

export const CLIENT_TYPE = 'browser_extension';
export const CLIENT_NAME = 'Chromium extension';
export const MODE = document.body.dataset.mode === 'panel' ? 'panel' : 'popup';

export const STORAGE_KEY = 'subconsciousConnection';
export const SERVER_KEY = 'subconsciousServer';

/** Environment presets. The dev token is the public constant of development engines. */
export const ENVIRONMENTS = {
  production: { label: 'Production', engineUrl: 'http://127.0.0.1:51516', serverUrl: 'https://api.subconscious.chat', token: '' },
  development: { label: 'Development', engineUrl: 'http://127.0.0.1:51515', serverUrl: 'http://127.0.0.1:5050', token: 'subconscious-dev-token' },
  custom: { label: 'Custom', engineUrl: '', serverUrl: '', token: '' },
};

export function environmentFor(config) {
  const match = Object.entries(ENVIRONMENTS).find(([name, env]) => name !== 'custom'
    && env.engineUrl === config.url && (!config.serverUrl || env.serverUrl === config.serverUrl));
  return match ? match[0] : 'custom';
}

export const state = {
  /** { url, token, serverUrl, paired, clientId, expiresAt, env } persisted in chrome.storage.local */
  config: {},
  /** { serverUrl, accessToken, refreshToken, expiresAt, user } persisted too */
  server: null,
  /** disconnected | connecting | connected */
  connection: 'disconnected',
  /** { status: unknown|anonymous|authenticated, user } as reported by the engine */
  account: { status: 'unknown', user: null },
  /** Main page: workspaces | threads | files | settings | account */
  page: 'threads',
  /** Section whose context panel the drawer shows: workspaces | threads | files */
  section: 'threads',
  workspaces: [],
  workspace: null,
  threads: [],
  thread: null,
  /** File viewer selection: { rootIndex, entry } */
  file: null,
  /** Last unrecoverable error to show in the connection banner of the active page. */
  notice: '',
};

const listeners = new Map();

export function on(event, fn) {
  if (!listeners.has(event)) listeners.set(event, new Set());
  listeners.get(event).add(fn);
  return () => listeners.get(event).delete(fn);
}

export function emit(event, detail) {
  for (const fn of listeners.get(event) || []) {
    try {
      fn(detail);
    } catch (error) {
      console.error(`Subconscious UI listener for "${event}" failed`, error);
    }
  }
}

export function set(patch, event = 'change') {
  Object.assign(state, patch);
  emit(event, patch);
}

export function isConnected() {
  return state.connection === 'connected';
}

export function errorMessage(error) {
  return (error && error.message) || String(error);
}
