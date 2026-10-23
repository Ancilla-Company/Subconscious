# Extension tools layer

Browser tools the extension offers to the engine's model, over the `/api/v1/events` WebSocket
(protocol: `engine/README.md`, "Client-defined tools").

Used through the host (`host_tools.js` -> `globalThis.subconsciousExtension`; see ../README.md). The Dart app registers the tool groups with the engine and answers `client.tool.request` by calling `callTool(group, id, argsJson)`.

`requestSiteAccess(origin)` (host API) must be called from a user gesture (a button) to prompt for host access.

## Tools (group `browser`)

| id | operation | notes |
|---|---|---|
| list_tabs | read | `current_window_only` |
| get_active_tab | read | |
| read_page | read | `tab_id`, `max_chars` (20000, max 60000), `include_links`; url, title, `note`, text outline, links `{ref,text,href}`, controls `{ref,tag,type,label,placeholder,value,checked,options,disabled}` |
| find_in_page | read | `query`, `case_sensitive`, `max_results`, `scroll_to_first` |
| scroll | read | `direction` up/down/top/bottom, `amount`, or `ref`/`selector` |
| wait_for | read | `text` or `selector`, `state` visible/hidden, `timeout_ms` (max 30000), or `ms` pause |
| click | update | `ref`/`selector`; waits for navigation (15 s) |
| type_text | update | `ref`/`selector`, `text`, `clear`, `submit` |
| press_key | update | `key`, modifiers, optional target |
| select_option | update | `value` / `label` / `index` |
| navigate | update | http(s) only |
| go_back / go_forward | update | |
| open_tab | create | optional http(s) `url`, `active` |
| switch_tab | update | |
| close_tab | delete | `tab_id` required |

All take an optional `tab_id` (default: active tab) where it makes sense. Refs (`e1`, `e2`, ...) are
assigned by `read_page` (and `find_in_page`) and kept in an isolated-world registry in the page; a
new `read_page` resets them. Scope is the **top frame only**; iframes are skipped. Open shadow roots are read.
Results are bounded: strings are cut at 60k chars and lists at 200 items, with `truncated:true`.
Each call times out after 50 s (engine: 60 s).

## Privacy rules (tools/redact.js, the single source)

* A control is sensitive when: `type=password` or `hidden`; `autocomplete` contains `password`,
  `one-time-code`, `cc-number`, `cc-csc`, `cc-exp`; or name/id/aria-label/placeholder/label contains
  `password|passwd|pwd|secret|cvv|cvc|passphrase|passcode|card number|security code|private key|api key`,
  or has a whole word `pass|otp|totp|pin|2fa|mfa` (camelCase and punctuation are split, so `shipping`/`passenger` are fine);
  csrf/nonce/token names count when `autocomplete=off`. Contenteditable boxes and `role=textbox` follow the same rules.
  This still catches a "show password" input that became `type=text`.
* Sensitive controls are listed as `{type:'password', redacted:true, label}` with no ref and no value; hidden inputs are omitted;
  they are skipped in text outline, `find_in_page` and `wait_for`. `click`, `type_text`, `press_key`, `select_option` refuse them:
  "This is a password/secret field; enter it yourself". File input values are never exposed. Cookies/storage are never read.
* The page script is the only code that sees field values, and it drops sensitive ones in the page. Every result then passes through
  `sanitizeResult`: URLs lose userinfo and secret params (`token, access_token, id_token, code, password, key, session, sig, ...`, query and fragment);
  free text loses JWTs, bearer tokens, common API key shapes and `password=...` pairs; strings under secret-looking object keys become `[redacted]`.
* `descriptorSensitive` is duplicated inside `pagescript.js` (injected functions cannot import); `redact.test.mjs` verifies both copies agree.
  Change both together.
* Page content is untrusted: `read_page` carries a fixed `note` telling the model to ignore instructions found in the page.

## Permissions

* `tabs`: read tab url/title for listing and for the special-page check.
* `scripting`: `chrome.scripting.executeScript` for reading/acting (ISOLATED world) and WebMCP (MAIN world).
* `optional_host_permissions` `http://*/*`, `https://*/*`: granted per origin. Before acting the host checks
  `chrome.permissions.contains`; if missing it tries `request` (only works in a user gesture) and otherwise returns
  "Grant access to <origin> in the extension (Site access)". Pages like chrome://, chrome-extension://, the Web Store, about:blank and
  the PDF viewer return "cannot access this page".

## WebMCP (group `webmcp`)

Tools of the active tab via `document.modelContext.getTools()` / `executeTool(tool, args, {signal})`
(Chrome origin trial; feature-detected, no-op when absent). All API calls live in `webmcp.js`. The watcher re-registers
the group (debounced 300 ms, only when the list changed) on tab activation, tab load/URL change, window focus, and a 3 s poll while the
extension page is visible (a `toolchange` event cannot reach the extension without a content script). Operation: `readOnlyHint` -> read,
`consequentialHint` -> delete, otherwise update; `debugging` tools are skipped; `untrustedContentHint` results are wrapped as
`{untrusted:true, source, content}` and the description is prefixed. Ids are sanitised page names (deduplicated); the origin is in the description.
Only tabs with granted site access are probed.

## Adding a tool

1. Add `{id, operation, description, input_schema}` to `definitions.js`.
2. Add a handler in `browser.js` (`handlers[id]`); for DOM work add an `op` in `pagescript.js` (self-contained, check `isSensitive` for anything targeting a field).
3. Results are sanitised automatically; add tests to `redact.test.mjs` if you add redaction rules.

Tests: `node --test tools/redact.test.mjs`. Manual: open `tools/testpage.html` via a local http server (e.g. `python -m http.server`)
with site access granted to that origin.
