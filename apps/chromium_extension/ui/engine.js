// Engine connection: REST API, automatic re-pairing on 401, the /api/v1/events
// WebSocket (chat turns, approvals, cancel) and the extension point for the
// client tool bridge (tools/bridge.js, written elsewhere).
import { pairEngine } from './pairing.js';
import { CLIENT_NAME, CLIENT_TYPE, STORAGE_KEY, emit, errorMessage, set, state } from './state.js';

const base = () => String(state.config.url || '').replace(/\/$/, '');

export async function persistConfig() {
  if (state.config.url) await chrome.storage.local.set({ [STORAGE_KEY]: state.config });
  else await chrome.storage.local.remove(STORAGE_KEY);
}

// ---- REST ------------------------------------------------------------------

let repairing = null;

/** Mints a fresh client token with the stored server session. */
function repair() {
  if (!repairing) {
    repairing = (async () => {
      if (!state.config.paired || !state.server) throw new Error('The engine rejected the saved token. Pair again from Account.');
      const result = await pairEngine(state.config.url);
      state.config = { ...state.config, token: result.token, clientId: result.clientId, expiresAt: result.expiresAt };
      await persistConfig();
    })().finally(() => { repairing = null; });
  }
  return repairing;
}

export async function api(path, options = {}, retried = false) {
  let response;
  try {
    response = await fetch(`${base()}/api/v1/${path}`, {
      ...options,
      headers: {
        Authorization: `Bearer ${state.config.token}`,
        'Content-Type': 'application/json',
        ...(options.headers || {}),
      },
    });
  } catch (_) {
    throw new Error(`Could not reach the engine at ${base()}. Is the desktop app running?`);
  }
  if (response.status === 401 && !retried && state.config.paired) {
    await repair();
    return api(path, options, true);
  }
  if (!response.ok) {
    let detail = '';
    try {
      const body = await response.json();
      detail = body.error || body.detail || '';
    } catch (_) {
      detail = '';
    }
    throw new Error((typeof detail === 'string' && detail) || `Engine request failed (${response.status}).`);
  }
  return response.status === 204 ? null : response.json();
}

// ---- tool bridge extension point -------------------------------------------

let bridge = null;
let bridgeWarned = false;

async function startBridge(socket) {
  stopBridge();
  try {
    const { createToolBridge } = await import('../tools/bridge.js');
    const next = createToolBridge({
      sendFrame: (frame) => socket.send(JSON.stringify(frame)),
      getConfig: () => ({ engineUrl: state.config.url, clientName: CLIENT_NAME }),
    });
    await next.register();
    if (events.socket === socket) bridge = next;
    else next.dispose();
  } catch (error) {
    bridge = null;
    if (!bridgeWarned) {
      bridgeWarned = true;
      console.info('Subconscious: browser tools are not available.', error);
    }
  }
}

function stopBridge() {
  const current = bridge;
  bridge = null;
  try {
    if (current) current.dispose();
  } catch (error) {
    console.warn('Subconscious: tool bridge dispose failed', error);
  }
}

async function routeToolRequest(socket, frame) {
  let handled = false;
  try {
    handled = bridge ? await bridge.handleFrame(frame) : false;
  } catch (error) {
    console.warn('Subconscious: tool bridge failed', error);
  }
  if (handled || socket.readyState !== WebSocket.OPEN) return;
  socket.send(JSON.stringify({
    v: 1,
    type: 'client.tool.result',
    id: frame.id,
    data: { request_id: frame.data?.request_id, ok: false, error: 'Browser tools are not available in this extension build.' },
  }));
}

// ---- events socket ---------------------------------------------------------
// One socket per open popup / side panel. It identifies the extension
// (client_type=browser_extension) and carries chat turns and tool traffic.

const events = { socket: null, ready: null, wanted: false, retries: 0, timer: null, turns: new Map() };

function eventsUrl() {
  const endpoint = new URL(state.config.url);
  endpoint.protocol = endpoint.protocol === 'https:' ? 'wss:' : 'ws:';
  endpoint.pathname = '/api/v1/events';
  endpoint.search = new URLSearchParams({
    token: state.config.token,
    client_type: CLIENT_TYPE,
    client_name: CLIENT_NAME,
    client_version: chrome.runtime.getManifest().version,
  }).toString();
  return endpoint;
}

function failTurns(error) {
  for (const turn of events.turns.values()) turn.handlers.onError?.(error);
  events.turns.clear();
}

export function connectEvents() {
  closeEvents();
  events.wanted = true;
  const socket = new WebSocket(eventsUrl());
  let acked = false;
  events.socket = socket;
  events.ready = new Promise((resolve, reject) => {
    socket.onopen = () => {
      socket.send(JSON.stringify({
        v: 1,
        type: 'client.hello',
        id: 'extension-hello',
        data: { clientType: CLIENT_TYPE, clientName: CLIENT_NAME, clientVersion: chrome.runtime.getManifest().version },
      }));
    };
    socket.onmessage = (event) => {
      let frame;
      try {
        frame = JSON.parse(event.data);
      } catch (_) {
        return;
      }
      if (!frame || typeof frame.type !== 'string') return;
      if (frame.type === 'client.hello.ack') {
        acked = true;
        events.retries = 0;
        set({ connection: 'connected' });
        resolve();
        startBridge(socket);
      } else if (frame.type === 'client.hello.reject') {
        reject(new Error(frame.data?.reason || 'Engine rejected the extension.'));
      } else if (frame.type === 'client.tool.request') {
        routeToolRequest(socket, frame);
      } else {
        dispatchTurnFrame(frame);
      }
    };
    socket.onerror = () => reject(new Error('Chat connection failed.'));
    socket.onclose = () => {
      reject(new Error('Chat connection closed.'));
      if (events.socket !== socket) return;
      events.socket = null;
      stopBridge();
      failTurns(new Error('Chat connection closed.'));
      if (events.wanted) scheduleReconnect(acked);
    };
  });
  events.ready.catch(() => {});
}

async function scheduleReconnect(wasAcked) {
  set({ connection: 'connecting' });
  // A socket refused before the hello is usually a rejected token. A REST call
  // re-pairs automatically when the engine answers 401 to a paired token.
  if (!wasAcked) await api('account/session').catch(() => {});
  if (!events.wanted) return;
  const delay = Math.min(30000, 1000 * 2 ** events.retries++);
  events.timer = setTimeout(() => { if (events.wanted) connectEvents(); }, delay);
}

export function closeEvents() {
  clearTimeout(events.timer);
  const socket = events.socket;
  events.socket = null;
  stopBridge();
  failTurns(new Error('Chat connection closed.'));
  if (socket) socket.close();
}

export function stopEvents() {
  events.wanted = false;
  closeEvents();
}

function dispatchTurnFrame(frame) {
  const turn = events.turns.get(frame.id);
  if (!turn) return; // oauth.request, agui.event and anything unknown are ignored
  const { handlers } = turn;
  switch (frame.type) {
    case 'chat.delta':
      handlers.onDelta?.(frame.data?.delta || '');
      break;
    case 'chat.done':
      events.turns.delete(frame.id);
      handlers.onDone?.(frame.data || {});
      break;
    case 'chat.cancelled':
      events.turns.delete(frame.id);
      handlers.onCancelled?.(frame.data || {});
      break;
    case 'chat.error':
      events.turns.delete(frame.id);
      handlers.onError?.(new Error(frame.data?.error || frame.data?.message || 'Chat failed.'));
      break;
    case 'tool.approval.request':
      handlers.onApproval?.({ turnId: frame.id, ...(frame.data || {}) });
      break;
    default:
      break;
  }
}

/** Starts a chat turn. Returns { turnId }. Handlers: onDelta, onDone, onCancelled, onError, onApproval. */
export async function sendChat({ content, threadUuid, workspaceUuid }, handlers) {
  if (!events.socket) connectEvents();
  await events.ready;
  const turnId = `extension-${crypto.randomUUID()}`;
  events.turns.set(turnId, { handlers });
  events.socket.send(JSON.stringify({
    v: 1,
    type: 'chat.send',
    id: turnId,
    data: { content, ...(threadUuid ? { thread_uuid: threadUuid } : { workspace_uuid: workspaceUuid }) },
  }));
  return { turnId };
}

function sendFrame(frame) {
  if (!events.socket || events.socket.readyState !== WebSocket.OPEN) throw new Error('Chat connection closed.');
  events.socket.send(JSON.stringify(frame));
}

export function cancelTurn(turnId, threadUuid) {
  sendFrame({ v: 1, type: 'chat.cancel', id: turnId, data: threadUuid ? { thread_uuid: threadUuid } : {} });
}

export function respondApproval(turnId, approvalId, decision) {
  sendFrame({ v: 1, type: 'tool.approval.response', id: turnId, data: { approval_id: approvalId, decision } });
}

// ---- connect / disconnect --------------------------------------------------

/** Fetches the account shown on the Account page. */
export async function refreshAccount() {
  const session = await api('account/session');
  if (state.config.paired) {
    // A paired token only exists for the engine's own account.
    const user = (session.authenticated && session.user) || state.server?.user || { email: 'Signed in' };
    set({ account: { status: 'authenticated', user } }, 'account');
    return;
  }
  set({
    account: session.authenticated && session.user
      ? { status: 'authenticated', user: session.user }
      : { status: 'anonymous', user: null },
  }, 'account');
}

/** Verifies the saved config, opens the socket and reports success. */
export async function connect() {
  set({ connection: 'connecting', notice: '' });
  try {
    await api('health');
    await refreshAccount();
    connectEvents();
    return true;
  } catch (error) {
    set({ connection: 'disconnected', account: { status: 'unknown', user: null }, notice: errorMessage(error) }, 'account');
    return false;
  }
}

/** Forgets the engine connection (and optionally the server session). */
export async function disconnect() {
  stopEvents();
  state.config = {};
  state.workspaces = [];
  state.workspace = null;
  state.threads = [];
  state.thread = null;
  state.file = null;
  await persistConfig();
  set({ connection: 'disconnected', account: { status: 'unknown', user: null } }, 'account');
  emit('selection');
}
