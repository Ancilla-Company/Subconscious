// App shell: top app bar, full-height main area, and the flyout drawer.
import { createChatView } from './chat.js';
import { createDrawer } from './drawer.js';
import { clear, h, iconButton, statusDot } from './dom.js';
import { MODE, errorMessage, on, set, state } from './state.js';
import { renderAccount } from './views/account.js';
import { renderFiles } from './views/files.js';
import { renderSettings } from './views/settings.js';
import { renderWorkspaces } from './views/workspaces.js';

const SECTIONS = new Set(['workspaces', 'threads', 'files']);
const STATUS = {
  connected: ['connected', 'Connected'],
  connecting: ['connecting', 'Connecting'],
  disconnected: ['disconnected', 'Disconnected'],
};

export function mountShell(root) {
  const chat = createChatView();
  const pageHost = h('div', { class: 'page-host' });
  const main = h('main', { class: 'main', id: 'main' }, chat.root, pageHost);

  const menu = iconButton('navigation', 'Open menu', () => drawer.toggle(), { className: 'menu-btn' });
  menu.setAttribute('aria-haspopup', 'dialog');
  menu.setAttribute('aria-expanded', 'false');
  const dotSlot = h('span', { class: 'status-slot' });
  const statusLabel = h('span', { class: 'status-label', role: 'status' });
  const appbar = h('header', { class: 'appbar' }, menu, h('strong', { class: 'appbar-title', text: 'Subconscious' }), h('span', { class: 'appbar-status' }, dotSlot, statusLabel));

  if (MODE === 'popup' && chrome.sidePanel?.open) {
    appbar.append(iconButton('panelRight', 'Open in side panel', async () => {
      try {
        const current = await chrome.windows.getCurrent();
        await chrome.sidePanel.open({ windowId: current.id });
        window.close();
      } catch (error) {
        set({ notice: errorMessage(error) });
      }
    }));
  }

  const shell = h('div', { class: 'shell' }, appbar, main);
  const drawer = createDrawer({
    navigate,
    onOpenChange(open) {
      shell.inert = open;
      menu.setAttribute('aria-expanded', String(open));
    },
  });
  root.append(shell, drawer.root);

  function renderStatus() {
    const [kind, label] = STATUS[state.connection] || STATUS.disconnected;
    clear(dotSlot, statusDot(kind, label));
    statusLabel.textContent = label;
  }

  let focusCreate = false;

  function renderPage() {
    const page = state.page;
    const onChat = page === 'threads';
    chat.root.classList.toggle('hidden', !onChat);
    pageHost.classList.toggle('hidden', onChat);
    if (onChat) return;
    const view = page === 'workspaces' ? renderWorkspaces({ focusCreate })
      : page === 'files' ? renderFiles()
        : page === 'settings' ? renderSettings()
          : renderAccount();
    focusCreate = false;
    clear(pageHost, view);
  }

  function typing() {
    const active = document.activeElement;
    return pageHost.contains(active) && /^(INPUT|TEXTAREA|SELECT)$/.test(active.tagName);
  }

  function navigate(page, options = {}) {
    focusCreate = Boolean(options.create);
    if (SECTIONS.has(page)) state.section = page;
    set({ page }, 'page');
    renderPage();
    main.scrollTop = 0;
  }

  // Refresh the visible page when data changes, but never while the user is typing.
  for (const event of ['config', 'account', 'workspaces', 'selection', 'change']) {
    on(event, () => { renderStatus(); if (!typing()) renderPage(); });
  }
  on('navigate', ({ page }) => navigate(page));
  on('focus-composer', () => setTimeout(() => chat.focus(), 0));

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && drawer.isOpen()) drawer.close();
  });

  renderStatus();
  renderPage();
  return { navigate, drawer };
}
