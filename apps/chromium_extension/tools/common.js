// Shared helpers for tab access, special-page detection and site permissions.
import { scrubText, scrubUrl } from './redact.js';

export function originOf(url) {
  try {
    const u = new URL(url);
    return u.protocol === 'http:' || u.protocol === 'https:' ? u.origin : null;
  } catch {
    return null;
  }
}

/** Returns a human readable reason when the tab cannot be scripted, else null. */
export function restrictedReason(url) {
  if (!url) return 'cannot access this page (no URL; the tab may still be loading or needs the tabs permission)';
  let u;
  try {
    u = new URL(url);
  } catch {
    return 'cannot access this page (invalid URL)';
  }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') {
    return `cannot access this page (${u.protocol.replace(':', '')}: pages are not scriptable)`;
  }
  if (u.hostname === 'chromewebstore.google.com' || (u.hostname === 'chrome.google.com' && u.pathname.startsWith('/webstore'))) {
    return 'cannot access this page (Chrome Web Store)';
  }
  if (/\.pdf$/i.test(u.pathname)) return 'cannot access this page (PDF viewer)';
  return null;
}

export async function hasSiteAccess(origin) {
  try {
    return await chrome.permissions.contains({ origins: [origin + '/*'] });
  } catch {
    return false;
  }
}

/**
 * Ask for access to an origin. Only succeeds inside a user gesture (call it from a button handler).
 * @returns {Promise<boolean>}
 */
export async function requestSiteAccess(origin) {
  const o = originOf(origin) || originOf(origin + '/');
  if (!o) return false;
  try {
    return await chrome.permissions.request({ origins: [o + '/*'] });
  } catch {
    return false;
  }
}

/** Throws a readable Error unless the tab is scriptable and site access is granted. */
export async function ensureAccess(tab) {
  const why = restrictedReason(tab.url);
  if (why) throw new Error(why);
  const origin = originOf(tab.url);
  if (await hasSiteAccess(origin)) return origin;
  if (await requestSiteAccess(origin)) return origin;
  throw new Error(`Grant access to ${origin} in the extension (Site access)`);
}

/** The tab the user is looking at (ignores the extension's own pages). */
export async function activeTab() {
  const isOwn = (t) => !t.url || t.url.startsWith('chrome-extension://') || t.url.startsWith(chrome.runtime.getURL(''));
  let tabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  let t = tabs.find((x) => !isOwn(x));
  if (!t) {
    tabs = await chrome.tabs.query({ active: true });
    t = tabs.find((x) => !isOwn(x)) || tabs[0];
  }
  if (!t) throw new Error('No active tab found.');
  return t;
}

export async function getTab(tabId) {
  if (Number.isInteger(tabId)) {
    try {
      return await chrome.tabs.get(tabId);
    } catch {
      throw new Error(`No tab with id ${tabId}.`);
    }
  }
  return activeTab();
}

export function tabInfo(t) {
  return {
    id: t.id,
    window_id: t.windowId,
    index: t.index,
    active: !!t.active,
    title: scrubText(t.title || ''),
    url: scrubUrl(t.url || t.pendingUrl || ''),
    status: t.status,
    pinned: !!t.pinned,
    audible: !!t.audible,
  };
}

/** Watches a tab for a navigation started by an action and resolves when it completes. */
export function watchNavigation(tabId) {
  let sawLoading = false;
  let complete = false;
  let wake = null;
  const listener = (id, change) => {
    if (id !== tabId) return;
    if (change.status === 'loading') sawLoading = true;
    if (change.status === 'complete') {
      complete = true;
      if (wake) wake();
    }
  };
  chrome.tabs.onUpdated.addListener(listener);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  return {
    /** @param graceMs how long to wait for a navigation to start. */
    async settle(graceMs = 800, timeoutMs = 15000) {
      try {
        const until = Date.now() + graceMs;
        while (!sawLoading && Date.now() < until) await sleep(50);
        if (!sawLoading) return { navigated: false };
        if (!complete) {
          await Promise.race([new Promise((r) => (wake = r)), sleep(timeoutMs)]);
        }
        return { navigated: true, timed_out: !complete };
      } finally {
        chrome.tabs.onUpdated.removeListener(listener);
      }
    },
    cancel() {
      chrome.tabs.onUpdated.removeListener(listener);
    },
  };
}

export function withTimeout(promise, ms, message) {
  let timer;
  const t = new Promise((_, rej) => {
    timer = setTimeout(() => rej(new Error(message)), ms);
  });
  return Promise.race([promise, t]).finally(() => clearTimeout(timer));
}
