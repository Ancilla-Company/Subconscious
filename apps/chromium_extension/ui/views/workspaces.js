// Workspaces main view: summary of the selected workspace plus the create form.
import { createWorkspace, selectWorkspace, workspaceRoots } from '../data.js';
import { button, buttonRow, emptyMessage, errorLine, h, pageHeading, textField } from '../dom.js';
import { emit, errorMessage, isConnected, state } from '../state.js';

export function renderWorkspaces({ focusCreate = false } = {}) {
  const root = h('div', { class: 'page' }, pageHeading('Workspaces'));
  const workspace = state.workspace;

  if (workspace) {
    const roots = workspaceRoots(workspace);
    root.append(h('section', { class: 'summary', aria: { label: 'Selected workspace' } },
      h('h2', { class: 'summary-title', text: workspace.name }),
      h('dl', { class: 'facts' },
        h('dt', { text: 'Folders' }),
        h('dd', {}, roots.length ? roots.map((path) => h('div', { class: 'mono', text: path })) : 'None configured'),
        h('dt', { text: 'Threads' }),
        h('dd', { text: String(state.threads.length) })),
      buttonRow(button('Open threads', { kind: 'tonal', icon: 'chat', onClick: () => emit('navigate', { page: 'threads' }) }))));
  } else {
    root.append(emptyMessage(state.workspaces.length ? 'Select a workspace from the menu.' : 'No workspaces yet. Create the first one below.'));
  }

  const error = errorLine('');
  const name = textField({ label: 'New workspace', placeholder: 'Workspace name', required: true, id: 'workspace-name' });
  const form = h('form', { class: 'stack' }, name.root, buttonRow(button('Create workspace', { type: 'submit', icon: 'add', disabled: !isConnected() })), error);
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    error.hidden = true;
    try {
      const created = await createWorkspace(name.input.value.trim());
      name.input.value = '';
      await selectWorkspace(state.workspaces.find((item) => item.uuid === created?.uuid) || state.workspace);
    } catch (failure) {
      error.textContent = errorMessage(failure);
      error.hidden = false;
    }
  });
  root.append(form);
  if (focusCreate) queueMicrotask(() => name.input.focus());
  if (!isConnected()) root.append(h('p', { class: 'hint', text: 'Connect to your engine on the Account page to manage workspaces.' }));
  return root;
}
