import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import {
  RULES, isSensitiveDescriptor, isSensitiveControl, scrubUrl, scrubText, scrubValue, sanitizeResult, bound,
} from './redact.js';
import { sanitizeToolId, operationFor, toRegistration } from './webmcp.js';
import { BROWSER_TOOLS } from './definitions.js';

const S = (d) => isSensitiveDescriptor(d);

test('sensitive descriptors', () => {
  assert.ok(S({ type: 'password' }));
  assert.ok(S({ type: 'PASSWORD' }));
  assert.ok(S({ type: 'hidden', name: 'x' }));
  for (const ac of ['current-password', 'new-password', 'one-time-code', 'cc-number', 'cc-csc', 'cc-exp', 'cc-exp-month']) {
    assert.ok(S({ type: 'text', autocomplete: ac }), ac);
  }
  for (const name of ['password', 'user_passwd', 'confirmPassword', 'pwd', 'client-secret', 'otp', 'cvv', 'cvc', 'pin', 'userPin', 'api_key']) {
    assert.ok(S({ type: 'text', name }), name);
    assert.ok(S({ type: 'text', id: name }), name);
    assert.ok(S({ type: 'text', ariaLabel: name }), name);
  }
  assert.ok(S({ type: 'text', label: 'Enter your PIN' }));
  assert.ok(S({ type: 'text', placeholder: 'Password' }));
  // show-password toggle turned the input into type=text: heuristics still catch it
  assert.ok(S({ type: 'text', name: 'login_password' }));
  assert.ok(S({ type: 'text', autocomplete: 'off', name: 'csrf_token' }));
  assert.ok(S({ type: 'text', autocomplete: 'off', id: 'nonce' }));
});

test('ordinary fields are not sensitive', () => {
  for (const d of [
    { type: 'text', name: 'email' },
    { type: 'text', name: 'shippingAddress' },
    { type: 'text', name: 'spinner' },
    { type: 'text', name: 'passenger' },
    { type: 'text', name: 'passport' },
    { type: 'search', placeholder: 'Search' },
    { type: 'text', name: 'token', autocomplete: 'on' },
    { type: 'checkbox', name: 'remember' },
  ]) assert.equal(S(d), false, JSON.stringify(d));
});

test('isSensitiveControl with a fake element', () => {
  const el = (attrs, extra = {}) => ({ getAttribute: (n) => attrs[n] ?? null, ...extra });
  assert.ok(isSensitiveControl(el({ type: 'password' })));
  assert.ok(isSensitiveControl(el({ name: 'pwd' }, { type: 'text' })));
  assert.equal(isSensitiveControl(el({ name: 'email' }, { type: 'email' })), false);
  assert.equal(isSensitiveControl(null), false);
});

test('page-side copy of descriptorSensitive matches the shared module', () => {
  const src = readFileSync(fileURLToPath(new URL('./pagescript.js', import.meta.url)), 'utf8');
  const m = src.match(/\/\/ BEGIN descriptorSensitive\s*([\s\S]*?)\/\/ END descriptorSensitive/);
  assert.ok(m, 'markers present');
  const page = new Function(m[1] + '; return descriptorSensitive;')();
  const names = ['', 'password', 'email', 'userPin', 'passenger', 'otp', 'csrf_token', 'token', 'spinner', 'cc-number', 'Search'];
  for (const type of ['text', 'password', 'hidden', 'email'])
    for (const ac of ['', 'off', 'one-time-code', 'cc-exp', 'name'])
      for (const n of names) {
        const d = { type, autocomplete: ac, name: n, id: n, ariaLabel: n, placeholder: n, label: n };
        assert.equal(page(d, RULES), S(d), JSON.stringify(d));
      }
});

test('scrubUrl', () => {
  const u = scrubUrl('https://user:pw@example.com/p?a=1&access_token=abc&code=xyz&session=s&q=hello&api_key=k#id_token=t&x=1');
  assert.ok(!u.includes('abc') && !u.includes('xyz') && !u.includes('pw@') && !u.includes('=t&'));
  assert.ok(u.includes('a=1') && u.includes('q=hello') && u.includes('x=1'));
  assert.equal(scrubUrl('https://example.com/?keyword=foo'), 'https://example.com/?keyword=foo');
  assert.equal(scrubUrl('data:text/html,secret'), 'data:[omitted]');
  assert.equal(scrubUrl('not a url'), 'not a url');
});

test('scrubText and scrubValue', () => {
  assert.ok(!scrubText('x eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijk y').includes('eyJ'));
  assert.ok(!scrubText('Authorization: Bearer abcdefghijklmnop12345').includes('abcdefghijklmnop'));
  assert.equal(scrubText('password: hunter2 ok'), 'password: [redacted] ok');
  assert.equal(scrubValue({ type: 'password' }, 'hunter2'), undefined);
  assert.equal(scrubValue({ type: 'text', name: 'email' }, 'a@b.c'), 'a@b.c');
});

test('sanitizeResult redacts secret keys, urls and redacted controls', () => {
  const out = sanitizeResult({
    url: 'https://e.com/?token=1&a=2',
    controls: [{ type: 'password', redacted: true, value: 'leak', label: 'Password' }],
    data: { password: 'p', api_key: 'k', name: 'n', nested: [{ authToken: 't' }] },
  });
  assert.ok(!out.url.includes('token=1'));
  assert.equal('value' in out.controls[0], false);
  assert.equal(out.data.password, '[redacted]');
  assert.equal(out.data.api_key, '[redacted]');
  assert.equal(out.data.nested[0].authToken, '[redacted]');
  assert.equal(out.data.name, 'n');
});

test('bound truncates strings and lists', () => {
  const r = bound({ text: 'x'.repeat(70000), list: Array.from({ length: 500 }, (_, i) => i) });
  assert.equal(r.text.length, 60000);
  assert.equal(r.list.length, 200);
  assert.equal(r.truncated, true);
  assert.deepEqual(bound('s'), { value: 's' });
});

test('webmcp helpers', () => {
  const used = new Set();
  assert.equal(sanitizeToolId('add to cart', used), 'add_to_cart');
  assert.equal(sanitizeToolId('add to cart', used), 'add_to_cart_2');
  assert.equal(sanitizeToolId('1st', used), 't_1st');
  assert.equal(operationFor({ readOnlyHint: true, consequentialHint: true }), 'read');
  assert.equal(operationFor({ consequentialHint: true }), 'delete');
  assert.equal(operationFor({}), 'update');
  const { tools, map } = toRegistration(7, 'https://x.test', [
    { name: 'search', description: 'd', inputSchema: null, annotations: { readOnlyHint: true, untrustedContentHint: true } },
    { name: 'dbg', description: '', inputSchema: {}, annotations: { debugging: true } },
    { name: 'buy', description: 'Buy', inputSchema: { type: 'object', properties: {} }, annotations: { consequentialHint: true } },
  ]);
  assert.deepEqual(tools.map((t) => [t.id, t.operation, t.read_only]), [['search', 'read', true], ['buy', 'delete', false]]);
  assert.ok(tools[0].description.startsWith('Returns untrusted page content.'));
  assert.ok(tools[0].description.includes('https://x.test'));
  assert.equal(map.get('buy').tabId, 7);
});

test('browser tool definitions satisfy engine validation', () => {
  const ops = new Set(['read', 'create', 'update', 'delete', 'execute']);
  const ids = new Set();
  for (const t of BROWSER_TOOLS) {
    assert.match(t.id, /^[A-Za-z][A-Za-z0-9_.\-]{0,63}$/);
    assert.ok(!ids.has(t.id)); ids.add(t.id);
    assert.ok(t.description.length <= 2000);
    assert.equal(t.input_schema.type, 'object');
    assert.ok(JSON.stringify(t.input_schema).length < 32768);
    assert.ok(ops.has(t.operation));
  }
  assert.equal(BROWSER_TOOLS.length, 16);
});
