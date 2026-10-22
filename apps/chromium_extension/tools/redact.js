// Shared privacy/redaction rules for every tool result. Pure functions only (no chrome.* or DOM
// globals), so they can be unit tested in node (see redact.test.mjs).
//
// Password data must never leave the page. The page-side script (pagescript.js) carries a
// byte-identical copy of `descriptorSensitive` because injected functions cannot import; the
// test file checks that the copy and this module agree.

/** Data-only rules; serialisable so they can be passed to injected page functions. */
export const RULES = {
  sensitiveTypes: ['password'],
  // autocomplete tokens that mark secret inputs
  autocompleteRe: 'password|one-time-code|cc-number|cc-csc|cc-exp',
  // substrings of name/id/aria-label/placeholder/label that mark secret inputs
  compoundRe:
    'passw(or)?d|pass[-_]?phrase|pass[-_]?code|pwd|secret|cvv|cvc|card[-_]?num|security[-_]?code|private[-_]?key|api[-_]?key',
  // whole words (after camelCase / punctuation splitting) that mark secret inputs
  tokens: ['pass', 'otp', 'totp', 'pin', '2fa', 'mfa'],
  // csrf-style tokens: sensitive when type=hidden or autocomplete=off
  csrfRe: 'csrf|xsrf|nonce|authenticity|(^|[^a-z])token([^a-z]|$)',
};

// BEGIN descriptorSensitive
const descriptorSensitive = (d, rules) => {
  const type = String(d.type || '').toLowerCase();
  if (rules.sensitiveTypes.indexOf(type) >= 0 || type === 'hidden') return true;
  const ac = String(d.autocomplete || '').toLowerCase();
  if (ac && new RegExp(rules.autocompleteRe).test(ac)) return true;
  const fields = [d.name, d.id, d.ariaLabel, d.placeholder, d.label];
  for (let i = 0; i < fields.length; i++) {
    if (!fields[i]) continue;
    const s = String(fields[i]);
    if (new RegExp(rules.compoundRe, 'i').test(s)) return true;
    const toks = s.replace(/([a-z0-9])([A-Z])/g, '$1 $2').toLowerCase().split(/[^a-z0-9]+/);
    for (let j = 0; j < toks.length; j++) if (rules.tokens.indexOf(toks[j]) >= 0) return true;
  }
  if (ac === 'off') {
    const csrf = new RegExp(rules.csrfRe, 'i');
    if ((d.name && csrf.test(String(d.name))) || (d.id && csrf.test(String(d.id)))) return true;
  }
  return false;
};
// END descriptorSensitive

/**
 * @param {{type?:string,autocomplete?:string,name?:string,id?:string,ariaLabel?:string,
 *          placeholder?:string,label?:string}} d
 */
export function isSensitiveDescriptor(d) {
  return descriptorSensitive(d || {}, RULES);
}

/** DOM-ish element (anything with getAttribute); used by tests and extension-side helpers. */
export function isSensitiveControl(el) {
  if (!el || typeof el.getAttribute !== 'function') return false;
  const g = (n) => el.getAttribute(n) || '';
  const labelNode = el.labels && el.labels[0];
  return isSensitiveDescriptor({
    type: g('type') === 'password' ? 'password' : el.type || g('type'),
    autocomplete: g('autocomplete'),
    name: g('name'),
    id: g('id'),
    ariaLabel: g('aria-label'),
    placeholder: g('placeholder'),
    label: labelNode ? labelNode.textContent : '',
  });
}

const SECRET_PARAM_RE =
  /(token|passw|pwd|secret|session|^code$|^key$|[_-]key$|apikey|^sid$|^sig$|signature|^auth|otp|jwt|bearer|credential|csrf|xsrf|nonce|ticket)/i;
const REDACTED = 'REDACTED';

function scrubParams(params) {
  let changed = false;
  for (const k of Array.from(new Set(params.keys()))) {
    if (SECRET_PARAM_RE.test(k)) {
      params.set(k, REDACTED);
      changed = true;
    }
  }
  return changed;
}

/** Strip userinfo and secret-looking query/fragment parameters from a URL string. */
export function scrubUrl(input) {
  if (typeof input !== 'string' || !input) return input;
  if (/^data:/i.test(input)) return 'data:[omitted]';
  if (/^javascript:/i.test(input)) return 'javascript:[omitted]';
  let u;
  try {
    u = new URL(input);
  } catch {
    return scrubText(input);
  }
  u.username = '';
  u.password = '';
  const q = new URLSearchParams(u.search);
  if (scrubParams(q)) u.search = q.toString();
  if (u.hash.indexOf('=') > 0) {
    const h = new URLSearchParams(u.hash.slice(1));
    if (scrubParams(h)) u.hash = h.toString();
  }
  return u.toString();
}

const TEXT_RULES = [
  [/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*/g, '[redacted-jwt]'],
  [/\bBearer\s+[A-Za-z0-9._~+/-]{12,}=*/gi, 'Bearer [redacted]'],
  [/\b(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}/g, '[redacted-key]'],
  [/\bAKIA[0-9A-Z]{16}\b/g, '[redacted-key]'],
  [/\bgh[pousr]_[A-Za-z0-9]{30,}/g, '[redacted-key]'],
  [
    /\b(password|passwd|pwd|secret|token|api[_-]?key)(\s*[:=]\s*)(?!\[redacted)\S+/gi,
    '$1$2[redacted]',
  ],
];

/** Scrub secret-looking substrings from free text. */
export function scrubText(s) {
  if (typeof s !== 'string' || !s) return s;
  let out = s;
  for (const [re, rep] of TEXT_RULES) out = out.replace(re, rep);
  return out;
}

/** Value of a control for the model: undefined when the control is sensitive. */
export function scrubValue(descriptor, value) {
  if (isSensitiveDescriptor(descriptor)) return undefined;
  return typeof value === 'string' ? scrubText(value) : value;
}

const SECRET_KEY_RE =
  /(passw|pwd|secret|token|api[_-]?key|authorization|cookie|credential|session[_-]?id|private[_-]?key)/i;
const URL_KEY_RE = /^(url|href|src|origin|link|action|referrer)$/i;

/** Deep-scrub a JSON value: URLs, free text, and values under secret-named keys. */
export function sanitizeResult(value, key = '') {
  if (typeof value === 'string') {
    if (key && SECRET_KEY_RE.test(key)) return '[redacted]';
    if (URL_KEY_RE.test(key) || /^https?:\/\/\S+$/i.test(value)) return scrubText(scrubUrl(value));
    return scrubText(value);
  }
  if (Array.isArray(value)) return value.map((v) => sanitizeResult(v, key));
  if (value && typeof value === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(value)) {
      if (value.redacted === true && k === 'value') continue;
      out[k] = sanitizeResult(v, k);
    }
    return out;
  }
  return value;
}

export const MAX_TEXT = 60000;
export const MAX_LIST = 200;
const MAX_TOTAL = 200000;

/** Truncate long strings / long lists (marking `truncated:true` on the owner) and cap total size. */
export function bound(value) {
  const walk = (v, owner) => {
    if (typeof v === 'string') {
      if (v.length > MAX_TEXT) {
        if (owner) owner.truncated = true;
        return v.slice(0, MAX_TEXT);
      }
      return v;
    }
    if (Array.isArray(v)) {
      let a = v;
      if (a.length > MAX_LIST) {
        if (owner) owner.truncated = true;
        a = a.slice(0, MAX_LIST);
      }
      return a.map((x) => walk(x, owner));
    }
    if (v && typeof v === 'object') {
      const out = {};
      for (const [k, x] of Object.entries(v)) out[k] = walk(x, out);
      return out;
    }
    return v;
  };
  let out = walk(value && typeof value === 'object' ? value : { value }, null);
  let json;
  try {
    json = JSON.stringify(out);
  } catch {
    return { truncated: true, content: String(value).slice(0, MAX_TEXT) };
  }
  if (json.length > MAX_TOTAL) out = { truncated: true, content: json.slice(0, MAX_TEXT) };
  return out;
}
