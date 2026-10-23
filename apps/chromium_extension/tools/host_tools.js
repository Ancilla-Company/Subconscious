// JS host for the embedded Flutter app: builds `globalThis.subconsciousExtension`
// (contract: .agents/tasks/extension-tools-pairing/contracts.md section 5).
// Everything crossing the boundary is a JSON string or primitive. callTool never rejects.
import { BROWSER_TOOLS } from './definitions.js';
import { callBrowserTool } from './browser.js';
import { createWebMcpWatcher } from './webmcp.js';
import { bound, sanitizeResult, scrubText } from './redact.js';
import { withTimeout, requestSiteAccess } from './common.js';

const REQUEST_TIMEOUT_MS = 50000; // engine waits 60 s
const BROWSER_IDS = new Set(BROWSER_TOOLS.map((t) => t.id));
const STORAGE_KEY = 'connection';

function toWire(t) {
  return {
    id: t.id,
    description: t.description,
    input_schema: t.input_schema,
    operation: t.operation,
    read_only: t.operation === 'read',
  };
}

function parseOrigins(json) {
  try {
    const v = JSON.parse(json);
    const list = Array.isArray(v) ? v : Array.isArray(v && v.origins) ? v.origins : [];
    return list.filter((s) => typeof s === 'string');
  } catch {
    return [];
  }
}

function errText(e) {
  return scrubText(String((e && e.message) || e)).slice(0, 1000);
}

export function createHost() {
  let webmcpTools = [];
  const listeners = new Set();

  const groups = () => {
    const out = [{ group: 'browser', title: 'Browser', tools: BROWSER_TOOLS.map(toWire) }];
    if (webmcpTools.length) out.push({ group: 'webmcp', title: 'Page tools (WebMCP)', tools: webmcpTools });
    return JSON.stringify(out);
  };

  const webmcp = createWebMcpWatcher({
    onChange: (tools) => {
      webmcpTools = tools;
      const json = groups();
      for (const cb of [...listeners]) {
        try {
          cb(json);
        } catch {
          /* listener errors must not break the host */
        }
      }
    },
  });

  async function run(group, id, args) {
    let result;
    if (group === 'webmcp') result = await webmcp.execute(id, args);
    else if (group === 'browser' && BROWSER_IDS.has(id)) result = await callBrowserTool(id, args);
    else throw new Error(`Unknown tool ${group}/${id}`);
    return bound(sanitizeResult(result));
  }

  const host = {
    version: 1,
    get mode() {
      const m = globalThis.__SUBCONSCIOUS_EXTENSION__;
      return m && m.mode === 'panel' ? 'panel' : 'popup';
    },
    extensionVersion: chrome.runtime.getManifest().version,
    extensionOrigin: location.origin,

    /**
     * Claims the lowest free "instance slot" (0, 1, ...) for as long as this page
     * lives. The popup, the side panel and a second window's side panel are all
     * the same extension origin and would otherwise share ONE hive node identity,
     * which the engine treats as a single client (the second hello is rejected as
     * "Client_ID already in use"). Each concurrently open page therefore gets its
     * own slot, and the app keeps a separate node identity per slot. The Web Locks
     * API releases a lock when its page closes, so slots are reused. Falls back
     * to slot 0 when the API is missing or every slot is taken.
     */
    async acquireInstanceSlot(max) {
      const limit = Math.max(1, Math.min(Number(max) || 4, 8));
      const locks = globalThis.navigator && globalThis.navigator.locks;
      if (!locks || !locks.request) return 0;
      for (let slot = 0; slot < limit; slot += 1) {
        const claimed = await new Promise((resolve) => {
          locks
            .request(`subconscious-instance-${slot}`, { ifAvailable: true }, (lock) => {
              if (!lock) {
                resolve(false);
                return undefined;
              }
              resolve(true);
              return new Promise(() => {}); // hold the lock until the page is closed
            })
            .catch(() => resolve(false));
        });
        if (claimed) return slot;
      }
      return 0;
    },

    async getConnection() {
      try {
        const r = await chrome.storage.local.get(STORAGE_KEY);
        return JSON.stringify(r[STORAGE_KEY] ?? null);
      } catch {
        return 'null';
      }
    },
    async setConnection(json) {
      const patch = JSON.parse(json);
      const r = await chrome.storage.local.get(STORAGE_KEY);
      const merged = { ...(r[STORAGE_KEY] || {}), ...(patch && typeof patch === 'object' ? patch : {}) };
      await chrome.storage.local.set({ [STORAGE_KEY]: merged });
    },
    async clearConnection() {
      await chrome.storage.local.remove(STORAGE_KEY);
    },

    async requestOrigins(originsJson) {
      const origins = parseOrigins(originsJson);
      if (!origins.length) return false;
      try {
        return await chrome.permissions.request({ origins });
      } catch {
        return false;
      }
    },
    async hasOrigins(originsJson) {
      const origins = parseOrigins(originsJson);
      if (!origins.length) return false;
      try {
        return await chrome.permissions.contains({ origins });
      } catch {
        return false;
      }
    },

    toolGroups: groups,
    onToolGroupsChanged(cb) {
      if (typeof cb !== 'function') return () => {};
      listeners.add(cb);
      return () => listeners.delete(cb);
    },
    async callTool(group, id, argsJson) {
      try {
        let args = {};
        if (argsJson) {
          const parsed = JSON.parse(argsJson);
          if (parsed && typeof parsed === 'object') args = parsed;
        }
        const result = await withTimeout(run(String(group), String(id), args), REQUEST_TIMEOUT_MS, 'Tool timed out');
        return JSON.stringify({ ok: true, result: result === undefined ? null : result });
      } catch (e) {
        return JSON.stringify({ ok: false, error: errText(e) });
      }
    },
    setVisible(visible) {
      try {
        if (visible) webmcp.start();
        else webmcp.stop();
      } catch {
        /* ignore */
      }
    },
    async openSidePanel() {
      try {
        if (host.mode !== 'popup' || !chrome.sidePanel || !chrome.sidePanel.open) return false;
        const win = await chrome.windows.getCurrent();
        await chrome.sidePanel.open({ windowId: win.id });
        return true;
      } catch {
        return false;
      }
    },
    async requestSiteAccess(origin) {
      try {
        return await requestSiteAccess(String(origin));
      } catch {
        return false;
      }
    },
  };
  return host;
}
