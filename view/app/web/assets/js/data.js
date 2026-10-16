// Client-side data store + polling. Snapshot arrives from /api/snapshot with ETag.
// demo 原型只消费 tasks / stories / sessions；控制器日志不再有页面展示，
// 因此不入库、也不参与内容签名。

export const state = {
  boot: {},
  tasks: [],
  stories: [],
  sessions: [],
  runtimes: [],
  idPrefixes: new Map(),
  generated: '',
  ready: false,
  connection: 'connecting',
};

const listeners = [];
export function onDataChange(fn) { listeners.push(fn); }
function notify() { for (const fn of listeners) fn(); }

let etag = '';
let inflight = false;
let prevTaskStates = null; // Map(id -> {status, prState}) 用于检测状态变迁

function dataSig(d) {
  return JSON.stringify([d.tasks, d.stories, d.sessions, d.runtimes]);
}
let snapshotSig = '';
let bootSig = '';
function connection(status) {
  if (state.connection === status) return;
  state.connection = status;
  notify();
}

function statusEvents(tasks) {
  if (!prevTaskStates) return [];
  const events = [];
  for (const t of tasks) {
    const p = prevTaskStates.get(t.id);
    if (!p) continue;
    const before = p.status + '|' + (p.prState || '');
    const after = t.status + '|' + ((t.pr && t.pr.state) || '');
    if (before === after) continue;
    const pr = (t.pr && t.pr.state) || '';
    let kind = null, title = '';
    if (pr === 'merged' || t.status === 'done' || t.status === 'merged') { kind = 'good'; title = '已交付'; }
    else if (['awaiting_human', 'awaiting_review', 'pr_ready'].includes(t.status)) { kind = 'human'; title = '进入人审'; }
    else if (t.status === 'blocked') { kind = 'bad'; title = '需关注'; }
    if (!kind) continue;
    events.push({
      taskId: t.id,
      issueLabel: t.issueLabel,
      repo: t.repo,
      title,
      detail: t.statusLabel + (pr && pr !== 'unknown' ? ` · PR ${pr}` : ''),
      kind,
    });
  }
  return events;
}

function snapshotTaskStates(tasks) {
  const map = new Map();
  for (const t of tasks) map.set(t.id, { status: t.status, prState: (t.pr && t.pr.state) || '' });
  return map;
}

export async function pollOnce() {
  if (inflight) return [];
  inflight = true;
  try {
    const headers = etag ? { 'If-None-Match': etag } : {};
    const res = await fetch('/api/snapshot', { cache: 'no-store', headers });
    if (res.status === 304) { connection('ok'); return []; }
    if (!res.ok) throw new Error('snapshot unavailable');
    const data = await res.json();
    if (!data || !Array.isArray(data.tasks) || !Array.isArray(data.stories)) { connection('ok'); return []; }
    etag = res.headers.get('ETag') || '';
    connection('ok');
    const sig = dataSig(data);
    state.generated = data.generated || '';
    if (sig === snapshotSig && state.ready) { notify(); return []; }
    const events = statusEvents(data.tasks);
    prevTaskStates = snapshotTaskStates(data.tasks);
    snapshotSig = sig;
    state.tasks = data.tasks;
    state.stories = data.stories;
    state.sessions = Array.isArray(data.sessions) ? data.sessions : [];
    state.idPrefixes = buildIdPrefixes(state.sessions);
    state.runtimes = Array.isArray(data.runtimes) ? data.runtimes : [];
    state.generated = data.generated || '';
    state.ready = true;
    normalizeFilters();
    notify();
    return events;
  } catch (err) {
    connection('error');
    return [];
  } finally {
    inflight = false;
  }
}

export async function pollBoot() {
  try {
    const res = await fetch('/api/bootstrap', { cache: 'no-store' });
    if (!res.ok) throw new Error('bootstrap unavailable');
    const boot = await res.json();
    const sig = JSON.stringify(boot);
    state.boot = boot;
    const title = state.boot.title || 'innovation-view';
    document.title = title + ' · 任务看板';
    if (sig !== bootSig) { bootSig = sig; notify(); }
  } catch (err) { connection('error'); }
}

// ---------- filters + selection (persist like the legacy workbench) ----------
export const filters = {
  repo: localStorage.getItem('repo-filter') || 'all',
  runtime: localStorage.getItem('rt-filter') || 'all',
};
export const selection = {
  story: localStorage.getItem('sel-story') || null,
  beat: localStorage.getItem('sel-beat') || localStorage.getItem('sel-task') || null,
  logId: localStorage.getItem('log-id') || '',
  logMode: localStorage.getItem('log-mode') || 'key',
};
export function persist() {
  localStorage.setItem('repo-filter', filters.repo);
  localStorage.setItem('rt-filter', filters.runtime);
  localStorage.setItem('sel-story', selection.story || '');
  localStorage.setItem('sel-beat', selection.beat || '');
  localStorage.setItem('log-id', selection.logId);
  localStorage.setItem('log-mode', selection.logMode);
}

// ---------- visibility helpers ----------
export function boardRuntimes() {
  return [...new Set([...state.stories, ...state.sessions].map(s => s.runtime).filter(Boolean))].sort((a, b) => a.localeCompare(b, 'en'));
}
export function showRuntime() { return boardRuntimes().length > 1; }
export function runtimeRoot(name) {
  const found = (state.runtimes || []).find(item => item.name === name);
  return found && found.root ? found.root : name;
}
function runtimeMatches(runtime) { return filters.runtime === 'all' || runtime === filters.runtime; }
function sessionMatchesRepo(session) {
  if (filters.repo === 'all') return true;
  if (session.repo === filters.repo) return true;
  if (!session.repo && session.role === '预检') return state.stories.some(s => s.repo === filters.repo && s.runtime === session.runtime);
  return false;
}
export function visibleStories() {
  return state.stories.filter(s => (filters.repo === 'all' || s.repo === filters.repo) && runtimeMatches(s.runtime));
}
export function visibleSessions() {
  return state.sessions.filter(s => runtimeMatches(s.runtime) && sessionMatchesRepo(s));
}
export function storyById(id) { return state.stories.find(s => s.id === id) || null; }
export function taskById(id) { return state.tasks.find(t => t.id === id) || null; }

// 会话 id 的展示前缀：UUIDv7 的前 8 位在同一分钟内会重复，同一运行时里可能
// 出现两个 agent 顶着同一个 8 位编号。这里按需加长，保证界面上能区分开。
function buildIdPrefixes(sessions) {
  const ids = sessions.map(s => String(s.id || ''));
  const map = new Map();
  for (const id of ids) {
    let len = Math.min(8, id.length);
    while (len < id.length && ids.some(other => other !== id && other.slice(0, len) === id.slice(0, len))) len += 1;
    map.set(id, id.slice(0, len));
  }
  return map;
}
export function displayId(session) {
  return state.idPrefixes.get(session.id) || session.short || String(session.id || '').slice(0, 8);
}

export function ensureSelection() {
  normalizeFilters();
  const stories = visibleStories();
  if (!stories.some(s => s.id === selection.story)) {
    const fromBeat = stories.find(s => (s.beats || []).some(b => b.taskId === selection.beat));
    selection.story = fromBeat ? fromBeat.id : (stories.find(s => s.outcomeKind === 'human') || stories[0] || {}).id || null;
  }
  const story = storyById(selection.story);
  if (story && !(story.beats || []).some(b => b.taskId === selection.beat)) {
    selection.beat = (story.beats[story.beats.length - 1] || {}).taskId || null;
  }
}

function normalizeFilters() {
  const all = [...state.stories, ...state.sessions];
  const configured = (state.boot && state.boot.repos ? state.boot.repos : [])
    .filter(r => r.enabled !== false)
    .map(r => r.alias || r.name);
  if (filters.repo !== 'all' && !all.some(s => s.repo === filters.repo) && !configured.includes(filters.repo)) filters.repo = 'all';
  const pool = all.filter(s => filters.repo === 'all' || s.repo === filters.repo);
  if (filters.runtime !== 'all' && !pool.some(s => s.runtime === filters.runtime)) filters.runtime = 'all';
}
