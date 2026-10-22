// Handlers of the `browser` tool group. Runs in the extension page (side panel/popup).
import { RULES, scrubUrl } from './redact.js';
import { pageRun } from './pagescript.js';
import { activeTab, ensureAccess, getTab, restrictedReason, tabInfo, watchNavigation } from './common.js';

function httpUrl(raw) {
  let s = String(raw || '').trim();
  if (!s) throw new Error('url is required');
  if (!/^[a-z][a-z0-9+.-]*:/i.test(s)) s = 'https://' + s;
  let u;
  try {
    u = new URL(s);
  } catch {
    throw new Error('Invalid URL');
  }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') throw new Error('Only http(s) URLs are allowed.');
  return u.href;
}

async function runInPage(tab, op, params) {
  await ensureAccess(tab);
  let res;
  try {
    res = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      world: 'ISOLATED',
      func: pageRun,
      args: [op, params || {}, RULES],
    });
  } catch (e) {
    const m = String((e && e.message) || e);
    if (/cannot access|extensions gallery|error page|showing error/i.test(m)) throw new Error('cannot access this page (' + m + ')');
    throw new Error(m);
  }
  const r = res && res[0] && res[0].result;
  if (!r) throw new Error('No result from page.');
  if (!r.ok) throw new Error(r.error);
  return r.data;
}

async function afterNavigation(tabId, nav, grace) {
  const info = await nav.settle(grace);
  const t = await chrome.tabs.get(tabId);
  return { ...info, url: scrubUrl(t.url || ''), title: t.title || '', status: t.status };
}

const handlers = {
  async list_tabs(a) {
    const tabs = await chrome.tabs.query(a.current_window_only ? { lastFocusedWindow: true } : {});
    return { tabs: tabs.map(tabInfo) };
  },
  async get_active_tab() {
    return tabInfo(await activeTab());
  },
  async read_page(a) {
    return runInPage(await getTab(a.tab_id), 'read_page', a);
  },
  async find_in_page(a) {
    return runInPage(await getTab(a.tab_id), 'find_in_page', a);
  },
  async scroll(a) {
    return runInPage(await getTab(a.tab_id), 'scroll', a);
  },
  async wait_for(a) {
    return runInPage(await getTab(a.tab_id), 'wait_for', a);
  },
  async select_option(a) {
    return runInPage(await getTab(a.tab_id), 'select_option', a);
  },
  async type_text(a) {
    const tab = await getTab(a.tab_id);
    const nav = watchNavigation(tab.id);
    try {
      const out = await runInPage(tab, 'type_text', a);
      if (a.submit) Object.assign(out, await afterNavigation(tab.id, nav, 800));
      else nav.cancel();
      return out;
    } catch (e) {
      nav.cancel();
      throw e;
    }
  },
  async press_key(a) {
    const tab = await getTab(a.tab_id);
    const nav = watchNavigation(tab.id);
    try {
      const out = await runInPage(tab, 'press_key', a);
      return Object.assign(out, await afterNavigation(tab.id, nav, 600));
    } catch (e) {
      nav.cancel();
      throw e;
    }
  },
  async click(a) {
    const tab = await getTab(a.tab_id);
    const nav = watchNavigation(tab.id);
    try {
      const out = await runInPage(tab, 'click', a);
      return Object.assign(out, await afterNavigation(tab.id, nav, 800));
    } catch (e) {
      nav.cancel();
      throw e;
    }
  },
  async navigate(a) {
    const url = httpUrl(a.url);
    const tab = await getTab(a.tab_id);
    const nav = watchNavigation(tab.id);
    try {
      await chrome.tabs.update(tab.id, { url });
      return await afterNavigation(tab.id, nav, 3000);
    } catch (e) {
      nav.cancel();
      throw e;
    }
  },
  async go_back(a) {
    return historyMove(a, 'goBack');
  },
  async go_forward(a) {
    return historyMove(a, 'goForward');
  },
  async open_tab(a) {
    const url = a.url ? httpUrl(a.url) : undefined;
    const t = await chrome.tabs.create({ url, active: a.active !== false });
    if (url) {
      const nav = watchNavigation(t.id);
      const info = await afterNavigation(t.id, nav, 500);
      return { tab_id: t.id, ...info };
    }
    return { tab_id: t.id, url: '', title: '' };
  },
  async switch_tab(a) {
    if (!Number.isInteger(a.tab_id)) throw new Error('tab_id is required');
    const t = await chrome.tabs.update(a.tab_id, { active: true });
    await chrome.windows.update(t.windowId, { focused: true });
    return tabInfo(await chrome.tabs.get(a.tab_id));
  },
  async close_tab(a) {
    if (!Number.isInteger(a.tab_id)) throw new Error('tab_id is required');
    const t = await getTab(a.tab_id);
    await chrome.tabs.remove(a.tab_id);
    return { closed: true, tab_id: a.tab_id, title: t.title || '' };
  },
};

async function historyMove(a, method) {
  const tab = await getTab(a.tab_id);
  const why = restrictedReason(tab.url);
  if (why) throw new Error(why);
  const nav = watchNavigation(tab.id);
  try {
    await chrome.tabs[method](tab.id);
  } catch (e) {
    nav.cancel();
    throw new Error('No history entry to go ' + (method === 'goBack' ? 'back' : 'forward') + ' to.');
  }
  return afterNavigation(tab.id, nav, 1500);
}

export async function callBrowserTool(name, args) {
  const h = handlers[name];
  if (!h) throw new Error('Unknown browser tool: ' + name);
  return h(args && typeof args === 'object' ? args : {});
}
