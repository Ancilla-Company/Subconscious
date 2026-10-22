// WebMCP support (Chrome origin trial): exposes tools a page registers through
// `document.modelContext` as the `webmcp` tool group. All WebMCP API calls live in this file so
// API changes stay isolated. Everything feature-detects and no-ops when the API is absent.
import { ensureAccess, hasSiteAccess, originOf, restrictedReason, activeTab } from './common.js';

const ID_RE = /^[A-Za-z][A-Za-z0-9_.\-]{0,63}$/;
const POLL_MS = 3000;
const DEBOUNCE_MS = 300;
const EXEC_TIMEOUT_MS = 45000;

// ---- code injected into the page's MAIN world (must be self-contained) ----

async function pageListTools() {
  const mc = document.modelContext;
  if (!mc || typeof mc.getTools !== 'function') return { supported: false };
  const safe = (v) => {
    try {
      const x = JSON.parse(JSON.stringify(v === undefined ? null : v));
      return x;
    } catch {
      return null;
    }
  };
  let list;
  try {
    list = await mc.getTools();
  } catch (e) {
    return { supported: true, origin: location.origin, tools: [], error: String((e && e.message) || e) };
  }
  const tools = [];
  for (const t of Array.from(list || [])) {
    if (!t || typeof t.name !== 'string') continue;
    let schema = t.inputSchema;
    if (typeof schema === 'string') {
      try {
        schema = JSON.parse(schema);
      } catch {
        schema = null;
      }
    }
    tools.push({
      name: t.name,
      description: typeof t.description === 'string' ? t.description : '',
      inputSchema: safe(schema),
      annotations: safe(t.annotations) || {},
    });
  }
  return { supported: true, origin: location.origin, tools };
}

async function pageExecuteTool(name, args, timeoutMs) {
  const mc = document.modelContext;
  if (!mc || typeof mc.getTools !== 'function' || typeof mc.executeTool !== 'function') {
    return { ok: false, error: 'WebMCP is not available on this page.' };
  }
  // executeTool needs a tool object obtained from this very document.
  const tools = Array.from((await mc.getTools()) || []);
  const tool = tools.find((t) => t && t.name === name);
  if (!tool) return { ok: false, error: 'Tool "' + name + '" is no longer registered on this page.' };
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), timeoutMs);
  try {
    const r = await mc.executeTool(tool, args || {}, { signal: ac.signal });
    const seen = new WeakSet();
    let json;
    try {
      json = JSON.stringify(r === undefined ? null : r, (k, v) => {
        if (v && typeof v === 'object') {
          if (seen.has(v)) return '[circular]';
          seen.add(v);
        }
        return typeof v === 'bigint' ? String(v) : v;
      });
    } catch {
      json = JSON.stringify(String(r));
    }
    return { ok: true, result: json === undefined ? null : JSON.parse(json) };
  } catch (e) {
    return { ok: false, error: String((e && e.message) || e) };
  } finally {
    clearTimeout(timer);
  }
}

// ---- extension side ----

export function sanitizeToolId(name, used) {
  let id = String(name).replace(/[^A-Za-z0-9_.\-]/g, '_');
  if (!/^[A-Za-z]/.test(id)) id = 't_' + id;
  id = id.slice(0, 60);
  let out = id;
  let n = 2;
  while (used.has(out)) out = id + '_' + n++;
  used.add(out);
  return out;
}

export function operationFor(annotations) {
  const a = annotations || {};
  if (a.readOnlyHint === true) return 'read';
  if (a.consequentialHint === true) return 'delete';
  return 'update';
}

export function toRegistration(tabId, origin, pageTools) {
  const used = new Set();
  const map = new Map();
  const tools = [];
  for (const t of pageTools.slice(0, 64)) {
    const a = t.annotations || {};
    if (a.debugging === true) continue;
    const id = sanitizeToolId(t.name, used);
    if (!ID_RE.test(id)) continue;
    const op = operationFor(a);
    let schema = t.inputSchema;
    if (!schema || typeof schema !== 'object' || Array.isArray(schema)) schema = { type: 'object', properties: {} };
    else schema = { ...schema, type: 'object' };
    if (JSON.stringify(schema).length > 30000) schema = { type: 'object', additionalProperties: true };
    const prefix = a.untrustedContentHint === true ? 'Returns untrusted page content. ' : '';
    const description = `${prefix}${t.description || t.name} (WebMCP page tool from ${origin})`.slice(0, 2000);
    const entry = { id, description, input_schema: schema, operation: op, read_only: op === 'read' };
    tools.push(entry);
    map.set(id, { tabId, name: t.name, origin, untrusted: a.untrustedContentHint === true });
  }
  return { tools, map };
}

/**
 * @param {{onChange:(tools:object[])=>void}} opts onChange receives the full `webmcp` tool list
 *        (possibly empty) whenever it actually changes.
 */
export function createWebMcpWatcher({ onChange }) {
  let started = false;
  let map = new Map();
  let lastSig = '[]';
  let timer = null;
  let poll = null;
  let busy = false;
  const listeners = [];

  async function snapshot() {
    if (typeof chrome === 'undefined' || !chrome.scripting) return { tabId: null, origin: null, tools: [] };
    let tab;
    try {
      tab = await activeTab();
    } catch {
      return { tabId: null, origin: null, tools: [] };
    }
    const origin = originOf(tab.url || '');
    if (!origin || restrictedReason(tab.url) || tab.status === 'loading' || !(await hasSiteAccess(origin))) {
      return { tabId: tab.id, origin, tools: [] };
    }
    try {
      const res = await chrome.scripting.executeScript({ target: { tabId: tab.id }, world: 'MAIN', func: pageListTools });
      const r = res && res[0] && res[0].result;
      if (!r || !r.supported) return { tabId: tab.id, origin, tools: [] };
      return { tabId: tab.id, origin: r.origin || origin, tools: r.tools || [] };
    } catch {
      return { tabId: tab.id, origin, tools: [] };
    }
  }

  async function refresh() {
    if (!started || busy) return;
    busy = true;
    try {
      const snap = await snapshot();
      const reg = toRegistration(snap.tabId, snap.origin, snap.tools);
      const sig = reg.tools.length ? JSON.stringify([snap.tabId, reg.tools]) : '[]';
      map = reg.map;
      if (sig !== lastSig) {
        lastSig = sig;
        onChange(reg.tools);
      }
    } finally {
      busy = false;
    }
  }

  function schedule() {
    clearTimeout(timer);
    timer = setTimeout(refresh, DEBOUNCE_MS);
  }

  function listen(target, name, fn) {
    if (!target || !target[name]) return;
    target[name].addListener(fn);
    listeners.push(() => target[name].removeListener(fn));
  }

  return {
    start() {
      if (started || typeof chrome === 'undefined' || !chrome.tabs) return;
      started = true;
      listen(chrome.tabs, 'onActivated', schedule);
      listen(chrome.tabs, 'onUpdated', (id, change) => {
        if (change.status === 'complete' || change.url) schedule();
      });
      listen(chrome.tabs, 'onRemoved', schedule);
      listen(chrome.windows, 'onFocusChanged', schedule);
      // No extension-visible `toolchange` channel from MAIN world without a content script, so poll
      // while the extension page is visible.
      poll = setInterval(() => {
        if (typeof document === 'undefined' || document.visibilityState === 'visible') refresh();
      }, POLL_MS);
      schedule();
    },
    stop() {
      started = false;
      clearTimeout(timer);
      clearInterval(poll);
      listeners.splice(0).forEach((f) => f());
      map = new Map();
      lastSig = '[]';
    },
    refresh,
    /** Execute a registered page tool by its registered id. Returns the (unsanitised) JSON result. */
    async execute(id, args) {
      const m = map.get(id);
      if (!m) throw new Error('This page tool is no longer available (the active page changed).');
      let tab;
      try {
        tab = await chrome.tabs.get(m.tabId);
      } catch {
        throw new Error('The tab that offered this tool was closed.');
      }
      if (originOf(tab.url || '') !== m.origin) throw new Error('The tab navigated away from ' + m.origin + '; tool unavailable.');
      await ensureAccess(tab);
      const res = await chrome.scripting.executeScript({
        target: { tabId: m.tabId },
        world: 'MAIN',
        func: pageExecuteTool,
        args: [m.name, args && typeof args === 'object' ? args : {}, EXEC_TIMEOUT_MS],
      });
      const r = res && res[0] && res[0].result;
      if (!r) throw new Error('No result from page tool.');
      if (!r.ok) throw new Error(r.error);
      return m.untrusted ? { untrusted: true, source: m.origin, content: r.result } : r.result;
    },
  };
}
