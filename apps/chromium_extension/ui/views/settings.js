// Settings main view: environment presets and the engine / server addresses.
import { disconnectEngine, endpoints, requestHosts, saveEndpoints } from '../connection.js';
import { banner, button, buttonRow, dropdown, errorLine, h, pageHeading, textField } from '../dom.js';
import { ENVIRONMENTS, errorMessage, state } from '../state.js';

export function renderSettings() {
  const current = endpoints();
  const env = dropdown({
    label: 'Environment',
    id: 'settings-env',
    value: current.env,
    options: Object.entries(ENVIRONMENTS).map(([value, preset]) => ({ value, label: value === 'custom' ? 'Custom' : `${preset.label} (port ${new URL(preset.engineUrl).port})` })),
    onChange: (value) => {
      const preset = ENVIRONMENTS[value];
      if (value !== 'custom') {
        engine.input.value = preset.engineUrl;
        server.input.value = preset.serverUrl;
      }
    },
  });
  const engine = textField({ label: 'Engine URL', id: 'settings-engine', value: current.engineUrl, required: true, placeholder: 'http://127.0.0.1:51516', inputmode: 'url' });
  const server = textField({ label: 'Server URL', id: 'settings-server', value: current.serverUrl, required: true, placeholder: 'https://api.subconscious.chat', inputmode: 'url' });
  const markCustom = () => { env.select.value = 'custom'; };
  engine.input.addEventListener('input', markCustom);
  server.input.addEventListener('input', markCustom);

  const error = errorLine('');
  const saved = h('p', { class: 'hint', role: 'status', hidden: true, text: 'Saved.' });
  const save = button('Save', { type: 'submit' });
  const disconnect = button('Disconnect', {
    kind: 'outlined',
    icon: 'plugDisconnected',
    disabled: !state.config.token,
    onClick: async () => {
      await disconnectEngine();
    },
  });

  const form = h('form', { class: 'stack' }, env.root, engine.root, server.root, buttonRow(disconnect, save), saved, error);
  form.addEventListener('submit', (event) => {
    event.preventDefault();
    error.hidden = true;
    saved.hidden = true;
    let engineUrl;
    let serverUrl;
    try {
      engineUrl = new URL(engine.input.value.trim()).origin;
      serverUrl = new URL(server.input.value.trim()).origin;
    } catch (_) {
      error.textContent = 'Enter full addresses, for example http://127.0.0.1:51516.';
      error.hidden = false;
      return;
    }
    // Keep the permission prompt inside this user gesture.
    requestHosts(engineUrl, serverUrl)
      .then(() => saveEndpoints({ env: env.select.value, engineUrl, serverUrl }))
      .then(() => { saved.hidden = false; })
      .catch((failure) => { error.textContent = errorMessage(failure); error.hidden = false; });
  });

  return h('div', { class: 'page' },
    pageHeading('Settings'),
    h('p', { class: 'hint', text: 'Choose which engine this extension talks to and which server signs you in. Sign in and pair from the Account page.' }),
    form,
    banner('info', 'Credentials stay in Chromium extension storage. Host access is requested only for the engine and server origins you save.'));
}
