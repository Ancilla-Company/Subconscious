// Account main view: server sign-in, engine discovery, pairing, and the
// signed-in card. A paired token is by definition on the engine's own account;
// a pasted joining token falls back to the engine's own sign-in forms.
import {
  applyStoredConfig, connectWithToken, disconnectEngine, endpoints, hasServerSession, pairAndConnect, requestHosts, signOutEverywhere,
} from '../connection.js';
import { banner, button, buttonRow, errorLine, fluentIcon, h, pageHeading, segmented, textField } from '../dom.js';
import { pairingMessage, probeEngine } from '../pairing.js';
import { signIn } from '../server.js';
import { ENVIRONMENTS, emit, errorMessage, isConnected, state } from '../state.js';
import { renderEngineSignedIn, renderEngineSignedOut } from './engine_account.js';

const flow = { mode: 'signIn', probe: 'idle', error: '', busy: false };

function userCard(user, caption) {
  const name = (user?.display_name || user?.displayName || '').trim();
  return h('div', { class: 'account-card' },
    h('div', { class: 'avatar' }, fluentIcon('person')),
    h('div', { class: 'account-details' },
      h('strong', { text: name || user?.email || 'Signed in' }),
      name && user?.email && h('span', { text: user.email }),
      caption && h('span', { text: caption })));
}

function hostLabel(url) {
  try {
    return new URL(url).host;
  } catch (_) {
    return url;
  }
}

export function renderAccount() {
  const root = h('div', { class: 'page' });
  const draw = () => {
    root.textContent = '';
    root.append(pageHeading('Account'));
    const connected = state.config.token && state.connection !== 'disconnected';
    if (connected && state.config.paired) root.append(pairedView());
    else if (connected) root.append(tokenView(draw));
    else root.append(pairingView(draw));
  };
  draw();
  return root;
}

// ---- connected -------------------------------------------------------------

function pairedView() {
  const error = errorLine('');
  const status = state.connection === 'connected' ? 'Paired with the engine on this computer' : 'Reconnecting to the engine…';
  return h('div', { class: 'stack' },
    userCard(state.account.user, status),
    buttonRow(
      button('Disconnect', { kind: 'outlined', icon: 'plugDisconnected', onClick: () => disconnectEngine() }),
      button('Sign out', { kind: 'tonal', icon: 'signOut', onClick: () => signOutEverywhere().catch((e) => { error.textContent = errorMessage(e); error.hidden = false; }) })),
    h('p', { class: 'hint', text: 'Sign out removes the engine pairing and your server sign-in from this browser.' }),
    error);
}

function tokenView(draw) {
  const body = h('div', { class: 'stack' });
  if (state.account.status === 'authenticated') {
    body.append(userCard(state.account.user, 'Connected with a joining token'), renderEngineSignedIn());
  } else if (state.account.status === 'anonymous') {
    body.append(renderEngineSignedOut(draw));
  } else {
    body.append(h('p', { class: 'empty', text: 'Checking your account…' }));
  }
  body.append(buttonRow(button('Disconnect', { kind: 'outlined', icon: 'plugDisconnected', onClick: () => disconnectEngine() })));
  return body;
}

// ---- not connected: sign in, find engine, pair -----------------------------

function pairingView(draw) {
  const { env, engineUrl, serverUrl } = endpoints();
  const stack = h('div', { class: 'stack' });
  if (state.notice && state.config.token) {
    stack.append(banner('error', state.notice), buttonRow(button('Retry connection', { kind: 'outlined', onClick: () => applyStoredConfig(state.config) })));
  }
  stack.append(
    h('p', { class: 'hint' },
      `${ENVIRONMENTS[env]?.label || 'Custom'}: engine ${hostLabel(engineUrl)}, server ${hostLabel(serverUrl)}. `,
      h('button', { type: 'button', class: 'link', text: 'Change', on: { click: () => emit('navigate', { page: 'settings' }) } })));

  const error = errorLine(flow.error);
  if (!hasServerSession()) stack.append(serverSignIn(draw, error, engineUrl, serverUrl));
  else stack.append(enginePairing(draw, error, engineUrl, serverUrl));
  stack.append(error, advanced(draw));
  return stack;
}

async function runPairing(draw) {
  flow.busy = true;
  flow.error = '';
  draw();
  try {
    await pairAndConnect();
  } catch (error) {
    flow.error = errorMessage(error);
  } finally {
    flow.busy = false;
    draw();
  }
}

function serverSignIn(draw, error, engineUrl, serverUrl) {
  const tabs = segmented('Account action', [['signIn', 'Sign in'], ['signUp', 'Create account']], flow.mode, (mode) => { flow.mode = mode; flow.error = ''; draw(); });
  if (flow.mode === 'signUp') {
    return h('div', { class: 'stack' },
      h('p', { class: 'hint', text: 'Sign in with your Subconscious account to pair this browser with your engine.' }), tabs,
      banner('info', 'Create your account in the Subconscious desktop app or at subconscious.chat, then come back and sign in here.'));
  }
  const email = textField({ label: 'Email address', id: 'srv-email', type: 'email', required: true, autocomplete: 'username', placeholder: 'you@example.com', value: flow.email || '', disabled: flow.busy });
  const password = textField({ label: 'Password', id: 'srv-pass', type: 'password', required: true, minlength: '8', autocomplete: 'current-password', placeholder: 'At least 8 characters', disabled: flow.busy });
  const form = h('form', { class: 'stack' }, email.root, password.root,
    buttonRow(button(flow.busy ? 'Signing in…' : 'Sign in and pair', { type: 'submit', block: true, disabled: flow.busy })));
  form.addEventListener('submit', (event) => {
    event.preventDefault();
    // Host permissions must be requested inside the gesture, before any other await.
    const hosts = requestHosts(engineUrl, serverUrl);
    const credentials = { email: email.input.value.trim(), password: password.input.value };
    flow.email = credentials.email;
    (async () => {
      flow.busy = true;
      flow.error = '';
      draw();
      try {
        await hosts;
        await signIn(serverUrl, credentials.email, credentials.password);
        flow.busy = false;
        await pairAndConnect();
      } catch (failure) {
        flow.error = errorMessage(failure);
      } finally {
        flow.busy = false;
        draw();
      }
    })();
  });
  error.textContent = flow.error;
  return h('div', { class: 'stack' },
    h('p', { class: 'hint', text: 'Sign in with your Subconscious account to pair this browser with your engine.' }), tabs, form);
}

function enginePairing(draw, error, engineUrl, serverUrl) {
  if (flow.probe === 'idle') {
    flow.probe = 'checking';
    probeEngine(engineUrl).then((result) => {
      flow.probe = result.found ? 'found' : 'missing';
      flow.probeNode = result.nodeId;
      draw();
    });
  }
  const probe = flow.probe;
  const label = probe === 'found' ? 'Engine found' : probe === 'missing' ? 'No engine found' : 'Looking for the engine…';
  const detail = probe === 'found' ? `Running at ${hostLabel(engineUrl)}`
    : probe === 'missing' ? 'Start the Subconscious desktop app on this computer.' : hostLabel(engineUrl);
  const retry = button('Retry', {
    kind: 'outlined',
    disabled: probe === 'checking' || flow.busy,
    onClick: () => { flow.probe = 'idle'; flow.error = ''; draw(); },
  });
  const connect = button(flow.busy ? 'Pairing…' : 'Pair and connect', {
    block: true,
    disabled: probe !== 'found' || flow.busy,
    onClick: () => {
      const hosts = requestHosts(engineUrl, serverUrl);
      hosts.then(() => runPairing(draw)).catch((failure) => { flow.error = errorMessage(failure); draw(); });
    },
  });
  const signOut = button('Sign out', {
    kind: 'text',
    onClick: () => signOutEverywhere().then(() => { flow.probe = 'idle'; flow.error = ''; draw(); }),
  });
  return h('div', { class: 'stack' },
    userCard(state.server.user, `Signed in to ${hostLabel(serverUrl)}`),
    h('div', { class: `probe probe-${probe}`, role: 'status' },
      h('span', { class: `status-dot ${probe === 'found' ? 'connected' : probe === 'missing' ? 'disconnected' : 'connecting'}`, aria: { hidden: 'true' } }),
      h('div', { class: 'probe-text' }, h('strong', { text: label }), h('span', { text: detail })), retry),
    connect, buttonRow(signOut));
}

// ---- fallback --------------------------------------------------------------

function advanced(draw) {
  const { engineUrl, token } = endpoints();
  const input = textField({ label: 'Joining token', id: 'adv-token', type: 'password', value: token, placeholder: 'Token from the desktop app' });
  const error = errorLine('');
  const form = h('form', { class: 'stack' },
    h('p', { class: 'hint', text: `If pairing is unavailable, paste the engine's joining token to connect to ${hostLabel(engineUrl)} directly.` }),
    input.root, buttonRow(button('Connect with token', { type: 'submit', kind: 'outlined' })), error);
  form.addEventListener('submit', (event) => {
    event.preventDefault();
    const value = input.input.value.trim();
    if (!value) { error.textContent = 'Paste the joining token first.'; error.hidden = false; return; }
    const hosts = requestHosts(engineUrl);
    hosts.then(() => connectWithToken(value)).catch((failure) => {
      error.textContent = isConnected() ? '' : pairingMessage(failure, 'token');
      error.hidden = false;
      draw();
    });
  });
  const details = h('details', { class: 'advanced' }, h('summary', { text: 'Advanced' }), form);
  if (flow.advancedOpen) details.open = true;
  details.addEventListener('toggle', () => { flow.advancedOpen = details.open; });
  return details;
}
