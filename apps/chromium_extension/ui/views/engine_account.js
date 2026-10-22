// Engine-side account session, used when the extension is connected with a
// pasted joining token (a paired token is by definition on the engine's own
// account, so the Account page shows the signed-in card without these forms).
import { connectWithToken } from '../connection.js';
import { api, refreshAccount } from '../engine.js';
import { button, buttonRow, errorLine, h, segmented, textField } from '../dom.js';
import { errorMessage, set, state } from '../state.js';

const ui = { form: 'signIn', codeRequested: false, email: '', cooldown: 0, timer: null };

const post = (path, body) => api(path, { method: 'POST', body: JSON.stringify(body) });

/** Each account has its own engine; follow a sign-in that lands on another profile. */
async function followProfile(profile) {
  if (!profile?.switched || !profile.port || !profile.token) return false;
  const next = new URL(state.config.url);
  if (profile.host && profile.host !== next.hostname) {
    next.hostname = profile.host;
    const granted = await chrome.permissions.request({ origins: [`${next.origin}/*`] });
    if (!granted) throw new Error('Host permission was not granted for your account engine.');
  }
  next.port = String(profile.port);
  state.config = { ...state.config, url: next.origin };
  await connectWithToken(profile.token);
  return true;
}

async function adopt(session) {
  if (await followProfile(session.profile)) return '';
  set({
    account: session.authenticated && session.user
      ? { status: 'authenticated', user: session.user }
      : { status: 'anonymous', user: null },
  }, 'account');
  return session.notice || '';
}

export function renderEngineSignedIn() {
  const error = errorLine('');
  const signOut = button('Sign out of engine', {
    kind: 'tonal',
    icon: 'signOut',
    onClick: async () => {
      signOut.disabled = true;
      try {
        await post('account/logout', {});
        await refreshAccount();
      } catch (failure) {
        signOut.disabled = false;
        error.textContent = errorMessage(failure);
        error.hidden = false;
      }
    },
  });
  return h('div', { class: 'stack' }, buttonRow(signOut), error);
}

export function renderEngineSignedOut(rerender) {
  const error = errorLine('');
  const notice = h('p', { class: 'notice', role: 'status', hidden: true });
  const busy = (form, label, action) => async (event) => {
    event.preventDefault();
    const submit = form.querySelector('button[type="submit"]');
    const idle = submit.textContent;
    error.hidden = true;
    notice.hidden = true;
    form.querySelectorAll('input, button').forEach((node) => { node.disabled = true; });
    submit.textContent = label;
    try {
      const message = await action();
      if (message) { notice.textContent = message; notice.hidden = false; }
    } catch (failure) {
      error.textContent = errorMessage(failure);
      error.hidden = false;
    } finally {
      if (form.isConnected) {
        form.querySelectorAll('input, button').forEach((node) => { node.disabled = false; });
        submit.textContent = idle;
      }
    }
  };

  const tabs = segmented('Account action', [['signIn', 'Sign in'], ['signUp', 'Create account']], ui.form, (value) => { ui.form = value; rerender(); });
  let form;
  if (ui.form === 'signIn') {
    const email = textField({ label: 'Email address', id: 'eng-in-email', type: 'email', required: true, autocomplete: 'username', placeholder: 'you@example.com' });
    const password = textField({ label: 'Password', id: 'eng-in-pass', type: 'password', required: true, minlength: '8', autocomplete: 'current-password', placeholder: 'At least 8 characters' });
    form = h('form', { class: 'stack' }, email.root, password.root, buttonRow(button('Sign in', { type: 'submit', block: true })));
    form.addEventListener('submit', busy(form, 'Signing in…', async () => adopt(await post('account/login', {
      email: email.input.value.trim(), password: password.input.value, device_name: 'Chromium extension',
    }))));
  } else {
    const email = textField({ label: 'Email address', id: 'eng-up-email', type: 'email', required: true, autocomplete: 'email', value: ui.email, placeholder: 'you@example.com' });
    const code = textField({ label: 'Verification code', id: 'eng-up-code', inputmode: 'numeric', autocomplete: 'one-time-code', required: ui.codeRequested, placeholder: 'Code from your email' });
    const name = textField({ label: 'Display name (optional)', id: 'eng-up-name', autocomplete: 'name' });
    const password = textField({ label: 'Password', id: 'eng-up-pass', type: 'password', minlength: '8', required: ui.codeRequested, autocomplete: 'new-password', placeholder: 'At least 8 characters' });
    const details = h('div', { class: ui.codeRequested ? '' : 'hidden' }, code.root, name.root, password.root);
    form = h('form', { class: 'stack' }, email.root, details,
      buttonRow(button(ui.codeRequested ? 'Create account' : 'Send verification code', { type: 'submit', block: true })));
    form.addEventListener('submit', busy(form, 'Contacting server…', async () => {
      ui.email = email.input.value.trim();
      if (!ui.codeRequested) {
        const result = await post('account/signup/code', { email: ui.email });
        ui.codeRequested = true;
        rerender();
        return result.notice || 'Check your email for a verification code.';
      }
      ui.codeRequested = false;
      return adopt(await post('account/signup/complete', {
        email: ui.email, code: code.input.value.trim(), password: password.input.value, display_name: name.input.value.trim(),
      }));
    }));
  }
  return h('div', { class: 'stack' },
    h('p', { class: 'hint', text: 'Sign this engine in to your Subconscious account. Your data stays on your own computers.' }),
    tabs, form, notice, error);
}
