// Tool bridge: registers browser + WebMCP tools with the engine and answers client.tool.request frames.
//
//   const bridge = createToolBridge({ sendFrame, getConfig });
//   bridge.register();            // after the events socket is open
//   socket.onmessage = (m) => bridge.handleFrame(JSON.parse(m.data));
//   bridge.dispose();             // on disconnect / teardown
import { BROWSER_TOOLS } from './definitions.js';
import { callBrowserTool } from './browser.js';
import { createWebMcpWatcher } from './webmcp.js';
import { bound, sanitizeResult, scrubText } from './redact.js';
import { withTimeout } from './common.js';

export { requestSiteAccess } from './common.js';

const REQUEST_TIMEOUT_MS = 50000; // engine waits 60 s
const BROWSER_IDS = new Set(BROWSER_TOOLS.map((t) => t.id));

function registerFrame(id, group, title, tools) {
  return { v: 1, type: 'tool.register', id, data: { group, title, tools } };
}

function toWire(t) {
  return {
    id: t.id,
    description: t.description,
    input_schema: t.input_schema,
    operation: t.operation,
    read_only: t.operation === 'read',
  };
}

/**
 * @param {{sendFrame:(frame:object)=>void, getConfig?:()=>any}} opts
 *        getConfig is accepted for the host app's use; the bridge currently needs no configuration.
 */
export function createToolBridge({ sendFrame, getConfig } = {}) {
  let disposed = false;
  const send = (frame) => {
    try {
      if (typeof sendFrame === 'function') sendFrame(frame);
    } catch {
      /* socket may be closed */
    }
  };
  const webmcp = createWebMcpWatcher({
    onChange: (tools) => {
      if (!disposed) send(registerFrame('webmcp-tools', 'webmcp', 'Page tools (WebMCP)', tools));
    },
  });

  async function run(data) {
    const name = String(data.tool_name || '');
    const args = data.arguments && typeof data.arguments === 'object' ? data.arguments : {};
    const group = data.group || 'browser';
    let result;
    if (group === 'webmcp') result = await webmcp.execute(name, args);
    else if (group === 'browser' && BROWSER_IDS.has(name)) result = await callBrowserTool(name, args);
    else throw new Error(`Unknown tool ${group}/${name}`);
    return bound(sanitizeResult(result));
  }

  async function answer(frame) {
    const data = frame.data || {};
    let payload;
    try {
      const result = await withTimeout(run(data), REQUEST_TIMEOUT_MS, 'Tool timed out');
      payload = { request_id: data.request_id, ok: true, result };
    } catch (e) {
      payload = { request_id: data.request_id, ok: false, error: scrubText(String((e && e.message) || e)).slice(0, 1000) };
    }
    if (!disposed) send({ v: 1, type: 'client.tool.result', id: frame.id, data: payload });
  }

  return {
    register() {
      if (disposed) return;
      send(registerFrame('browser-tools', 'browser', 'Browser', BROWSER_TOOLS.map(toWire)));
      webmcp.start();
    },
    handleFrame(frame) {
      try {
        if (!frame || frame.type !== 'client.tool.request') return false;
        answer(frame).catch(() => {});
        return true;
      } catch {
        return false;
      }
    },
    dispose() {
      if (disposed) return;
      webmcp.stop();
      send(registerFrame('browser-tools', 'browser', 'Browser', []));
      send(registerFrame('webmcp-tools', 'webmcp', 'Page tools (WebMCP)', []));
      disposed = true;
    },
  };
}
