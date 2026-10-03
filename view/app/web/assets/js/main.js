// Boot: hash router + polling loop + event wiring.

import { $, setText } from './fmt.js';
import { state, pollOnce, pollBoot, onDataChange, filters, selection, persist, ensureSelection } from './data.js';
import { renderChrome } from './chrome.js';
import { renderBoardView } from './board.js';
import { renderDetail, openDetail, closeDetail, openSession, closeSession, sessionOpen } from './detail.js';
import { renderAgentsPage, renderSettingsPage, setAgentRoleFilter, setAgentQuery, setAgentSort, resetAgentFilters } from './pages.js';
import { handleEvents, clearUnread } from './notify.js';

const VIEWS = ['board', 'agents', 'settings'];

function currentView() {
  const hash = location.hash || '#/board';
  const name = hash.replace(/^#\//, '').split('/')[0];
  return VIEWS.includes(name) ? name : 'board';
}

function applyRoute() {
  const view = currentView();
  const hash = location.hash || '#/board';
  // #/story/<id> deep link: board view + open detail
  const storyMatch = hash.match(/^#\/story\/(.+)$/);
  VIEWS.forEach(name => {
    const el = document.getElementById('view-' + name);
    if (el) el.hidden = name !== view;
  });
  renderChrome(view);
  if (view === 'agents') renderAgentsPage();
  else if (view === 'settings') renderSettingsPage();
  if (storyMatch) {
    const storyId = routeId(storyMatch[1]);
    if (state.stories.some(s => s.id === storyId)) openDetail(storyId);
    else closeDetail();
  } else {
    closeDetail();
  }
  if (view === 'board') renderBoardView();
  const sessionId = sessionRoute();
  if (sessionId) openRoutedSession(sessionId);
  else closeSession();
}

function routeId(value) { try { return decodeURIComponent(value); } catch { return ''; } }
function sessionRoute() { const match = location.hash.match(/^#\/agents\/(.+)$/); return match ? routeId(match[1]) : ''; }
function openRoutedSession(id) {
  openSession(id);
  if (state.ready && !state.sessions.some(s => s.id === id)) setText($('agent-note'), '请求的会话不在当前采集快照中，请检查链接或等待采集。');
}
function dismissSession() {
  closeSession();
  if (sessionRoute()) { history.replaceState(null, '', '#/agents'); applyRoute(); }
}

function detailPinned() {
  return /^#\/story\//.test(location.hash);
}

function renderCurrent() {
  renderChrome(currentView());
  const view = currentView();
  if (view === 'board') { ensureSelection(); renderBoardView(); renderDetail(); }
  else if (view === 'agents') { renderAgentsPage(); if (sessionRoute()) openRoutedSession(sessionRoute()); }
  else if (view === 'settings') renderSettingsPage();
}

function showBootEmpty(show, reason) {
  const el = document.getElementById('boot-empty');
  el.hidden = !show;
  if (reason) setText(document.getElementById('boot-empty-reason'), reason);
}

// ---------- wiring ----------
function wire() {
  window.addEventListener('hashchange', applyRoute);

  document.getElementById('sb-nav').addEventListener('click', e => {
    const item = e.target.closest('.nav-item');
    if (!item) return;
    // default anchor navigation updates the hash; nothing else to do
  });

  document.getElementById('sb-repos').addEventListener('click', e => {
    const btn = e.target.closest('[data-repo]');
    if (!btn) return;
    // 仓库是筛选不是页面：再点当前仓库 = 取消筛选回到全部
    filters.repo = filters.repo === btn.dataset.repo ? 'all' : btn.dataset.repo;
    filters.runtime = 'all';
    persist();
    renderCurrent();
  });

  document.getElementById('topbar').addEventListener('click', e => {
    if (e.target.closest('#repo-clear')) {
      e.preventDefault();
      filters.repo = 'all';
      persist();
      renderCurrent();
    }
  });

  document.getElementById('rt-nav').addEventListener('click', e => {
    const btn = e.target.closest('[data-rt]');
    if (!btn) return;
    filters.runtime = btn.dataset.rt;
    persist();
    renderCurrent();
  });

  document.getElementById('board').addEventListener('click', e => {
    if (e.target.closest('a')) return;
    const card = e.target.closest('[data-story]');
    if (!card) return;
    const storyId = card.dataset.story;
    if (location.hash === '#/story/' + storyId) openDetail(storyId);
    else location.hash = '#/story/' + storyId;
  });

  document.getElementById('detail-pane').addEventListener('click', e => {
    if (e.target.closest('#detail-close')) {
      history.replaceState(null, '', '#/board');
      applyRoute();
      return;
    }
    const sessionCard = e.target.closest('[data-session]');
    if (sessionCard) {
      e.preventDefault();
      openSession(sessionCard.dataset.session, sessionCard.dataset.title);
      return;
    }
    const beat = e.target.closest('[data-beat]');
    if (beat) {
      selection.beat = beat.dataset.beat;
      persist();
      renderDetail();
    }
  });

  document.getElementById('detail-overlay').addEventListener('click', e => {
    if (e.target.id === 'detail-overlay') {
      history.replaceState(null, '', '#/board');
      applyRoute();
    }
  });

  document.getElementById('agent-tools').addEventListener('click', e => {
    const chip = e.target.closest('[data-srole]');
    if (chip) setAgentRoleFilter(chip.dataset.srole);
  });

  document.getElementById('agent-groups').addEventListener('click', e => {
    if (e.target.closest('[data-agent-reset]')) { resetAgentFilters(); return; }
    const card = e.target.closest('[data-session]');
    if (!card) return;
    e.preventDefault();
    const hash = '#/agents/' + encodeURIComponent(card.dataset.session);
    if (location.hash === hash) openSession(card.dataset.session, card.dataset.title);
    else location.hash = hash;
  });

  $('agent-search').addEventListener('input', e => setAgentQuery(e.target.value));
  $('agent-sort').addEventListener('change', e => setAgentSort(e.target.value));

  document.getElementById('session-pane-close').addEventListener('click', dismissSession);
  document.getElementById('session-overlay').addEventListener('click', e => {
    if (e.target.id === 'session-overlay') dismissSession();
  });

  document.getElementById('refresh-now').addEventListener('click', async () => {
    await pollBoot();
    handleEvents(await pollOnce());
  });

  document.getElementById('theme-toggle').addEventListener('click', () => {
    const next = document.documentElement.dataset.theme === 'light' ? 'dark' : 'light';
    document.documentElement.dataset.theme = next;
    localStorage.setItem('theme', next);
  });

  window.addEventListener('focus', clearUnread);

  document.addEventListener('keydown', e => {
    if (e.key === 'Escape') {
      if (sessionOpen()) dismissSession();
      else if (detailPinned()) {
        history.replaceState(null, '', '#/board');
        applyRoute();
      }
    }
    if (e.key === '/' && !sessionOpen() && !e.target.closest('input,textarea,select,[contenteditable="true"]')) {
      const search = currentView() === 'agents' ? $('agent-search') : document.querySelector('[data-board-search]');
      if (search) { e.preventDefault(); search.focus(); }
    }
  });
}

// ---------- boot ----------
async function boot() {
  wire();
  applyRoute();
  await pollBoot();
  const changed = await pollOnce();
  if (!state.ready) {
    showBootEmpty(true, state.connection === 'error' ? '无法连接看板服务，请检查本地进程。恢复连接后页面会自动重试。' : state.boot.collection?.status === 'error' ? '运行时采集失败。请检查 WSL 和运行目录；恢复后会自动采集。' : '采集循环尚未完成第一拍，采集成功后会自动出现。');
  } else {
    showBootEmpty(false);
    applyRoute();
  }
  const intervalMs = Math.max(2, Number(state.boot.interval) || 5) * 1000;
  setInterval(async () => {
    await pollBoot();
    handleEvents(await pollOnce());
  }, intervalMs);
  document.addEventListener('visibilitychange', async () => {
    if (!document.hidden) { await pollBoot(); handleEvents(await pollOnce()); }
  });
}

onDataChange(() => {
  if (!state.ready) { renderChrome(currentView()); showBootEmpty(true, state.connection === 'error' ? '无法连接看板服务，请检查本地进程。' : state.boot.collection?.status === 'error' ? '运行时采集失败，请检查 WSL 和运行目录。' : '采集循环尚未完成第一拍，采集成功后会自动出现。'); return; }
  showBootEmpty(false);
  renderCurrent();
});

boot();
