// Orchestrates connecting: stored config, host permissions, pairing, joining
// token fallback, sign-out and the startup sequence.
import { loadWorkspaces } from './data.js';
import { connect, disconnect, persistConfig, stopEvents } from './engine.js';
import { pairEngine } from './pairing.js';
import { loadServer, saveServer } from './server.js';
import { ENVIRONMENTS, STORAGE_KEY, emit, environmentFor, set, state } from './state.js';

/** Engine/server endpoints in effect: the saved ones or the production defaults. */
export function endpoints() {
  const env = state.config.env || environmentFor(state.config);
  const preset = ENVIRONMENTS[state.config.url ? env : 'production'] || ENVIRONMENTS.production;
  return {
    env: state.config.url ? env : 'production',
    engineUrl: state.config.url || preset.engineUrl,
    serverUrl: state.config.serverUrl || preset.serverUrl,
    token: state.config.token || preset.token,
  };
}

/**
 * Asks for optional host access to each URL's origin. Call it synchronously
 * inside the click handler (before any await) so the user gesture is valid.
 */
export function requestHosts(...urls) {
  const origins = [...new Set(urls.filter(Boolean).map((url) => `${new URL(url).origin}/*`))];
  return chrome.permissions.request({ origins }).then((granted) => {
    if (!granted) throw new Error('Host permission was not granted, so the extension cannot reach the engine or server.');
  });
}

export function hasServerSession() {
  const { serverUrl } = endpoints();
  return Boolean(state.server && state.server.serverUrl === serverUrl.replace(/\/+$/, ''));
}

async function finishConnect({ landOnAccountIfSignedOut }) {
  if (!(await connect())) throw new Error(state.notice || 'Could not connect to the engine.');
  await loadWorkspaces().catch((error) => console.warn('Subconscious: workspaces failed', error));
  const needsAccount = landOnAccountIfSignedOut && state.account.status !== 'authenticated';
  emit('navigate', { page: needsAccount ? 'account' : 'threads' });
}

/** Saves environment + URLs without connecting. Drops the token when the engine changes. */
export async function saveEndpoints({ env, engineUrl, serverUrl }) {
  const engineChanged = state.config.url && state.config.url.replace(/\/$/, '') !== engineUrl.replace(/\/$/, '');
  if (engineChanged) {
    stopEvents();
    state.config = {};
    set({ connection: 'disconnected', account: { status: 'unknown', user: null } }, 'account');
  }
  state.config = { ...state.config, env, url: engineUrl, serverUrl };
  await persistConfig();
  emit('config');
}

/** Server sign-in result is already stored; pair with the engine and connect. */
export async function pairAndConnect() {
  const { env, engineUrl, serverUrl } = endpoints();
  set({ connection: 'connecting' });
  try {
    const result = await pairEngine(engineUrl);
    state.config = { env, url: engineUrl, serverUrl, token: result.token, paired: true, clientId: result.clientId, expiresAt: result.expiresAt };
    await persistConfig();
    await finishConnect({ landOnAccountIfSignedOut: false });
  } catch (error) {
    set({ connection: 'disconnected' });
    throw error;
  }
}

/** Fallback: connect with a pasted joining token (or the development token). */
export async function connectWithToken(token) {
  const { env, engineUrl, serverUrl } = endpoints();
  stopEvents();
  state.config = { env, url: engineUrl, serverUrl, token, paired: false };
  await persistConfig();
  await finishConnect({ landOnAccountIfSignedOut: true });
}

/** Forgets the engine connection; the server sign-in stays. */
export async function disconnectEngine() {
  const { env, engineUrl, serverUrl } = endpoints();
  await disconnect();
  state.config = { env, url: engineUrl, serverUrl };
  await persistConfig();
  emit('config');
}

/** Clears the engine token and the server session. */
export async function signOutEverywhere() {
  await disconnect();
  await saveServer(null);
  await chrome.storage.local.remove(STORAGE_KEY);
  state.config = {};
  emit('config');
  set({ account: { status: 'unknown', user: null } }, 'account');
}

/** Applies a config read from storage (startup, or another window changed it). */
export async function applyStoredConfig(stored) {
  stopEvents();
  state.config = stored || {};
  state.workspace = null;
  state.workspaces = [];
  state.thread = null;
  state.threads = [];
  state.file = null;
  emit('selection');
  emit('config');
  if (state.config.url && state.config.token) {
    if (await connect()) {
      await loadWorkspaces().catch((error) => console.warn('Subconscious: workspaces failed', error));
      emit('navigate', { page: state.account.status === 'authenticated' ? 'threads' : 'account' });
      return;
    }
  }
  set({ connection: 'disconnected', account: { status: 'unknown', user: null } }, 'account');
  emit('navigate', { page: 'account' });
}

export async function startup() {
  const [stored] = await Promise.all([chrome.storage.local.get(STORAGE_KEY), loadServer()]);
  await applyStoredConfig(stored[STORAGE_KEY]);
}
