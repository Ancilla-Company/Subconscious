# Subconscious Markdown and Plain Text Editors

Production feature requirements and current status. Assessed October 2026.

## 1. Purpose and scope

This document lists the features a production release of the Subconscious file editors is expected to have, and records where the current implementation stands against each one. It starts from the reported bugs (whitespace that does not save, no triple-click line selection) and an earlier report of formatting carrying onto other lines, which this assessment found is still present. It extends them into a full requirements list, checked against the code and against measured behavior of the editors as they are today.

Contents: [1 Purpose](#1-purpose-and-scope), [2 How to read](#2-how-to-read-this-document), [3 Summary](#3-summary), [4 Shared requirements](#4-shared-editor-requirements), [5 Markdown](#5-markdown-editor-requirements), [6 Plain text](#6-plain-text-editor-requirements), [7 Defects](#7-verified-defects), [8 Architecture](#8-architecture-decision), [9 Release gates](#9-release-gates-and-test-plan), [Appendix A](#appendix-a-markdown-round-trip-results), [B](#appendix-b-whitespace-results), [C](#appendix-c-how-this-was-assessed), [D](#appendix-d-references).

It covers three things:

- The **Markdown editor**, used for `.md` and `.markdown` files.
- The **plain text editor**, used for `.txt` files.
- The **editor shell** both share: tabs, saving, external changes, status, performance, accessibility and security.

Other text and source files (code, JSON, YAML and so on) open in a separate code editor and are out of scope.

Target platforms follow `docs/ui-completion-plan.md`: Windows desktop, Flutter web and Android. macOS, Linux and iOS are not actively verified.

Where the code lives:

- `WorkspaceFileEditor` in `apps/unified_app/lib/features/context/presentation/context_panel.dart` holds the tabs, open, save and both editors.
- `workspace_rich_text.dart` in the same folder holds the formatting limits, the paste sanitizer and the embed builders.
- Both editors currently run on the `flutter_quill` 11.5.1 rich-text engine. `markdown_quill` 4.3.0 converts between markdown text and the rich-text document.
- Files are read and written through the engine file API in `engine/src/subconscious_engine/services/workspace_files.py`. It accepts files up to 1,000,000 bytes and only valid UTF-8.

## 2. How to read this document

**Priority**

| Priority | Meaning |
|---|---|
| P0 | Release blocker. Data loss, a crash, a security problem, or a core action users try in their first minute. |
| P1 | Expected of a full-featured editor. Ship in 1.0 or record a waiver. |
| P2 | Polish and differentiators. May follow 1.0. |

**Status**

| Status | Meaning |
|---|---|
| Done | Works as required. |
| Partial | Part of the requirement works. The note says what is missing. |
| Missing | Not implemented. |
| Defect | Implemented but wrong, and the wrong behavior was reproduced. |
| Unverified | Not tested. Needs a manual or device check before release. |

**Evidence tags** at the end of a note say how the status was established.

| Tag | Meaning |
|---|---|
| [P] | Probe. A throwaway Flutter test ran the real editor widget (with a Windows platform override), or the real Quill controller it is built on, and drove it with key, mouse or direct edit calls. |
| [C] | Corpus. Markdown constructs and whitespace cases were run through the same conversion libraries and the same open and save logic as the editor. |
| [S] | Source. Established by reading the editor, engine or package source. |

Requirement IDs are stable: `ED-` shared editor, `MD-` markdown, `TX-` plain text, `D-` defects. Appendix C describes the method and its limits.

## 3. Summary

**Verdict.** The markdown editor is not ready for a production release. The plain text editor keeps content faithfully apart from trailing newlines and mixed line endings, but it crashes on files with many lines. Both share data-safety gaps.

**What blocks release**

1. **Markdown is rewritten, not edited.** The editor turns the file into a rich-text document and regenerates the markdown on every save. Blank lines, hard line breaks, indentation, tables, raw HTML, front matter, heading levels 4 to 6 and image alt text are lost or rewritten (MD-FID-01 to MD-FID-17, D-01, D-11). This is the cause of the reported whitespace loss.
2. **Unsaved work can disappear without a warning.** Leaving the Files view, switching workspace or closing the window discards edits. Save with no engine connection clears the dirty marker and writes nothing. Ctrl+S does nothing. A later Save overwrites changes made by the agent or another program (ED-SAV-01 to ED-SAV-10, ED-EXT-02, D-04 to D-09).
3. **Plain text files with many lines crash.** Opening about 8,000 lines throws a StackOverflowError (233 KB with short lines), well under the 1,000,000 byte limit the engine accepts. It depends on the number of lines, not the size (ED-PER-01, D-13).
4. **Typed and pasted markdown is not understood.** `# Heading` is saved as `\# Heading`, so text copied from a chat reply is corrupted (MD-EDT-05, MD-EDT-06, D-10).
5. **Basic selection and Enter behavior are wrong.** Triple-click does not select a line, and bold, italic or code formatting carries onto the next line (MD-SEL-02, MD-EDT-03, D-02, D-03).

**Decision needed.** Items 1 and 4 come from the editing model, not from individual bugs, so they need a product decision before work starts. Section 8 sets out the options. It recommends a source-first markdown editor with an optional rich-text mode, and a plain text input for `.txt`.

**Status counts** (computed from the tables in sections 4 to 6)

<!--COUNTS-->
| Area | Requirements | Done | Partial | Missing | Defect | Unverified | P0 not done |
|---|---|---|---|---|---|---|---|
| Shared editor (ED) | 75 | 10 | 8 | 26 | 5 | 26 | 32 of 39 |
| Markdown (MD) | 149 | 14 | 20 | 86 | 21 | 8 | 36 of 48 |
| Plain text (TX) | 39 | 5 | 7 | 16 | 4 | 7 | 9 of 14 |
| **Total** | **263** | **29** | **35** | **128** | **30** | **41** | **77 of 101** |

Of the 101 P0 requirements, 24 are Done and 77 are not (27 Defect, 14 Missing, 20 Partial, 16 Unverified). Every P0 row must be Done, or waived in writing by the product owner, before release.
<!--/COUNTS-->

## 4. Shared editor requirements

These apply to both editors.

### 4.1 Saving and data safety (ED-SAV)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| ED-SAV-01 | Save writes exactly the text shown, and the tab becomes clean only after the write succeeds | P0 | Defect | With no engine connection, Save marks the tab clean and writes nothing, with no error shown. [P] |
| ED-SAV-02 | A failed save keeps the tab dirty and the draft intact, and tells the user why | P0 | Partial | Engine errors reach the toast and keep the tab dirty. The no-connection path in ED-SAV-01 bypasses this. [S][P] |
| ED-SAV-03 | Ctrl+S saves the active tab (Cmd+S on macOS), and on web the browser's own save dialog is suppressed | P0 | Missing | No save shortcut is bound. Pressing Ctrl+S left the tab dirty. [P] |
| ED-SAV-04 | An unedited file is never rewritten | P0 | Done | The tab starts clean and Save is disabled until the text changes. [S] |
| ED-SAV-05 | Writes are atomic: write a temporary file, flush it, then rename over the original | P0 | Missing | The engine writes in place (seek to 0, write, truncate), so a crash mid-write can leave a damaged file. [S] |
| ED-SAV-06 | Closing a dirty tab offers Save, Don't save and Cancel | P0 | Partial | The prompt offers Cancel and Discard only. [S] |
| ED-SAV-07 | Closing the window with dirty tabs asks before exiting | P0 | Missing | The close handler saves app state and destroys the window without asking the editor. Web and Android have no equivalent guard. [S] |
| ED-SAV-08 | Unsaved edits survive leaving the Files view and returning | P0 | Defect | Typed text was gone after switching to another panel and back. [P] |
| ED-SAV-09 | Unsaved edits survive a workspace switch, or the user is asked first | P0 | Defect | Changing the active workspace clears every tab, dirty or not. [S] |
| ED-SAV-10 | Before overwriting, detect that the file changed on disk since it was opened, and ask | P0 | Missing | The write request carries no version, hash or timestamp, so the last writer wins. [S] |
| ED-SAV-11 | Crash recovery: unsaved drafts are kept in app storage and offered at next launch | P1 | Missing | |
| ED-SAV-12 | Autosave with a debounce, on focus loss and on tab switch, controlled by a setting | P1 | Missing | Saving is manual only. [S] |
| ED-SAV-13 | Save all dirty tabs | P1 | Missing | |
| ED-SAV-14 | Save As to a new name inside the workspace roots | P1 | Missing | |
| ED-SAV-15 | Files that are read-only on disk open read-only, with an indicator and Save disabled | P1 | Missing | |

### 4.2 External changes and the agent (ED-EXT)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| ED-EXT-01 | A clean tab reloads when the file changes on disk (agent edit, another program, sync client) | P0 | Partial | The open file refreshes after an agent chat turn that has an active file. There is no file watcher, so other changes appear only when the file is reopened. [S] |
| ED-EXT-02 | A dirty tab with an outside change offers keep mine, take theirs or compare | P0 | Missing | The draft is kept, and the next Save overwrites the outside change without notice. [S] |
| ED-EXT-03 | A file deleted or renamed outside the app marks its tab as missing and offers Save As | P1 | Unverified | |
| ED-EXT-04 | Moves made in the file tree update open tabs | P1 | Done | Open tabs and the active file are rebased after a move. [S] |
| ED-EXT-05 | The engine pushes file-change events so the editor does not depend on chat turns | P2 | Missing | |

### 4.3 Tabs and sessions (ED-TAB)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| ED-TAB-01 | Each tab shows a dirty indicator | P0 | Done | A dot appears after an edit and clears after a save. [P] |
| ED-TAB-02 | Open tabs and the active tab restore on restart, per workspace | P0 | Done | Restored from the remembered open files. [S] |
| ED-TAB-03 | Per-tab state survives tab switches: unsaved text, selection, undo history, scroll position | P0 | Defect | Unsaved text and selection survive. Undo history is lost, and blank lines typed in markdown are lost because the draft is parsed again. Scroll position was not measured. [P] |
| ED-TAB-04 | A file opens in at most one tab | P1 | Done | Tabs are keyed by root and path. [S] |
| ED-TAB-05 | Reorder tabs by dragging | P1 | Missing | |
| ED-TAB-06 | Tab menu: close, close others, close to the right, copy path, reveal in file tree | P1 | Missing | |
| ED-TAB-07 | Reopen the last closed tab | P1 | Missing | |
| ED-TAB-08 | Keyboard: Ctrl+W close, Ctrl+Tab and Ctrl+Shift+Tab cycle, Ctrl+1 to 9 jump | P1 | Missing | No bindings found. [S] |
| ED-TAB-09 | A long tab strip scrolls and keeps the active tab in view | P1 | Unverified | The strip scrolls horizontally. Following the active tab was not checked. |
| ED-TAB-10 | Pin tabs | P2 | Missing | |
| ED-TAB-11 | Caret and scroll position are restored when a file is reopened after a restart | P2 | Missing | The caret is kept in memory per tab only. Only the open files and the active file are remembered across restarts. [S] |

### 4.4 Status and feedback (ED-STA)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| ED-STA-01 | Status bar: line and column, selection size, character and word counts, encoding, line ending | P1 | Missing | There is no status bar. [S] |
| ED-STA-02 | Saving shows progress and a clear saved state | P1 | Partial | The Save button shows a spinner and the dirty dot clears. There is no saved confirmation. [S] |
| ED-STA-03 | Read, write and size errors name the file and the cause and suggest a next step | P0 | Partial | Engine messages such as "exceeds the 1 MB limit" and "not valid UTF-8 text" are shown in a toast, without a next step. [S] |
| ED-STA-04 | The editor shows when the engine is disconnected and disables Save | P0 | Missing | Save stays enabled while disconnected, which causes ED-SAV-01. [P] |
| ED-STA-05 | Read-only and unsupported-encoding states are visible on the tab | P1 | Missing | |

### 4.5 Performance and scale (ED-PER)

Proposed budgets, to be confirmed on the team's reference hardware with release builds: open a 200 KB file in 1 second or less, 95th percentile keystroke latency of 50 ms or less on a 200 KB file, and no crash up to the engine limit of 1,000,000 bytes. The timings below came from the debug test VM, which is far slower than a release build, so use them to judge how cost scales with size, not as absolute numbers.

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| ED-PER-01 | Every file the engine accepts (up to 1,000,000 bytes) opens and edits without crashing | P0 | Defect | Opening plain text of about 8,000 lines throws a StackOverflowError, while 6,000 lines opened. The limit follows the line count, not the byte size. Markdown of 8,000 lines (365 KB) opened. [P] |
| ED-PER-02 | Open time of 1 second or less for a 200 KB file | P0 | Unverified | Debug test timings: 22 KB markdown 1.3 s, 91 KB markdown 4.0 s, 365 KB markdown 16 s. [P] |
| ED-PER-03 | 95th percentile keystroke latency of 50 ms or less on a 200 KB file | P0 | Unverified | Debug test timings for one edit: 0.33 s at 22 KB, 0.94 s at 91 KB, 3.7 s at 365 KB. [P] |
| ED-PER-04 | Large paste (several MB of text) does not freeze or crash | P0 | Unverified | Inserting text goes through the same document insert that overflowed on open. Paste was not tested. [S] |
| ED-PER-05 | Only visible lines are laid out and painted | P1 | Unverified | Open time and latency grow roughly in line with size, which suggests the whole document is laid out. Confirm with a profile. |
| ED-PER-06 | Scrolling holds the display refresh rate on a 1 MB file | P1 | Unverified | |
| ED-PER-07 | Files above a soft limit open in a lighter mode with a notice | P1 | Missing | |
| ED-PER-08 | Parsing, search and export run off the UI thread | P2 | Missing | Markdown parsing runs on the UI thread during open. [S] |
| ED-PER-09 | Memory returns to baseline after tabs close | P1 | Unverified | |

### 4.6 Accessibility (ED-A11Y)

The target is WCAG 2.2 Level AA. Automated checks cannot certify conformance. It needs manual testing with assistive technologies (Narrator and NVDA on Windows, TalkBack on Android) and an expert review.

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| ED-A11Y-01 | Every command is reachable by keyboard alone, in a logical focus order | P0 | Unverified | |
| ED-A11Y-02 | Ribbon buttons and menus expose names, roles and states to screen readers | P0 | Unverified | Quill buttons have tooltips. Roles and states were not checked. |
| ED-A11Y-03 | Screen readers can read and navigate the document, and announce the caret line, the selection and formatting changes | P0 | Unverified | |
| ED-A11Y-04 | A visible focus indicator on the editor and on every control | P0 | Unverified | |
| ED-A11Y-05 | Text, selection, ribbon states and code colors meet 4.5:1 contrast (3:1 for large text and icons) in light, dark and every accent theme | P0 | Unverified | |
| ED-A11Y-06 | OS text scaling up to 200% causes no clipping or overlap, and the ribbon wraps | P0 | Unverified | |
| ED-A11Y-07 | The active ribbon state is not shown by color alone | P0 | Unverified | Active buttons use a fill. Confirm a non-color cue and selected semantics. |
| ED-A11Y-08 | Honors reduced motion and high-contrast settings | P1 | Unverified | |
| ED-A11Y-09 | Tooltips show the shortcut as well as the name | P1 | Missing | Tooltips are names only. [S] |

### 4.7 Text input and internationalization (ED-I18N)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| ED-I18N-01 | IME composition (Chinese, Japanese, Korean and others) works without lost characters, with the candidate window beside the caret | P0 | Unverified | Needs device testing. |
| ED-I18N-02 | Caret movement, selection and Backspace treat emoji, combining marks and surrogate pairs as single characters | P0 | Unverified | |
| ED-I18N-03 | Right-to-left and mixed-direction text render and edit correctly | P1 | Unverified | An Arabic line survived a markdown round trip unchanged. Editing was not tested. [C] |
| ED-I18N-04 | Dead keys, AltGr and non-US layouts type correctly and shortcuts still work | P1 | Unverified | |
| ED-I18N-05 | Shortcuts follow platform conventions (Ctrl or Cmd) | P1 | Done | Quill picks Cmd on macOS and Ctrl elsewhere. [S] |
| ED-I18N-06 | The editor's own strings (dialogs, tooltips) can be localized | P2 | Partial | Quill ships localizations. The app's own strings are English literals. [S] |
| ED-I18N-07 | Word selection and word-wise movement follow locale rules, including CJK text that has no spaces | P2 | Unverified | |

### 4.8 Security and privacy (ED-SEC)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| ED-SEC-01 | Opening or editing a file never fetches remote content (images, previews, link cards) | P0 | Done | Images show a placeholder with their address and are not fetched. [S][P] |
| ED-SEC-02 | Links open only for safe schemes (http, https, mailto). Other schemes are blocked or confirmed | P0 | Unverified | The app does not set a link launcher. Quill's default was not checked. |
| ED-SEC-03 | Embedded HTML never executes. If it is ever rendered, it passes through an allow-list sanitizer | P0 | Done | Raw HTML is escaped to text today. This is safe, but it changes the file (MD-FID-09). [C] |
| ED-SEC-04 | File access stays inside the workspace roots. Traversal, absolute paths and reparse points are refused | P0 | Done | Enforced in the engine. [S] |
| ED-SEC-05 | Pasted content is reduced to what the file type can store | P0 | Done | Markdown keeps only storable formatting. Plain text takes text only. [S][P] |
| ED-SEC-06 | Logs and telemetry never include file content or full paths | P0 | Unverified | |
| ED-SEC-07 | Recovery drafts are stored in the user's app data folder with user-only permissions and removed after saving | P1 | Missing | Applies once ED-SAV-11 exists. |

### 4.9 Reliability and diagnostics (ED-REL)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| ED-REL-01 | An error while preparing one tab never blanks the panel or other tabs. The editor falls back to a plain text view with a notice | P0 | Missing | A conversion error escapes through the controller's listener and leaves the tab half-initialized. This is how empty markdown files broke earlier, and there is no general guard. [S] |
| ED-REL-02 | Fuzz and soak tests: random edit, undo, redo, tab switch and save sequences never throw or lose text | P0 | Missing | |
| ED-REL-03 | Non-content diagnostics (file type, size, timings, error codes) are logged for support | P1 | Unverified | |

### 4.10 Platforms (ED-PLT)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| ED-PLT-01 | Windows: mouse, keyboard, IME, touch and pen input, DPI scaling | P0 | Partial | Mouse and keyboard passed in the Flutter test harness with a Windows platform override. The packaged app, IME, touch and pen were not tested. [P] |
| ED-PLT-02 | Web: shortcuts do not trigger browser actions, clipboard permissions are handled, narrow widths work | P1 | Unverified | |
| ED-PLT-03 | Android: soft keyboard, selection handles and magnifier, hardware keyboard shortcuts, Back asks before discarding | P1 | Unverified | |
| ED-PLT-04 | Narrow layouts (under 720 px) keep the editor usable | P1 | Partial | The markdown ribbon wraps onto extra rows at a 420 px panel width. Other controls were not checked. [P] |

## 5. Markdown editor requirements

### 5.1 Source fidelity (MD-FID)

The file on disk is the source of truth. Opening a file and changing one character must change only that character. This is the most important section of the document, and today it is the weakest.

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| MD-FID-01 | After an edit, everything outside the edit stays byte-identical | P0 | Defect | The whole file is regenerated from the rich-text model on save. Of 82 constructs tested, 28 came back identical, 24 were rewritten with the same rendering, 4 were rewritten in a way that breaks extension syntax or drops content, and 26 changed or lost content (Appendix A). [C] |
| MD-FID-02 | Blank lines are preserved at any count: between blocks, at the start and at the end | P0 | Defect | Runs of blank lines collapse to one, and leading and trailing blank lines vanish (Appendix B). Blank lines typed in a session are also lost on a tab switch. [C][P] |
| MD-FID-03 | Hard line breaks (two trailing spaces or a backslash) are preserved | P0 | Defect | Each becomes a paragraph break. [C] |
| MD-FID-04 | Soft line breaks in hard-wrapped prose are preserved | P0 | Defect | Wrapped lines are joined into one long line, so a file wrapped at 80 columns produces a whole-paragraph diff. [C] |
| MD-FID-05 | Trailing spaces, tabs and indentation are preserved | P0 | Defect | Trailing spaces are dropped, and a line indented four spaces or by a tab becomes a fenced code block. [C] |
| MD-FID-06 | Marker style is preserved: emphasis with `*` or `_`, bullets with `-`, `*` or `+`, `1.` or `1)`, rule style, ATX or setext headings, backtick or tilde fences | P0 | Defect | Rewritten to one style, for example `*x*` becomes `_x_`. The meaning is kept and the diff is noisy. [C] |
| MD-FID-07 | List start numbers and nesting width are preserved | P0 | Defect | A list starting at 5 restarts at 1. Two-space nesting becomes four. [C] |
| MD-FID-08 | Headings of levels 4 to 6 are preserved | P0 | Defect | The `#` marks are deleted, leaving a plain paragraph. [C] |
| MD-FID-09 | Raw HTML (inline, blocks, comments, details and summary) is preserved verbatim | P0 | Defect | Escaped as text, for example `<div>` becomes `\<div\>`. [C] |
| MD-FID-10 | Front matter (YAML or TOML) is preserved verbatim and kept out of the body | P0 | Defect | Becomes a rule followed by a heading, which breaks tools that read the metadata. [C] |
| MD-FID-11 | Tables are preserved | P0 | Defect | Cells collapse into one run-on line. [C] |
| MD-FID-12 | Links keep their titles, reference definitions, autolinks and bare URLs as written | P0 | Defect | Titles are dropped, reference links are inlined, an unused definition is deleted, and bare URLs and autolinks become `[url](url)` with escaped characters. [C] |
| MD-FID-13 | Images keep alt text and titles, and images inside links (badges) keep the link | P0 | Defect | Alt text and titles are dropped, and the link around a badge image is removed. [C] |
| MD-FID-14 | No backslash escapes are added that the author did not write | P0 | Defect | `snake_case` becomes `snake\_case` and `2 * 3` becomes `2 \* 3`. [C] |
| MD-FID-15 | Nested structure survives: quotes in lists, multi-paragraph and code-bearing list items, nested quotes, loose lists | P0 | Defect | A nested quote is flattened, the second paragraph or code in a list item merges into the first line, and loose lists become tight. [C] |
| MD-FID-16 | Footnotes, definition lists, math blocks, alerts such as `> [!NOTE]`, and wiki links are preserved | P0 | Defect | Footnotes become a numbered list, alerts and wiki links are escaped, and a math block collapses to one line. [C] |
| MD-FID-17 | Inline code that contains backticks is preserved | P1 | Defect | Double-backtick spans lose their delimiters. [C] |
| MD-FID-18 | Line endings are preserved: LF, CRLF and mixed | P0 | Partial | A file with one style keeps it. Mixed endings become CRLF throughout and a lone CR becomes LF. [C] |
| MD-FID-19 | A UTF-8 byte order mark is preserved | P1 | Defect | The engine strips it on read and does not write it back. [S] |
| MD-FID-20 | Syntax the editor cannot represent is never rewritten. It is shown as a locked block, or the file opens in source mode with a notice | P0 | Missing | The editor rewrites unsupported syntax without warning. [S] |
| MD-FID-21 | A round-trip regression corpus runs in CI: CommonMark 0.31.2 examples, GFM examples and this repository's own `.md` files | P0 | Missing | No Dart tests cover the editors. [S] |
| MD-FID-22 | A "show changes" view compares the draft with the saved file before saving | P1 | Missing | |

### 5.2 Editing modes (MD-MOD)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| MD-MOD-01 | Source mode: edit the raw markdown text exactly as stored | P0 | Missing | The only view is the rich-text view. [S] |
| MD-MOD-02 | Preview mode: rendered, read-only and accurate to CommonMark and GFM | P1 | Missing | |
| MD-MOD-03 | Split view: source beside a live preview, scrolling in sync | P1 | Missing | |
| MD-MOD-04 | Rich-text (WYSIWYG) editing | P1 | Partial | Available, with the fidelity defects in 5.1. |
| MD-MOD-05 | Switch modes with a button or shortcut, keeping caret, selection and scroll position, and remember the choice | P1 | Missing | |
| MD-MOD-06 | Focus mode that dims everything but the current paragraph, and typewriter scrolling | P2 | Missing | |
| MD-MOD-07 | Readable line length: a maximum width and an optional centered column | P2 | Missing | |
| MD-MOD-08 | Full-screen or zen mode | P2 | Missing | |

### 5.3 Core editing (MD-EDT)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| MD-EDT-01 | Undo and redo with word-level grouping and deep history (Ctrl+Z, Ctrl+Y, Ctrl+Shift+Z) | P0 | Partial | The shortcuts work. History is lost when the tab is switched. [P] |
| MD-EDT-02 | Enter continues bullet, numbered and task lists and quotes, and Enter on an empty item exits | P0 | Done | A checked task continues as an unchecked task. [P] |
| MD-EDT-03 | Formatting does not carry onto the next line after Enter | P0 | Defect | Bold, italic and inline code typed on the line after Enter inherit the previous line's formatting. [P] |
| MD-EDT-04 | Toggling a format at the caret affects only the text typed next | P0 | Unverified | |
| MD-EDT-05 | Typing markdown syntax converts it live: `# `, `- `, `1. `, `> `, a code fence, `- [ ]`, `**bold**`, `*italic*`, `` `code` ``, `~~strike~~`, `[text](url)`, `---` | P0 | Missing | Typed syntax stays literal and is saved with backslashes: `# Heading` is stored as `\# Heading`. Needed in rich-text mode only. [P] |
| MD-EDT-06 | Pasted markdown is kept as markdown (source mode) or parsed (rich-text mode) | P0 | Defect | Plain text is inserted as literal characters and saved escaped, so markdown copied from a chat reply is corrupted. [S][P] |
| MD-EDT-07 | Paste options: Paste, Paste as plain text (Ctrl+Shift+V), HTML to markdown conversion, and a URL pasted over a selection makes a link | P1 | Partial | Rich paste is reduced to storable formatting. The other options are missing. [S] |
| MD-EDT-08 | Tab and Shift+Tab indent and outdent list items. In code blocks Tab inserts spaces | P1 | Partial | List indent and outdent work. Tab in other text inserts a literal tab character. [P] |
| MD-EDT-09 | Ordered lists renumber when items are added, removed or moved | P1 | Unverified | |
| MD-EDT-10 | Line commands: duplicate, delete, move up and down, join | P1 | Missing | |
| MD-EDT-11 | Auto-pair brackets, quotes, backticks and emphasis markers, and type over the closing character | P1 | Missing | |
| MD-EDT-12 | A hard line break command (Shift+Enter) | P1 | Missing | |
| MD-EDT-13 | Task checkboxes toggle by click and by keyboard | P1 | Unverified | |
| MD-EDT-14 | Code blocks have a language picker, syntax highlighting and a copy button | P1 | Partial | The language is kept in the file. There is no picker, highlighting or copy button. [S] |
| MD-EDT-15 | Spell check with underlines, suggestions and a personal dictionary | P1 | Missing | |
| MD-EDT-16 | Autocomplete for links to workspace files, heading anchors and mentions | P1 | Missing | |
| MD-EDT-17 | Smart typography (curly quotes, dashes, ellipsis), off by default | P2 | Missing | |
| MD-EDT-18 | Emoji shortcodes such as `:smile:` complete from a picker | P2 | Missing | |
| MD-EDT-19 | Drag selected text to move or copy it | P2 | Unverified | |
| MD-EDT-20 | Multiple cursors and column selection | P2 | Missing | |

### 5.4 Selection and pointer (MD-SEL)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| MD-SEL-01 | A click places the caret and a double-click selects a word | P0 | Done | [P] |
| MD-SEL-02 | A triple-click selects the line or paragraph, and dragging after it extends by line | P0 | Defect | The third click collapses to a caret. Quill's gesture detector handles single and double taps only, while Flutter's own text selection has a triple-tap handler. [P][S] |
| MD-SEL-03 | Shift+click, drag, Shift+arrows, Ctrl+Shift+arrows, Shift+Home and Shift+End, Ctrl+A | P0 | Done | Tested in a plain text tab, except Ctrl+A, which was tested in a markdown tab. Both use the same editor. [P] |
| MD-SEL-04 | Home, End, Ctrl+Home, Ctrl+End, PageUp, PageDown, Ctrl+Left and Ctrl+Right | P0 | Done | Tested in a plain text tab, and PageUp was not tested. Ctrl+Right stopped at the end of the word, so confirm that matches Windows convention. [P] |
| MD-SEL-05 | Ctrl+Backspace and Ctrl+Delete delete a word | P0 | Done | Tested in a plain text tab. [P] |
| MD-SEL-06 | Cut, copy and paste of text through shortcuts | P0 | Done | Tested in a plain text tab with a mocked clipboard. [P] |
| MD-SEL-07 | A right-click menu with cut, copy, paste, select all, plus formatting and spelling items | P1 | Unverified | Quill supplies a default builder, but a test right-click showed no menu. Check in a real window. [P] |
| MD-SEL-08 | Touch: long-press selects a word, handles adjust the selection, a magnifier shows during drags | P1 | Unverified | |
| MD-SEL-09 | Clicking the left margin selects the line | P2 | Missing | |
| MD-SEL-10 | Smart Home (first non-space character, then column 0), and expand or shrink the selection by syntax | P2 | Unverified | |

### 5.5 Inline formatting (MD-INL)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| MD-INL-01 | Bold, italic, strikethrough and inline code from the ribbon and shortcuts | P0 | Done | Applied and cleared correctly, and only formats markdown can store are allowed. [P] |
| MD-INL-02 | Links: insert and edit (Ctrl+K), remove, keep the title, open with Ctrl+click | P0 | Partial | The insert and edit dialog exists and typing at the end of a link does not extend it. Titles are dropped on save, and opening a link was not tested. [P][C] |
| MD-INL-03 | Clear formatting | P1 | Done | The ribbon has the button. [P] |
| MD-INL-04 | URLs are linked as they are typed | P1 | Partial | A URL followed by a space becomes a link, which is saved as `[url](url)` with escaped characters. [P][C] |
| MD-INL-05 | Bold and italic combined, and nested emphasis | P1 | Partial | `***x***` is saved as `**_x_**`. [C] |
| MD-INL-06 | Highlight, subscript and superscript syntax | P2 | Missing | The characters survive as literal text. There is no command and no rendering. [C] |
| MD-INL-07 | Inline math | P2 | Missing | Kept as literal text. [C] |
| MD-INL-08 | Each format has a documented shortcut with no clashes | P1 | Partial | Shortcuts come from Quill's defaults, and Ctrl+Shift+S is strikethrough where most editors use Save As. [S] |

### 5.6 Block formatting (MD-BLK)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| MD-BLK-01 | Headings 1 to 6 from the ribbon, shortcuts and typing | P0 | Partial | Levels 1 to 3 only. Levels 4 to 6 are blocked because they cannot be read back (MD-FID-08). [P] |
| MD-BLK-02 | Bullet, numbered and task lists, nested to at least six levels | P0 | Partial | Bullet, numbered and task lists and one level of nesting work. Deeper nesting was not tested, and several list shapes are rewritten on save (MD-FID-07, MD-FID-15). [P][C] |
| MD-BLK-03 | Blockquotes, including nested and multi-paragraph | P0 | Partial | A single level works. Nested quotes are flattened. [C] |
| MD-BLK-04 | Fenced code blocks with a language, and indented code blocks | P0 | Partial | Fenced blocks with a language are kept. Indented code and tilde fences are rewritten as backtick fences. [C] |
| MD-BLK-05 | Horizontal rules: insert, display and keep the style | P0 | Partial | A rule displays as a line and is written back as `- - -`. There is no insert command. [C] |
| MD-BLK-06 | Tables: insert, edit cells, add and remove rows and columns, set alignment, move with Tab, paste from spreadsheets | P1 | Missing | Existing tables are corrupted on save (MD-FID-11). [C] |
| MD-BLK-07 | Collapse and expand sections by heading | P2 | Missing | |

### 5.7 Extended syntax (MD-EXT)

Preserving the syntax comes first (5.1). This section is about editing and rendering it.

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| MD-EXT-01 | GitHub-flavored extensions: tables, task lists, strikethrough and autolinks | P0 | Partial | Task lists and strikethrough work. Tables and autolinks do not (MD-FID-11, MD-INL-04). [C] |
| MD-EXT-02 | Front matter shown as a collapsible block and edited as text | P1 | Missing | |
| MD-EXT-03 | Raw HTML blocks shown as an opaque block that can be edited as source | P1 | Missing | |
| MD-EXT-04 | Footnotes: insert, jump to the definition, back-reference | P1 | Missing | |
| MD-EXT-05 | GitHub alerts (NOTE, TIP, IMPORTANT, WARNING, CAUTION) | P1 | Missing | |
| MD-EXT-06 | Math with LaTeX, inline and block | P2 | Missing | |
| MD-EXT-07 | Diagrams (Mermaid) | P2 | Missing | |
| MD-EXT-08 | Wiki links and backlinks | P2 | Missing | |
| MD-EXT-09 | Definition lists, abbreviations, highlight, subscript and superscript | P2 | Missing | |
| MD-EXT-10 | Table of contents block | P2 | Missing | |
| MD-EXT-11 | A per-workspace choice of markdown flavor | P2 | Missing | |

### 5.8 Preview and rendering (MD-PRV)

No preview exists today. These apply when one is added.

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| MD-PRV-01 | Output matches CommonMark 0.31.2 and GitHub's GFM for the supported syntax | P0 | Missing | |
| MD-PRV-02 | Raw HTML is passed through an allow-list sanitizer | P0 | Missing | Required before any preview renders HTML. |
| MD-PRV-03 | Headings get anchors and in-page `#anchor` links scroll | P1 | Missing | |
| MD-PRV-04 | Code blocks are syntax highlighted for common languages | P1 | Missing | |
| MD-PRV-05 | Local images resolve relative to the file and load through the engine. Remote images stay off until the user opts in | P1 | Partial | The editor shows a placeholder with the address. Nothing is loaded. [P] |
| MD-PRV-06 | Task checkboxes toggle in the preview and write back to the source | P1 | Missing | |
| MD-PRV-07 | The preview and the source scroll together, and a click in the preview jumps to the source | P1 | Missing | |
| MD-PRV-08 | Rendered output can be copied as rich text or HTML | P1 | Missing | |

### 5.9 Find and replace (MD-FND)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| MD-FND-01 | Find in the file (Ctrl+F) with next, previous, match case and whole word | P0 | Done | Quill's find dialog opens with Ctrl+F. [P] |
| MD-FND-02 | All matches are highlighted and a count is shown, for example 3 of 12 | P1 | Unverified | |
| MD-FND-03 | Replace and Replace all (Ctrl+H) | P1 | Missing | The dialog is find-only. [P][S] |
| MD-FND-04 | Regular expressions, with capture groups in the replacement | P1 | Missing | |
| MD-FND-05 | Find in selection | P2 | Missing | |
| MD-FND-06 | Go to line (Ctrl+G) in source mode, and go to heading | P1 | Missing | |
| MD-FND-07 | Find in all workspace files by content | P2 | Missing | The engine's file search matches names only. [S] |

### 5.10 Document navigation (MD-NAV)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| MD-NAV-01 | An outline panel lists headings, jumps on click and follows the caret | P1 | Missing | |
| MD-NAV-02 | Links to other workspace files open them in a tab, and `#anchor` links jump | P1 | Missing | |
| MD-NAV-03 | Quick open for recent files and workspace files (Ctrl+P) | P1 | Missing | |
| MD-NAV-04 | A breadcrumb or sticky heading showing the current section | P2 | Missing | |
| MD-NAV-05 | Back and forward navigation history | P2 | Missing | |
| MD-NAV-06 | A backlinks panel | P2 | Missing | |
| MD-NAV-07 | Links to files and anchors that do not exist are flagged | P2 | Missing | |

### 5.11 Ribbon, commands and shortcuts (MD-CMD)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| MD-CMD-01 | The ribbon appears for markdown only and offers only formats the file can store | P0 | Done | `.txt` has no ribbon. Fonts, sizes, colors, underline and sub or superscript are absent. [P] |
| MD-CMD-02 | Ribbon buttons match the sidebar buttons (32 px, 4 px radius, 20 px icons, filled when active) and are left aligned | P0 | Done | Button size matched the real sidebar button, and both themes were compared. [P] |
| MD-CMD-03 | The ribbon shows the active state of the selection and disables unavailable actions | P0 | Done | Undo and redo are disabled until there is history, and Bold fills when active. [P] |
| MD-CMD-04 | The ribbon covers headings, bold, italic, strikethrough, code, link, lists, task, quote, code block, rule, table, image and clear | P1 | Partial | No rule, table or image buttons. [P] |
| MD-CMD-05 | The ribbon wraps or scrolls on narrow widths | P1 | Done | Wraps onto extra rows at a 420 px panel width. [P] |
| MD-CMD-06 | Command palette (Ctrl+Shift+P) | P1 | Missing | |
| MD-CMD-07 | A shortcut cheat sheet and customizable shortcuts | P2 | Missing | |
| MD-CMD-08 | A floating toolbar on selection | P2 | Missing | |
| MD-CMD-09 | A slash menu for inserting blocks | P2 | Missing | |

### 5.12 Images, links and attachments (MD-MED)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| MD-MED-01 | Insert an image from a file picker using a workspace-relative path | P1 | Missing | |
| MD-MED-02 | Pasting or dropping an image saves it to a configurable attachments folder with a unique name and inserts the link | P1 | Missing | |
| MD-MED-03 | Edit alt text and title | P1 | Missing | Alt text is lost on save today (MD-FID-13). |
| MD-MED-04 | Local images display inline | P1 | Missing | Only a placeholder shows. |
| MD-MED-05 | Link to a workspace file from a picker, and drag a file from the file tree to insert a link | P1 | Missing | |
| MD-MED-06 | Resize images | P2 | Missing | |
| MD-MED-07 | Renaming or moving a file updates links that point to it | P2 | Missing | |

### 5.13 Clipboard, import and export (MD-IOX)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| MD-IOX-01 | Copy as markdown, as HTML and as rich text | P1 | Missing | |
| MD-IOX-02 | Paste from Word, web pages and spreadsheets converts headings, lists, tables and links to markdown | P1 | Partial | Rich paste keeps formatting markdown can store. Table handling was not tested. [S] |
| MD-IOX-03 | Export to HTML, PDF and DOCX | P1 | Missing | |
| MD-IOX-04 | Print and print preview | P2 | Missing | |
| MD-IOX-05 | Open in the default app and reveal in Explorer | P2 | Missing | |

### 5.14 View and preferences (MD-VEW)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| MD-VEW-01 | The editor follows the app's light, dark and accent themes | P0 | Done | [P] |
| MD-VEW-02 | Zoom with Ctrl+wheel and Ctrl+plus, Ctrl+minus, Ctrl+0 | P1 | Missing | |
| MD-VEW-03 | Font family, size and line height | P1 | Missing | There are no editor settings. [S] |
| MD-VEW-04 | Word wrap toggle in source mode | P1 | Missing | |
| MD-VEW-05 | Line numbers in source mode | P1 | Missing | |
| MD-VEW-06 | Tab width and a spaces-or-tabs choice | P1 | Missing | |
| MD-VEW-07 | Editor preferences are stored per user and can be reset | P1 | Missing | |
| MD-VEW-08 | Show whitespace and line endings | P2 | Missing | |

### 5.15 Status (MD-STA)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| MD-STA-01 | Word count, character count, reading time and selection counts | P1 | Missing | |

### 5.16 Agent integration (MD-AGT)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| MD-AGT-01 | Edits the agent makes to an open file appear without reopening it | P0 | Partial | See ED-EXT-01. [S] |
| MD-AGT-02 | Agent edits are shown as a diff with accept and reject | P1 | Missing | |
| MD-AGT-03 | The agent sees the active file, the selection and the caret as context | P1 | Missing | Planned in `continue.txt`. |
| MD-AGT-04 | Actions on the selection: ask, rewrite, summarize, continue | P2 | Missing | |

### 5.17 History and review (MD-HIS)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| MD-HIS-01 | Local version history with restore | P2 | Missing | |
| MD-HIS-02 | Source-control status in the gutter | P2 | Missing | |
| MD-HIS-03 | Comments or suggestions | P2 | Missing | |

### 5.18 Templates and extension points (MD-TPL)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| MD-TPL-01 | New-file templates (blank, note, README) and a sensible default file name | P2 | Missing | The create flow suggests `new-file.md` and writes an empty file. [S] |
| MD-TPL-02 | Snippets with placeholders | P2 | Missing | |
| MD-TPL-03 | Optional lint hints: skipped heading levels, duplicate headings, trailing spaces | P2 | Missing | |
| MD-TPL-04 | Extension points for the native extensions planned in `continue.txt` | P2 | Missing | |

## 6. Plain text editor requirements

The shared requirements in section 4 apply to this editor too: saving, tabs, performance, accessibility and security.

### 6.1 Principles

- A `.txt` file is a sequence of characters. It has no place for fonts, bold, links or colors.
- So the editor has no ribbon, no formatting shortcuts, and pastes text only.
- Every character is significant: spaces, tabs, blank lines and the final newline.
- Notepad is the baseline for expectations. Windows 11's optional Notepad formatting toolbar works by typing Markdown symbols into the text, so the saved file is still plain text ([How-To Geek](https://www.howtogeek.com/this-classic-windows-app-is-now-my-favorite-markdown-editor/)).

### 6.2 Fidelity (TX-FID)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| TX-FID-01 | An edit changes only the characters edited | P0 | Partial | Content, leading and interior blank lines, trailing spaces, tabs, space-only lines and non-breaking spaces are preserved. The rows below list the exceptions. [C] |
| TX-FID-02 | Trailing blank lines are preserved at any count | P0 | Defect | A file ending in three blank lines is saved with a single newline, and blank lines typed at the end are lost. [C] |
| TX-FID-03 | The final newline can be added or removed | P0 | Defect | A file without a final newline cannot gain one, and a file with one cannot lose it. [C] |
| TX-FID-04 | Line endings: detect LF, CRLF, CR and mixed, preserve each line's ending, show it in the status bar, convert on request | P0 | Partial | A file with one style keeps it. Mixed endings become CRLF throughout and a lone CR becomes LF. [C] |
| TX-FID-05 | A UTF-8 byte order mark is preserved. UTF-16 and legacy code pages are detected, then converted with a prompt or refused with a clear message | P1 | Defect | The BOM is dropped on the first save. Files that are not UTF-8 are rejected by the engine. [S] |
| TX-FID-06 | Binary files and files containing NUL are refused with a notice | P1 | Unverified | |
| TX-FID-07 | Lines of 100,000 characters or more edit without freezing | P1 | Unverified | A 5,000-character line was fine in markdown. [C] |
| TX-FID-08 | No formatting is ever stored, displayed or offered | P0 | Partial | The ribbon is gone, and formatting commands, shortcuts and rich paste are blocked. A typed URL still gets link styling on screen, which is not saved. [P] |
| TX-FID-09 | Invisible characters (zero-width, bidirectional controls) can be made visible | P2 | Missing | |

### 6.3 Editing (TX-EDT)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| TX-EDT-01 | Type, Backspace, Delete, and Ctrl+Backspace and Ctrl+Delete to delete a word | P0 | Done | Typing and the Ctrl word-delete shortcuts were tested. Plain Backspace and Delete were not run separately. [P] |
| TX-EDT-02 | Undo and redo with deep history that survives tab switches | P0 | Partial | The shortcuts work. History is lost on a tab switch. [P] |
| TX-EDT-03 | Cut, copy and paste as plain text, and paste never brings formatting | P0 | Done | [P][S] |
| TX-EDT-04 | Tab inserts a tab character (or spaces, by setting). Tab and Shift+Tab indent and outdent selected lines | P1 | Partial | Tab inserts a tab character [P]. With a selection the editor swallows the key and does nothing, judging by the source, which was not run. [S] |
| TX-EDT-05 | Large paste is fast and does not crash | P0 | Unverified | See ED-PER-04. |
| TX-EDT-06 | Line commands: duplicate, delete, move up and down, join | P1 | Missing | |
| TX-EDT-07 | Auto-indent: Enter copies the previous line's leading whitespace | P2 | Missing | |
| TX-EDT-08 | Insert the date and time (F5) | P2 | Missing | |
| TX-EDT-09 | Change case, sort lines and trim trailing whitespace on request | P2 | Missing | |
| TX-EDT-10 | Spell check, off by default | P2 | Missing | |
| TX-EDT-11 | Drag selected text to move or copy it | P2 | Unverified | |
| TX-EDT-12 | Multiple cursors and column selection | P2 | Missing | |

### 6.4 Selection (TX-SEL)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| TX-SEL-01 | A click places the caret and a double-click selects a word | P0 | Done | [P] |
| TX-SEL-02 | A triple-click selects the line | P0 | Defect | The third click collapses to a caret, as in markdown (MD-SEL-02). [P] |
| TX-SEL-03 | Shift+click, drag, Ctrl+A, and the arrow, Home, End, PageUp and PageDown keys with their Shift and Ctrl variants | P0 | Done | [P] |
| TX-SEL-04 | A right-click menu with cut, copy, paste, undo and select all | P1 | Unverified | See MD-SEL-07. |
| TX-SEL-05 | Clicking a line number selects the line | P2 | Missing | |

### 6.5 Find (TX-FND)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| TX-FND-01 | Find with next, previous, match case, whole word and wrap-around | P0 | Partial | Ctrl+F opens a find dialog. Wrap-around was not checked. [P] |
| TX-FND-02 | Replace and Replace all | P1 | Missing | |
| TX-FND-03 | Go to line (Ctrl+G) | P1 | Missing | |
| TX-FND-04 | Match count and highlight all matches | P1 | Unverified | |
| TX-FND-05 | Regular expressions | P2 | Missing | |

### 6.6 View (TX-VEW)

| ID | Requirement | Pri | Status | Notes |
|---|---|---|---|---|
| TX-VEW-01 | Word wrap on by default, with a toggle | P1 | Partial | Text always wraps. There is no toggle. [S] |
| TX-VEW-02 | Font family and size, monospace by default, and zoom | P1 | Missing | The editor uses the rich-text body font. [P] |
| TX-VEW-03 | Line numbers | P1 | Missing | |
| TX-VEW-04 | Status bar: line, column, characters, encoding, line ending and zoom | P1 | Missing | |
| TX-VEW-05 | The editor follows the app's light, dark and accent themes | P0 | Done | [P] |
| TX-VEW-06 | Show whitespace and tabs, and highlight the current line | P2 | Missing | |
| TX-VEW-07 | Print | P2 | Missing | |
| TX-VEW-08 | URLs are clickable with Ctrl+click without changing the file | P2 | Unverified | |

## 7. Verified defects

Severity: **S1** loses data or crashes, **S2** wrong behavior, **S3** minor. Items marked reported came from user bug reports. Each was then reproduced or confirmed in the source, as the evidence tags in sections 4 to 6 show.

| ID | Sev | Defect | Cause | Direction |
|---|---|---|---|---|
| D-01 | S1 | Extra blank lines disappear after a file is closed and reopened (reported). Markdown collapses runs of blank lines and drops leading and trailing ones. Plain text drops trailing blank lines and cannot gain or lose the final newline. | The rich-text model has no place for blank-line counts. For plain text, the save path strips every trailing newline and then adds back at most one. | Section 8 for markdown. For plain text, stop trimming and treat the text as authoritative. |
| D-02 | S2 | Triple-click does not select a line, only double-click selecting a word works (reported). Both editors. | Quill's gesture detector recognizes single tap, double tap, long press and drag. Three quick taps arrive as a single tap, a double tap, then a single tap. | Use a plain text input for `.txt` and for markdown source mode. For Quill, extend or replace the detector. |
| D-03 | S2 | Bold, italic and inline code carry onto the next line after Enter (reported earlier, still present). | Quill's insert rule copies the previous run's inline styles onto text typed on an empty line. Turning off `keepStyleOnNewLine` does not stop it (tested). A custom rule would have to use Quill's internal library, which is marked experimental and may change in any minor version. | Strip inline styles in the controller after such inserts, patch Quill, or move off Quill. |
| D-04 | S1 | Unsaved edits vanish when the user leaves the Files view and returns. | Drafts live in widget state, and the main panel unmounts the editor when the destination changes. | Keep drafts in a document store owned by the controller. |
| D-05 | S1 | Unsaved edits vanish when the workspace changes. | The editor clears all tabs when the active workspace changes. | The same document store, plus a prompt. |
| D-06 | S1 | Closing the window ignores unsaved edits. | The close handler saves app state and destroys the window. Nothing asks the editor. | A close hook that checks the document store and prompts. |
| D-07 | S1 | Save with no engine connection marks the tab clean and writes nothing. | Saving returns silently when there is no client, then the editor resets its baseline because no error was recorded. | Return a result or throw. Clear the dirty state only on confirmed success, and disable Save while disconnected. |
| D-08 | S2 | Ctrl+S does nothing. | No shortcut is bound to save. | Bind save in the editor and app, and suppress the browser dialog on web. |
| D-09 | S1 | A change made by the agent or another program is overwritten by a later Save. | A dirty tab keeps its draft when the file changes, and the write API has no version check. | A version or hash check on write, plus a conflict prompt. |
| D-10 | S1 | Typed or pasted markdown (`# Heading`, `**bold**`, a link) is not interpreted and is saved with backslashes. | The rich-text model treats typed characters as text, the serializer escapes markdown characters, and no live markdown shortcuts are configured. | Source mode stores text as typed. In rich-text mode add shortcut rules and parse markdown on paste. |
| D-11 | S1 | The first edit rewrites the whole file and loses content (Appendix A): tables, raw HTML, front matter, hard breaks, heading levels 4 to 6, image alt text, link titles and nested quotes. | The file is regenerated from the rich-text model (section 8). | Section 8. |
| D-12 | S1 | Switching tabs loses undo history and any blank lines typed since opening, even without saving. | The editor disposes its controller on every tab switch and rebuilds it by parsing the draft text again. | Keep one controller per tab alive, or keep the draft in the document store without re-parsing. |
| D-13 | S1 | Opening a plain text file of about 8,000 lines throws a StackOverflowError (233 KB with short lines, about 350 KB with longer ones). The threshold in the test VM is between 6,000 and 8,000 lines, so it depends on line count rather than size. | The plain text open path inserts the whole text in one call, which recurses once per line. A markdown file of 8,000 lines opened, probably because its converter builds the document from many small operations. | Build the document one operation per line, or stop using the rich-text model for plain text. Re-measure in a release build. |
| D-14 | S2 | Open time and keystroke latency grow with file size. In the debug test build a 91 KB file opens in 4.0 s and a 365 KB file in 16 s. | Probably layout of every line. To be confirmed by profiling. | Virtualized rendering, plus release-build benchmarks. |
| D-15 | S3 | Lone carriage returns become line feeds, and mixed line endings become one style on save. | The save path assumes one line-ending style per file. | Preserve endings per line. |
| D-16 | S3 | A UTF-8 byte order mark is removed on the first save. | The engine strips it on read and writes none. | Report the BOM to the editor and write it back. |
| D-17 | S2 | A crash during Save can leave a damaged file. | The engine writes in place: seek, write, truncate. | Write a temporary file, flush, then rename atomically. |
| D-18 | S2 | An exception while preparing one tab can leave the editor blank. Empty markdown files hit this and were fixed. Other failures are not guarded. | Tab preparation has no error handling, and the exception escapes through the controller's listener before the panel rebuilds. | Catch it and fall back to a plain text view with a notice (ED-REL-01). |
| D-19 | S3 | Some default shortcuts clash with common conventions. Ctrl+Shift+S is strikethrough, where most editors use Save As. | Quill's default shortcut table. | Review and rebind (MD-INL-08). |

## 8. Architecture decision

Most markdown defects come from the editing model, not from individual bugs. The editor parses the file into a rich-text document and regenerates markdown from it on every save. A rich-text document has no place to keep blank-line counts, marker choices, raw HTML, front matter or table layout, so those are lost or rewritten. Patching cases one at a time cannot reach byte-for-byte fidelity.

### 8.1 Options for markdown

| Option | What it is | Fidelity | Effort | Risks |
|---|---|---|---|---|
| A. Source-first | The file text is the document. Syntax is highlighted, the ribbon and shortcuts insert or remove markers, and a preview pane renders the result. | Exact by construction | Medium to high: an editor component, a preview renderer and ribbon wiring | Flutter has no mature drop-in source markdown editor. The existing code editor dependency declares a word-wrap flag that its current version never reads, and it needs benchmarking on large files. |
| B. Hybrid | Option A as the default, with the current rich-text mode kept as an opt-in beta, with a warning, until it passes the round-trip corpus | Exact in the default mode | Medium | Two editing modes to maintain |
| C. Repair the rich-text model | Keep Quill, keep original source spans, rewrite only edited blocks, and lock syntax it cannot represent | Good, but not exact for blank lines | High | Needs a markdown parser with source positions (the `markdown` package does not provide them). Quill's global insert rules and the missing triple-click remain. |

**Recommendation: B for 1.0.** It fixes the fidelity, whitespace, typed-syntax and paste defects in the default mode, and it keeps a path to rich-text editing without making it the thing that can lose data.

### 8.2 Plain text

Use a plain text input, not the rich-text model. Flutter's own text selection code has a triple-tap handler, it wraps long lines, and a plain text input has no formatting to leak. That should remove D-02, D-13 and the trailing-newline defects for `.txt`. Benchmark it at 1,000,000 bytes first, and if it is too slow, chunk or virtualize the text view.

### 8.3 Questions for the product owner

1. Is markdown editing a primary feature, or a convenience for reviewing and fixing agent output? This decides how many P1 rows ship in 1.0.
2. Must rich-text (WYSIWYG) editing ship in 1.0, or is source mode with a preview enough?
3. Is editing on Android in scope for 1.0, or is it view-only there?
4. Should the editors support files above the engine's 1,000,000 byte limit?
5. Is a preview pane acceptable to render raw HTML, with sanitizing, or should HTML always show as source?

## 9. Release gates and test plan

### 9.1 Gates

| Gate | Pass criteria |
|---|---|
| Data safety | No scenario in D-04 to D-09 can lose or overwrite user text silently. Killing the process during Save leaves the file either old or new, never partial. |
| Fidelity | For every file in the corpus (Appendix A and B cases, CommonMark 0.31.2 examples, GFM examples, this repository's own `.md` files), open, change one character, save: only that character differs. |
| Whitespace | Every Appendix B case is byte-identical for both editors. |
| Selection | Click, double-click, triple-click, drag and Shift+click behave as in Notepad and VS Code on Windows. |
| Scale | Files up to 1,000,000 bytes open and edit without a crash. Open in 1 s or less and keystroke p95 of 50 ms or less at 200 KB, on a release build. |
| Accessibility | Keyboard-only pass, Narrator and NVDA pass, contrast and text scaling checks. Automated tools cannot certify WCAG 2.2 AA, so this needs manual testing with assistive technologies and an expert review. |
| Platforms | A manual pass on Windows, Chrome and Edge, and a mid-range Android phone. |
| Stability | A fuzz run of random edit, undo, redo, tab switch and save sequences: zero exceptions and zero lost text. |

### 9.2 Test plan

- **Unit and corpus tests** (Dart): the conversion corpus with golden files, and the whitespace matrix from Appendix B.
- **Widget tests**: turn the behavior probes used for this assessment into permanent tests, and add ribbon golden images for light, dark and narrow layouts. Only `integration_test/navigation_smoke_test.dart` exists today, and no Dart tests cover the editors.
- **Integration tests**: open, edit, save, disconnect the engine, reconnect, switch tabs, leave and return to the Files view, and agent edits against dirty tabs.
- **Engine tests** (pytest): atomic writes, the size limit, BOM handling and conflict detection.
- **Performance benchmarks**: release-profile runs on fixed corpora of 50 KB, 200 KB and 1 MB, with short and long lines.
- **Manual**: IME, screen readers, touch and web shortcuts.

### 9.3 Suggested order of work

1. Data safety (D-04 to D-09, D-17, D-18). It does not depend on the editor choice.
2. The plain text editor on a plain text input (D-01 for `.txt`, D-02, D-13, D-15).
3. Markdown source mode and preview (D-01, D-10, D-11, D-12 for markdown).
4. Ribbon actions, shortcuts, find and replace, and the status bar in source mode.
5. P1 navigation and authoring: outline, links, tables and images.
6. Performance and accessibility passes, then the release gates.

## Appendix A. Markdown round-trip results

82 markdown constructs were opened and saved with no edit beyond the conversion. Each result was compared with the original text, and with the HTML both texts render to under GFM.

**Identical (28).** The editor treats a few of these as plain text, which is why they survive: highlight, superscript, inline math and emoji shortcodes.

bold with `**`; italic with `_`; strikethrough; inline code; link; escaped asterisks; emoji shortcode; Unicode emoji; highlight `==`; superscript `^`; inline math; headings 1 to 3; two paragraphs; blockquote; two-line blockquote; bullets with `-`; ordered list; task list; four-space nested bullets; ordered list inside a bullet; fenced code; fenced code with language; code with a blank line; a 5,000-character line; Chinese text; Arabic text.

**Rewritten with the same rendering (24).** The meaning is kept, but the diff is noisy.

bold with `__`; italic with `*`; bold italic `***`; soft line break (lines are joined); autolink `<url>`; bare URL; reference link; literal asterisks; `snake_case` word; HTML entity; subscript `~`; closed ATX heading; setext heading 1 and 2; empty heading; bullets with `*` and `+`; ordered list with `)`; two-space nested bullets; tilde fence; indented code; horizontal rule with `---`, `***` and `___`.

**Same rendering in plain GFM, but breaks extension syntax or drops content (4).**

front matter; GitHub alert; wiki link; a link reference definition that nothing uses (deleted).

**Changed or lost content (26).**

inline code containing backticks; link title; image; image title; image inside a link; image inside text; inline HTML; hard break with two spaces; hard break with a backslash; footnote; math block; headings 4, 5 and 6; nested blockquote; list inside a blockquote; ordered list starting at 5; loose list; list item with two paragraphs; list item with code; table; aligned table; HTML block; details and summary; HTML comment; definition list.

## Appendix B. Whitespace results

Each case was opened and saved with no edit, in both editors.

| Case | Markdown | Plain text |
|---|---|---|
| One blank line between paragraphs | Same | Same |
| Three blank lines between paragraphs | Collapsed to one | Same |
| Three trailing blank lines | Reduced to one newline | Reduced to one newline |
| Three leading blank lines | Removed | Same |
| No final newline | Same | Same |
| Three trailing spaces | Becomes a paragraph break | Same |
| Two trailing spaces (hard break) | Becomes a paragraph break | Same |
| Four leading spaces | Becomes a fenced code block | Same |
| Leading tab | Becomes a fenced code block | Same |
| Tab inside a line | Same | Same |
| Space-only line between paragraphs | Becomes an empty line | Same |
| Many spaces inside a line | Same | Same |
| Non-breaking space | Same | Same |
| CRLF endings | Same | Same |
| LF and CRLF mixed | Becomes CRLF, lines joined | Becomes CRLF |
| Lone CR endings | Lines joined, final break lost | Becomes LF, final break lost |
| Empty file | Same | Same |
| A single newline | Same | Same |
| Spaces only | Becomes a single newline | Same |

Blank lines typed inside the editor behave the same way. In markdown, pressing Enter twice after a paragraph is saved, but is gone after the file is reopened, and also after switching to another tab and back. In plain text, pressing Enter three times at the end of the file is not saved.

## Appendix C. How this was assessed

- **Source [S].** The editor, the engine file service, `flutter_quill` 11.5.1, `markdown_quill` 4.3.0 and `flutter_code_editor` 0.3.5 were read.
- **Probes [P].** Throwaway Flutter tests mounted the real `WorkspaceFileEditor` with a Windows platform override and drove it with key and mouse events: clicks, shortcuts, tab switching, leaving the Files view, Save, and open and edit timings. Other probes drove the Quill controller and document directly: Enter behavior, formatting carry-over, typed syntax and the large-document threshold.
- **Corpus [C].** 82 markdown constructs and 19 whitespace cases ran through the same libraries and the same open and save logic as the editor. The editor's conversion code is private, so it was reproduced rather than called.
- **Not covered.** The packaged app, IME, screen readers, touch, Android, web, release-build performance, and real engine writes. The timings are from a debug test build and show scaling, not production speed.
- **Probe files.** They were deleted after the run. Section 9.2 recommends turning them into permanent tests.

## Appendix D. References

- CommonMark specification, version 0.31.2 (2024-01-28): <https://spec.commonmark.org/current>
- GitHub Flavored Markdown specification: <https://github.github.com/gfm/>
- WCAG 2.2: <https://www.w3.org/TR/WCAG22/>
- Windows 11 Notepad Markdown behavior: <https://www.howtogeek.com/this-classic-windows-app-is-now-my-favorite-markdown-editor/>

Content was rephrased for compliance with licensing restrictions.

Current State of the Work:
Other work left

Finish the round.
Re-run tests and analyze, because my last edit (the super-parameter change) is unverified.
Clean up temp files and the engine on port 55693, and check for a stray flutter_tester.
File types.
The engine opens only 34 fixed extensions, the original list, which I haven't touched.
.dart, .log, .csv, .ini, .cfg, .bat, .kt, .swift, .env and extensionless files like Makefile can't be opened. So "other plain text readable files" isn't met yet.
This is an access rule, so I want your call (question below).
Real-app check.
I haven't built or launched the app. Removing Quill and adding url_launcher changes the Windows plugin set, so flutter build windows should run. I can do that.
The hands-on pass is yours: edit, close the window and reopen, the conflict banner, triple-click, pasting markdown, and a large file.
P0 rows in the doc I can't mark Done. This is my read, not a full re-triage.
There are no live external-change events (ED-EXT-01, MD-AGT-01). The editor refreshes on focus, tab switch, reconnect and after a chat turn.
The conflict banner offers Load from disk and Overwrite with mine, with no compare (ED-EXT-02).
Save disables when offline and its tooltip says why, but there is no banner (ED-STA-04).
Links open from the preview only, not with Ctrl+click in source mode (MD-INL-02).
The preview hasn't been checked against the CommonMark examples (MD-PRV-01).
I audited logging only in my own code, which has none (ED-SEC-06).
A multi-MB paste is untested (ED-PER-04).
I'd record your accepted gaps as written waivers, which is what the doc's release gate asks for.
Docs. Re-triage all 263 rows, since the "77 of 101 P0 not done" count predates the rebuild. Sections 1, 3 and 8 still describe Quill.
Final message and git hygiene. I still owe you the AI-edit options outline, and workspace_rich_text.dart shows as AD in git.
I'd go in this order: engine tests, Dart tests, the file-type change, the docs re-triage, the build check, then the final message.

Two questions:

For file types, open any existing file that decodes as UTF-8 with no NUL bytes and keep the list only for creating new files. Remember this is still a note taker like notion or obsidian so it's more important to be able to edit the markdown file in preview mode.
