// Workspace / thread / file data, loaded from the engine REST API into `state`.
import { api } from './engine.js';
import { emit, set, state } from './state.js';

export async function loadWorkspaces() {
  const workspaces = await api('workspaces');
  const selected = workspaces.find((item) => item.uuid === state.workspace?.uuid) || null;
  set({ workspaces, workspace: selected }, 'workspaces');
  return workspaces;
}

export async function createWorkspace(name) {
  const workspace = await api('workspaces', { method: 'POST', body: JSON.stringify({ name }) });
  await loadWorkspaces();
  return workspace;
}

export async function loadThreads(workspaceUuid = state.workspace?.uuid) {
  if (!workspaceUuid) {
    set({ threads: [] }, 'threads');
    return [];
  }
  const threads = await api(`workspaces/${encodeURIComponent(workspaceUuid)}/threads`);
  if (workspaceUuid === state.workspace?.uuid) set({ threads }, 'threads');
  return threads;
}

export async function createThread(workspaceUuid, title) {
  const thread = await api('threads', { method: 'POST', body: JSON.stringify({ workspaceUuid, title: title || null }) });
  return thread;
}

export function loadMessages(threadUuid) {
  return api(`threads/${encodeURIComponent(threadUuid)}/messages`);
}

export function workspaceRoots(workspace) {
  try {
    const roots = JSON.parse(workspace?.directories || '[]');
    return Array.isArray(roots) ? roots.filter((item) => typeof item === 'string') : [];
  } catch (_) {
    return [];
  }
}

export function listFiles(workspaceUuid, rootIndex, path = '') {
  const query = new URLSearchParams({ rootIndex: String(rootIndex) });
  if (path) query.set('path', path);
  return api(`workspaces/${encodeURIComponent(workspaceUuid)}/files?${query}`);
}

export function readFile(workspaceUuid, rootIndex, path) {
  const query = new URLSearchParams({ rootIndex: String(rootIndex), path });
  return api(`workspaces/${encodeURIComponent(workspaceUuid)}/files/content?${query}`);
}

/** Selects a workspace (and clears the thread / file selection that belonged to the old one). */
export async function selectWorkspace(workspace) {
  set({ workspace, thread: null, threads: [], file: null }, 'selection');
  emit('threads');
  if (workspace) await loadThreads(workspace.uuid);
}

export function selectThread(thread) {
  set({ thread }, 'selection');
}
