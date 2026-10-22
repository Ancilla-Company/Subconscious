// Files main view: a read-only viewer for the file picked in the drawer's tree.
import { readFile } from '../data.js';
import { banner, button, buttonRow, emptyMessage, h, pageHeading } from '../dom.js';
import { errorMessage, state } from '../state.js';

const MAX_CHARS = 200000;

export function renderFiles() {
  const root = h('div', { class: 'page' }, pageHeading('Files'));
  const selected = state.file;
  if (!selected || !state.workspace) {
    root.append(emptyMessage(state.workspace ? 'Open the menu and pick a file to view it here.' : 'Choose a workspace, then pick a file from the menu.'));
    return root;
  }
  const body = h('pre', { class: 'file-view', tabindex: '0', aria: { label: `Contents of ${selected.name}` }, text: 'Loading…' });
  const actions = h('div', {});
  root.append(
    h('div', { class: 'file-head' }, h('strong', { class: 'file-name', text: selected.name }), h('span', { class: 'mono file-path', text: selected.entry })),
    actions, body);
  readFile(state.workspace.uuid, selected.rootIndex, selected.entry).then((result) => {
    if (state.file !== selected) return;
    const text = typeof result === 'string' ? result : typeof result?.content === 'string' ? result.content : null;
    if (text === null) {
      body.replaceWith(banner('info', 'This file cannot be shown as text.'));
      return;
    }
    body.textContent = text.length > MAX_CHARS ? `${text.slice(0, MAX_CHARS)}\n… (truncated)` : text;
    actions.append(buttonRow(button('Copy', { kind: 'outlined', icon: 'copy', onClick: () => navigator.clipboard.writeText(text) })));
  }).catch((error) => {
    if (state.file === selected) body.replaceWith(banner('error', errorMessage(error)));
  });
  return root;
}
