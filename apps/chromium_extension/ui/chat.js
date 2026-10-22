// Threads main view: header strip, scrolling message list, pinned composer.
// Message text is only ever placed with textContent / text nodes.
import { cancelTurn, respondApproval, sendChat } from './engine.js';
import { loadMessages, loadThreads, selectThread } from './data.js';
import { button, buttonRow, clear, emptyMessage, h, iconButton } from './dom.js';
import { errorMessage, isConnected, on, state } from './state.js';

/** Splits text into ```fenced``` blocks, `inline code` and plain runs. */
export function renderRich(target, text) {
  target.textContent = '';
  const fence = /```([^\n`]*)\n?([\s\S]*?)(?:```|$)/g;
  let last = 0;
  let match;
  while ((match = fence.exec(text)) !== null) {
    if (match.index > last) renderInline(target, text.slice(last, match.index));
    target.append(codeBlock(match[2].replace(/\n$/, ''), match[1].trim()));
    last = fence.lastIndex;
    if (match[0].length === 0) fence.lastIndex++;
  }
  if (last < text.length) renderInline(target, text.slice(last));
}

function renderInline(target, text) {
  const parts = text.split(/(`[^`\n]+`)/g);
  const span = h('span', { class: 'prose' });
  for (const part of parts) {
    if (part.length > 2 && part.startsWith('`') && part.endsWith('`')) span.append(h('code', { class: 'inline-code', text: part.slice(1, -1) }));
    else if (part) span.append(document.createTextNode(part));
  }
  target.append(span);
}

function codeBlock(code, language) {
  const copy = iconButton('copy', 'Copy code', async () => {
    try {
      await navigator.clipboard.writeText(code);
      copy.title = 'Copied';
      setTimeout(() => { copy.title = 'Copy code'; }, 1500);
    } catch (_) {
      copy.title = 'Copy failed';
    }
  }, { size: 'sm' });
  return h('div', { class: 'code-block' },
    h('div', { class: 'code-head' }, h('span', { text: language || 'code' }), copy),
    h('pre', {}, h('code', { text: code })));
}

const NEAR_BOTTOM = 48;

export function createChatView() {
  const root = h('section', { class: 'chat', aria: { label: 'Chat' } });
  const header = h('div', { class: 'thread-header' });
  const messages = h('div', { class: 'messages', role: 'log', aria: { live: 'polite', label: 'Messages' }, tabindex: '0' });
  const input = h('textarea', { class: 'field composer-input', rows: '1', placeholder: 'Message Subconscious', aria: { label: 'Message' } });
  const send = iconButton('send', 'Send message', null, { type: 'submit', className: 'send-btn' });
  const stop = iconButton('stop', 'Stop', () => stopTurn(), { className: 'send-btn hidden' });
  const note = h('p', { class: 'composer-note', hidden: true });
  const composer = h('form', { class: 'composer' }, h('div', { class: 'composer-row' }, input, send, stop), note);
  root.append(header, messages, composer);

  let turn = null; // { id, node, text, content, approvals: Set }
  let shownThread = null;

  const scrollIfNear = (wasNear) => { if (wasNear) messages.scrollTop = messages.scrollHeight; };
  const isNear = () => messages.scrollHeight - messages.scrollTop - messages.clientHeight < NEAR_BOTTOM;

  function renderHeader() {
    clear(header,
      h('h1', { class: 'thread-title', text: state.thread ? state.thread.title || 'Untitled thread' : state.workspace ? 'New thread' : 'Threads' }),
      state.workspace && h('span', { class: 'thread-workspace', text: state.workspace.name }));
  }

  function renderComposerState() {
    const connected = isConnected();
    const busy = Boolean(turn);
    const reason = !state.workspace ? 'Choose a workspace from the menu to start chatting.'
      : !connected ? 'Not connected to the engine. Open Account to connect.' : '';
    const disabled = Boolean(reason);
    input.disabled = disabled;
    send.disabled = disabled || busy;
    send.classList.toggle('hidden', busy);
    stop.classList.toggle('hidden', !busy);
    note.hidden = !reason;
    note.textContent = reason;
  }

  function addMessage(role, content) {
    if (role === 'system') {
      const node = h('div', { class: 'banner banner-error', role: 'alert', text: content });
      messages.append(node);
      return { node, body: node };
    }
    const body = h('div', { class: 'msg-body' });
    renderRich(body, content);
    const node = h('div', { class: `msg ${role}` }, body);
    messages.append(node);
    return { node, body };
  }

  async function showThread() {
    renderHeader();
    renderComposerState();
    const uuid = state.thread?.uuid || null;
    if (uuid === shownThread) return;
    shownThread = uuid;
    clear(messages);
    if (!uuid) {
      messages.append(state.workspace
        ? emptyMessage('Start a conversation below.')
        : emptyMessage('Choose a workspace from the menu to start chatting.'));
      return;
    }
    try {
      const rows = await loadMessages(uuid);
      if (shownThread !== uuid) return;
      clear(messages);
      rows.forEach((row) => addMessage(row.role === 'user' ? 'user' : row.role === 'system' ? 'system' : 'assistant', row.content || ''));
      if (!rows.length) messages.append(emptyMessage('No messages yet.'));
      messages.scrollTop = messages.scrollHeight;
    } catch (error) {
      clear(messages);
      addMessage('system', errorMessage(error));
    }
  }

  function approvalCard(request) {
    const decide = (decision) => {
      try {
        respondApproval(request.turnId, request.approval_id, decision);
      } catch (error) {
        addMessage('system', errorMessage(error));
        return;
      }
      settle(decision === 'approve' ? 'Approved' : 'Denied');
    };
    const approve = button('Approve', { kind: 'filled', onClick: () => decide('approve') });
    const deny = button('Deny', { kind: 'outlined', onClick: () => decide('deny') });
    const status = h('p', { class: 'approval-status', text: 'Waiting for approval' });
    const args = h('pre', { class: 'approval-args', tabindex: '0', aria: { label: 'Tool arguments' }, text: formatArguments(request.arguments) });
    const card = h('div', { class: 'banner banner-warning approval', role: 'alert', aria: { label: `Approval needed for ${request.tool_name}` } },
      h('div', { class: 'approval-head' },
        h('strong', { text: request.tool_name || 'Tool' }),
        request.operation && h('span', { class: 'badge', text: request.operation })),
      h('p', { class: 'approval-hint', text: 'Subconscious wants to run this tool.' }),
      args, status, buttonRow(deny, approve));
    function settle(label) {
      approve.disabled = true;
      deny.disabled = true;
      status.textContent = label;
      card.setAttribute('role', 'status');
      turn?.approvals.delete(settle);
    }
    turn?.approvals.add(() => settle('No longer waiting'));
    messages.append(card);
    return card;
  }

  function formatArguments(value) {
    try {
      return JSON.stringify(value ?? {}, null, 2);
    } catch (_) {
      return String(value);
    }
  }

  function finishTurn() {
    if (turn) turn.approvals.forEach((close) => close());
    turn = null;
    renderComposerState();
  }

  function stopTurn() {
    if (!turn) return;
    try {
      cancelTurn(turn.id, state.thread?.uuid);
    } catch (error) {
      addMessage('system', errorMessage(error));
      finishTurn();
    }
  }

  async function submit(event) {
    event.preventDefault();
    const content = input.value.trim();
    if (!content || turn || input.disabled) return;
    input.value = '';
    autosize();
    const workspace = state.workspace;
    if (messages.querySelector('.empty')) clear(messages);
    addMessage('user', content);
    const reply = addMessage('assistant', '');
    reply.node.classList.add('pending');
    reply.body.append(h('span', { class: 'thinking', text: 'Thinking…' }));
    messages.scrollTop = messages.scrollHeight;
    const current = { id: null, node: reply.node, text: '', approvals: new Set() };
    turn = current;
    renderComposerState();
    const wasNear = () => isNear();
    let renderQueued = false;
    const paint = () => {
      renderQueued = false;
      const near = wasNear();
      renderRich(reply.body, current.text);
      scrollIfNear(near);
    };
    const end = () => {
      reply.node.classList.remove('pending');
      if (!current.text) reply.node.remove();
      else paint();
    };
    try {
      const { turnId } = await sendChat({ content, threadUuid: state.thread?.uuid, workspaceUuid: workspace.uuid }, {
        onDelta(delta) {
          current.text += delta;
          reply.node.classList.remove('pending');
          if (!renderQueued) {
            renderQueued = true;
            requestAnimationFrame(paint);
          }
        },
        async onDone(done) {
          end();
          finishTurn();
          await adoptThread(done.thread_uuid, workspace.uuid);
        },
        onCancelled() {
          end();
          addMessage('system', 'Stopped.');
          finishTurn();
        },
        onError(error) {
          end();
          addMessage('system', errorMessage(error));
          finishTurn();
        },
        onApproval(request) {
          reply.node.classList.remove('pending');
          approvalCard(request);
          messages.scrollTop = messages.scrollHeight;
        },
      });
      current.id = turnId;
    } catch (error) {
      end();
      addMessage('system', errorMessage(error));
      finishTurn();
    }
  }

  async function adoptThread(uuid, workspaceUuid) {
    try {
      const threads = await loadThreads(workspaceUuid);
      if (!state.thread && uuid) {
        const created = threads.find((item) => item.uuid === uuid) || { uuid, title: 'Untitled thread', workspaceUuid };
        shownThread = uuid; // the transcript is already on screen
        selectThread(created);
      } else if (state.thread) {
        const refreshed = threads.find((item) => item.uuid === state.thread.uuid);
        if (refreshed) { state.thread = refreshed; renderHeader(); }
      }
    } catch (error) {
      console.warn('Subconscious: could not refresh threads', error);
    }
  }

  function autosize() {
    input.style.height = 'auto';
    input.style.height = `${Math.min(input.scrollHeight, 140)}px`;
  }

  composer.addEventListener('submit', submit);
  input.addEventListener('input', autosize);
  input.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      composer.requestSubmit();
    }
  });

  on('selection', () => { showThread(); });
  on('change', renderComposerState);
  on('account', renderComposerState);
  on('workspaces', renderHeader);
  renderHeader();
  renderComposerState();
  showThread();

  return { root, focus: () => input.focus(), refresh: () => { showThread(); } };
}
