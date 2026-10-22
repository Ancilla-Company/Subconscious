// Left flyout drawer (the mobile layout's navigation): logo header, section
// nav, the context panel for the selected section and a settings/account
// footer. Overlay with scrim, focus trap, Esc/scrim/selection closes it.
import { brandLogo } from '../icons.js';
import { listFiles, selectThread, selectWorkspace, workspaceRoots } from './data.js';
import { clear, dropdown, emptyMessage, fluentIcon, h, iconButton, listRow } from './dom.js';
import { emit, errorMessage, on, set, state } from './state.js';

const SECTIONS = [
  ['workspaces', 'Workspaces', 'apps'],
  ['threads', 'Threads', 'chat'],
  ['files', 'Files', 'files'],
];

const FOCUSABLE = 'a[href], button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex]:not([tabindex="-1"])';

// File tree cache for the Files context panel.
const tree = { workspace: null, rootIndex: 0, expanded: new Set(), children: new Map(), loading: new Set(), error: '' };

function resetTree() {
  Object.assign(tree, { workspace: state.workspace?.uuid || null, rootIndex: 0, expanded: new Set(), children: new Map(), loading: new Set(), error: '' });
}

export function createDrawer({ navigate, onOpenChange }) {
  const title = h('strong', { class: 'flyout-title', text: 'Subconscious' });
  const closeButton = iconButton('dismiss', 'Close menu', () => close());
  const nav = h('nav', { class: 'flyout-nav', aria: { label: 'Sections' } });
  const context = h('div', { class: 'flyout-context' });
  const footer = h('div', { class: 'flyout-footer' });
  const panel = h('aside', {
    class: 'drawer',
    role: 'dialog',
    aria: { modal: 'true', label: 'Navigation menu' },
    tabindex: '-1',
    inert: true,
  },
  h('div', { class: 'flyout-header' }, brandLogo(), title, closeButton),
  nav, h('hr', { class: 'divider' }), context, h('hr', { class: 'divider' }), footer);
  const scrim = h('div', { class: 'scrim', on: { click: () => close() } });
  const root = h('div', { class: 'drawer-layer' }, scrim, panel);

  let opened = false;
  let returnFocus = null;

  function open() {
    if (opened) return;
    opened = true;
    returnFocus = document.activeElement;
    render();
    panel.inert = false;
    root.classList.add('open');
    onOpenChange(true);
    const selected = nav.querySelector('[aria-current="page"]') || nav.querySelector('button');
    (selected || panel).focus();
    refreshTree();
  }

  function close({ restoreFocus = true } = {}) {
    if (!opened) return;
    opened = false;
    root.classList.remove('open');
    panel.inert = true;
    onOpenChange(false);
    if (restoreFocus && returnFocus && returnFocus.isConnected) returnFocus.focus();
    returnFocus = null;
  }

  panel.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      event.stopPropagation();
      close();
    } else if (event.key === 'Tab') {
      const items = [...panel.querySelectorAll(FOCUSABLE)].filter((node) => node.offsetParent !== null);
      if (!items.length) return;
      const first = items[0];
      const last = items[items.length - 1];
      if (event.shiftKey && (document.activeElement === first || document.activeElement === panel)) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    }
  });

  // ---- content -------------------------------------------------------------

  function choose(page) {
    navigate(page);
    close({ restoreFocus: false });
  }

  function renderNav() {
    clear(nav, SECTIONS.map(([id, label, icon]) => {
      const selected = state.section === id;
      const row = h('button', {
        type: 'button',
        class: `nav${selected ? ' selected' : ''}`,
        dataset: { key: `nav-${id}` },
        aria: selected ? { current: 'page' } : {},
        on: { click: () => { set({ section: id }, 'section'); navigate(id); } },
      }, fluentIcon(icon, { filled: selected }), h('span', { text: label }));
      return row;
    }));
  }

  function toolbar(label, action) {
    return h('div', { class: 'context-toolbar' }, h('span', { class: 'context-title', text: label }), action);
  }

  function renderWorkspacesContext() {
    const add = iconButton('add', 'New workspace', () => { navigate('workspaces', { create: true }); close({ restoreFocus: false }); }, { size: 'sm' });
    const list = h('div', { class: 'list' });
    if (!state.workspaces.length) list.append(emptyMessage('No workspaces yet.'));
    state.workspaces.forEach((workspace) => {
      const row = listRow({
        icon: 'apps',
        label: workspace.name,
        selected: workspace.uuid === state.workspace?.uuid,
        onClick: async () => { choose('workspaces'); await selectWorkspace(workspace); },
      });
      row.dataset.key = `ws-${workspace.uuid}`;
      list.append(row);
    });
    clear(context, toolbar('Workspaces', add), list);
  }

  function renderThreadsContext() {
    const add = iconButton('add', 'New thread', () => {
      selectThread(null);
      choose('threads');
      emit('focus-composer');
    }, { size: 'sm', disabled: !state.workspace });
    const filter = dropdown({
      label: 'Workspace',
      id: 'drawer-thread-workspace',
      value: state.workspace?.uuid || '',
      options: [{ value: '', label: 'Choose a workspace' }, ...state.workspaces.map((item) => ({ value: item.uuid, label: item.name }))],
      onChange: (uuid) => selectWorkspace(state.workspaces.find((item) => item.uuid === uuid) || null),
    });
    filter.select.dataset.key = 'thread-filter';
    const list = h('div', { class: 'list' });
    if (!state.workspace) list.append(emptyMessage('Choose a workspace first.'));
    else if (!state.threads.length) list.append(emptyMessage('No threads yet.'));
    state.threads.forEach((thread) => {
      const row = listRow({
        icon: 'chat',
        label: thread.title || 'Untitled thread',
        selected: thread.uuid === state.thread?.uuid,
        onClick: () => { selectThread(thread); choose('threads'); },
      });
      row.dataset.key = `th-${thread.uuid}`;
      list.append(row);
    });
    clear(context, filter.root, toolbar('Threads', add), list);
  }

  async function refreshTree() {
    if (state.section !== 'files' || !state.workspace) return;
    const key = '';
    if (tree.workspace !== state.workspace.uuid) resetTree();
    if (!tree.children.has(key) && !tree.loading.has(key)) await loadDirectory(key);
  }

  async function loadDirectory(path) {
    tree.loading.add(path);
    tree.error = '';
    renderContext();
    try {
      tree.children.set(path, await listFiles(state.workspace.uuid, tree.rootIndex, path));
    } catch (error) {
      tree.error = errorMessage(error);
      tree.expanded.delete(path);
    } finally {
      tree.loading.delete(path);
      renderContext();
    }
  }

  function renderFilesContext() {
    const roots = workspaceRoots(state.workspace);
    if (!state.workspace) return clear(context, toolbar('Files'), emptyMessage('Choose a workspace in Workspaces or Threads first.'));
    if (tree.workspace !== state.workspace.uuid) resetTree();
    if (!roots.length) return clear(context, toolbar('Files'), emptyMessage('This workspace has no configured folders.'));
    const folder = dropdown({
      label: 'Workspace folder',
      id: 'drawer-folder',
      value: String(tree.rootIndex),
      options: roots.map((path, index) => ({ value: String(index), label: path })),
      onChange: (value) => { Object.assign(tree, { rootIndex: Number(value), expanded: new Set(), children: new Map(), loading: new Set() }); set({ file: null }, 'selection'); refreshTree(); },
    });
    folder.select.dataset.key = 'folder-select';
    const list = h('div', { class: 'list', role: 'tree' });
    const walk = (path, depth) => {
      const entries = tree.children.get(path);
      if (!entries) return;
      entries.forEach((entry) => {
        const entryPath = entry.relativePath || entry.path || entry.name;
        const isDir = Boolean(entry.isDirectory);
        const open = isDir && tree.expanded.has(entryPath);
        const selected = !isDir && state.file?.entry === entryPath && state.file?.rootIndex === tree.rootIndex;
        const row = listRow({
          icon: isDir ? (open ? 'folderOpen' : 'folder') : 'document',
          label: entry.name,
          depth,
          selected,
          expanded: isDir ? open : null,
          onClick: () => {
            if (isDir) {
              if (open) tree.expanded.delete(entryPath);
              else {
                tree.expanded.add(entryPath);
                if (!tree.children.has(entryPath)) loadDirectory(entryPath);
              }
              renderContext();
            } else {
              set({ file: { rootIndex: tree.rootIndex, entry: entryPath, name: entry.name } }, 'selection');
              choose('files');
            }
          },
        });
        row.dataset.key = `file-${entryPath}`;
        list.append(row);
        if (open) walk(entryPath, depth + 1);
      });
    };
    walk('', 0);
    if (tree.loading.size && !tree.children.size) list.append(emptyMessage('Loading…'));
    else if (tree.children.get('') && !tree.children.get('').length) list.append(emptyMessage('No files in this folder.'));
    clear(context, folder.root, toolbar('Files'), tree.error && h('p', { class: 'form-error', role: 'alert', text: tree.error }), list);
  }

  function renderContext() {
    const active = document.activeElement;
    const key = panel.contains(active) ? active.dataset?.key : null;
    if (state.section === 'workspaces') renderWorkspacesContext();
    else if (state.section === 'files') renderFilesContext();
    else renderThreadsContext();
    if (key) panel.querySelector(`[data-key="${CSS.escape(key)}"]`)?.focus();
  }

  function renderFooter() {
    const user = state.account.user;
    const name = (user?.display_name || user?.displayName || '').trim() || user?.email || '';
    const selected = state.page === 'account';
    clear(footer,
      iconButton('settings', 'Settings', () => choose('settings'), { size: 'lg', filled: state.page === 'settings', className: state.page === 'settings' ? 'selected' : '' }),
      h('button', {
        type: 'button',
        class: `nav account${selected ? ' selected' : ''}`,
        aria: selected ? { current: 'page' } : {},
        on: { click: () => choose('account') },
      },
      fluentIcon('person', { filled: selected }),
      h('span', { class: 'account-text' },
        h('span', { class: 'account-name', text: name || 'Account' }),
        user && user.email && name !== user.email && h('small', { text: user.email }),
        !user && h('small', { text: state.account.status === 'anonymous' ? 'Not signed in' : 'Not connected' }))));
  }

  function render() {
    renderNav();
    renderContext();
    renderFooter();
  }

  for (const event of ['workspaces', 'threads', 'selection', 'account', 'section', 'page']) {
    on(event, () => {
      if (event === 'section' || event === 'page') refreshTree();
      if (event === 'selection' || event === 'workspaces') {
        if (tree.workspace !== (state.workspace?.uuid || null)) resetTree();
        refreshTree();
      }
      if (opened) render();
    });
  }
  render();

  return { root, open, close, isOpen: () => opened, toggle: () => (opened ? close() : open()) };
}
