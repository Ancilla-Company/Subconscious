// Subconscious cloud server client: email sign-in with a native refresh token,
// token refresh with rotation, and persistence in chrome.storage.local.
import { SERVER_KEY, state } from './state.js';

const trim = (url) => String(url || '').replace(/\/+$/, '');

/** Turns a FastAPI error body (`detail` string or validation list) into text. */
export function describeDetail(body, fallback) {
  const detail = body && body.detail;
  if (typeof detail === 'string' && detail) return detail;
  if (Array.isArray(detail) && detail.length) {
    return detail.map((item) => (item && item.msg) || String(item)).join('; ');
  }
  if (body && typeof body.error === 'string') return body.error;
  return fallback;
}

export class HttpError extends Error {
  constructor(message, status) {
    super(message);
    this.status = status;
  }
}

/** JSON fetch against any base URL. Throws HttpError with the server's `detail`. */
export async function jsonFetch(base, path, { method = 'GET', body, token, headers = {} } = {}) {
  let response;
  try {
    response = await fetch(`${trim(base)}${path}`, {
      method,
      headers: {
        Accept: 'application/json',
        ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...headers,
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch (_) {
    throw new HttpError(`Could not reach ${trim(base)}. Check the address and your connection.`, 0);
  }
  let data = null;
  try {
    data = response.status === 204 ? null : await response.json();
  } catch (_) {
    data = null;
  }
  if (!response.ok) throw new HttpError(describeDetail(data, `Request failed (${response.status}).`), response.status);
  return data;
}

export async function saveServer(session) {
  state.server = session;
  if (session) await chrome.storage.local.set({ [SERVER_KEY]: session });
  else await chrome.storage.local.remove(SERVER_KEY);
}

export async function loadServer() {
  const stored = await chrome.storage.local.get(SERVER_KEY);
  state.server = stored[SERVER_KEY] || null;
  return state.server;
}

function sessionFrom(serverUrl, data, previous) {
  return {
    serverUrl: trim(serverUrl),
    accessToken: data.access_token,
    refreshToken: data.refresh_token || previous?.refreshToken || '',
    expiresAt: Date.now() + (Number(data.expires_in) || 900) * 1000,
    user: data.user || previous?.user || null,
  };
}

/** Signs in with email + password. Native flavour returns the refresh token in the body. */
export async function signIn(serverUrl, email, password) {
  const data = await jsonFetch(serverUrl, '/auth/email/login?native=true', { method: 'POST', body: { email, password } });
  if (!data || !data.access_token) throw new Error('The server did not return a session.');
  await saveServer(sessionFrom(serverUrl, data, null));
  return state.server;
}

let refreshing = null;

/** Uses the stored refresh token and stores the rotated one. */
export function refreshSession() {
  if (!refreshing) {
    refreshing = (async () => {
      const current = state.server;
      if (!current?.refreshToken) throw new HttpError('Your session expired. Sign in again.', 401);
      try {
        const data = await jsonFetch(current.serverUrl, '/auth/refresh', { method: 'POST', body: { refresh_token: current.refreshToken } });
        await saveServer(sessionFrom(current.serverUrl, data, current));
      } catch (error) {
        if (error.status === 400 || error.status === 401 || error.status === 403) await saveServer(null);
        throw error;
      }
      return state.server;
    })().finally(() => { refreshing = null; });
  }
  return refreshing;
}

/** Authenticated server request; refreshes once on 401 or when the token is about to expire. */
export async function serverRequest(path, options = {}) {
  if (!state.server) throw new HttpError('Sign in to your Subconscious account first.', 401);
  if (state.server.expiresAt - Date.now() < 30000) await refreshSession();
  try {
    return await jsonFetch(state.server.serverUrl, path, { ...options, token: state.server.accessToken });
  } catch (error) {
    if (error.status !== 401) throw error;
    await refreshSession();
    return jsonFetch(state.server.serverUrl, path, { ...options, token: state.server.accessToken });
  }
}
