// Pairing the extension with the local engine through the cloud server:
// engine health probe -> server pairing assertion -> engine /pair -> client token.
import { HttpError, jsonFetch, serverRequest } from './server.js';

const SAME_ACCOUNT = 'Sign this engine in to the same account in the desktop app, then retry.';

/** Public engine health. Returns { found, nodeId, version } and never throws. */
export async function probeEngine(engineUrl) {
  try {
    const health = await jsonFetch(engineUrl, '/api/v1/health');
    return { found: true, nodeId: (health && health.node_id) || null, health };
  } catch (error) {
    return { found: false, nodeId: null, error };
  }
}

export function base64Url(bytes) {
  let binary = '';
  bytes.forEach((byte) => { binary += String.fromCharCode(byte); });
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function newNonce() {
  return base64Url(crypto.getRandomValues(new Uint8Array(32)));
}

/** Plain-language message for each failure along the pairing flow. */
export function pairingMessage(error, stage) {
  const status = error && error.status;
  if (status === 0) {
    return stage === 'engine' ? 'No engine found. Start the Subconscious desktop app, then retry.' : error.message;
  }
  if (stage === 'assertion') {
    if (status === 404) return `This engine is not registered to your account. ${SAME_ACCOUNT}`;
    if (status === 403) return 'This engine was removed from your account. Sign it in again in the desktop app.';
    if (status === 429) return 'Too many pairing attempts. Wait a minute, then retry.';
    if (status === 401) return 'Your session expired. Sign in again.';
  }
  if (stage === 'engine') {
    if (status === 401) return SAME_ACCOUNT;
    if (status === 403) return 'The engine refused this extension. Update the desktop app, then retry.';
    if (status === 404) return 'The pairing code expired or was already used. Retry.';
    if (status === 429) return 'Too many pairing attempts. Wait a minute, then retry.';
    if (status === 503) return 'The engine could not reach the Subconscious server. Check your connection, then retry.';
  }
  return (error && error.message) || 'Pairing failed.';
}

/**
 * Runs the whole pairing exchange with the stored server session.
 * Resolves to { token, clientId, expiresAt }; rejects with an Error whose message is user-ready.
 */
export async function pairEngine(engineUrl) {
  const probe = await probeEngine(engineUrl);
  if (!probe.found) throw new HttpError(pairingMessage(probe.error || new HttpError('', 0), 'engine'), 0);
  if (!probe.nodeId) throw new HttpError(`This engine is not linked to an account yet. ${SAME_ACCOUNT}`, 409);

  const clientNonce = newNonce();
  let assertion;
  try {
    assertion = await serverRequest(`/nodes/${encodeURIComponent(probe.nodeId)}/pairing-assertion`, {
      method: 'POST',
      body: { client_nonce: clientNonce, origin: location.origin },
    });
  } catch (error) {
    throw new HttpError(pairingMessage(error, 'assertion'), error.status);
  }

  let paired;
  try {
    paired = await jsonFetch(engineUrl, '/api/v1/pair', {
      method: 'POST',
      body: { assertion: assertion.assertion, client_nonce: clientNonce },
    });
  } catch (error) {
    throw new HttpError(pairingMessage(error, 'engine'), error.status);
  }
  if (!paired || !paired.token) throw new Error('The engine did not return a client token.');
  return { token: paired.token, clientId: paired.client_id || '', expiresAt: paired.expires_at || null };
}
