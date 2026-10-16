// Sidebar (workspace nav, repo list, pending runtimes) + topbar chrome.

import { $, esc, setText, setHTML } from './fmt.js';
import { state, filters, boardRuntimes, runtimeRoot, visibleSessions } from './data.js';

const NAV_TITLES = { board: '任务看板', agents: 'Agent 上下文', settings: '设置' };

export function renderChrome(activeView) {
  // nav active state
  document.querySelectorAll('#sb-nav .nav-item').forEach(item => {
    item.classList.toggle('active', item.dataset.view === activeView);
  });
  // workspace title
  setText($('ws-title'), state.boot.title || 'innovation-view');
  // crumb
  setText($('crumb'), NAV_TITLES[activeView] || '任务看板');
  setHTML($('crumb-sub'), filters.repo === 'all'
    ? '全部仓库'
    : `${esc(filters.repo)} <a class="clear-filter" id="repo-clear" href="#" title="清除仓库筛选">×</a>`);
  // agents count
  setText($('nav-sessions-count'), state.sessions.length ? String(visibleSessions().length) : '');
  // Connection and collection health are distinct from a task being blocked.
  const dot = $('node-dot');
  const collection = state.boot.collection || {};
  const stale = collection.lastSuccess && Date.now() - Date.parse(collection.lastSuccess) > Math.max(60, (Number(state.boot.interval) || 5) * 3) * 1000;
  const unhealthy = state.connection === 'error' || ['error', 'empty'].includes(collection.status) || stale;
  if (dot) dot.classList.toggle('warn', Boolean(unhealthy));
  setText($('live-label'), state.connection === 'error' ? '服务断开 · 保留旧数据' : collection.status === 'error' ? '采集失败 · 保留旧数据' : collection.status === 'empty' ? '未发现运行目录' : stale ? '数据已过期' : collection.status === 'ok' ? '只读采集 · 正常' : '等待采集');
  if ($('live-label')) $('live-label').title = collection.lastError || (collection.lastSuccess ? `最近采集成功：${collection.lastSuccess}` : '等待采集状态');
  // generated stamp
  setText($('gen-stamp'), state.generated);
  // runtime root line (bottom of sidebar)
  const names = boardRuntimes();
  const rootEl = $('sb-root');
  if (names.length === 1) {
    setText(rootEl, '运行目录 ' + runtimeRoot(names[0]));
    rootEl.title = runtimeRoot(names[0]);
  } else {
    setText(rootEl, names.length ? `${names.length} 个运行时` : '');
    rootEl.title = '';
  }
  renderRepoList(repoNames());
  renderPending();
  renderRuntimeChips();
}

function repoNames() {
  const configured = (state.boot && state.boot.repos ? state.boot.repos : [])
    .filter(r => r.enabled !== false)
    .map(r => r.alias || r.name);
  const fromData = [...state.stories, ...state.sessions].map(s => s.repo).filter(Boolean);
  return [...new Set([...configured, ...fromData])].sort((a, b) => a.localeCompare(b, 'zh-CN'));
}

function renderRepoList(repos) {
  const el = $('sb-repos');
  if (!repos.length) {
    setHTML(el, '<span class="sb-pending-row"><small>看板上还没有仓库数据</small></span>');
    return;
  }
  // 仓库区是筛选器，不是页面导航：没有"全部仓库"入口，再点一次当前仓库即取消筛选。
  setHTML(el, repos.map(name => `
    <button class="sb-repo ${name === filters.repo ? 'active' : ''}" type="button" data-repo="${esc(name)}" title="${esc(name)}">
      <span class="repo-dot" aria-hidden="true"></span>
      <span class="lbl">${esc(name)}</span>
      <small>${state.stories.filter(s => s.repo === name).length}</small>
    </button>`).join(''));
}

function renderPending() {
  const pending = (state.boot.pending || []);
  const section = $('sb-pending-section');
  if (!pending.length) { section.hidden = true; return; }
  section.hidden = false;
  setText($('sb-pending-count'), String(pending.length));
  setHTML($('sb-pending'), pending.map(item => `
    <span class="sb-pending-row">
      <b>${esc(item.repo)}</b>
      <small>运行时 ${esc(item.runtime)} · 在 app/config.toml 的 [[repos]] 里登记后接入</small>
    </span>`).join(''));
}

function renderRuntimeChips() {
  const pool = [...state.stories, ...state.sessions].filter(s => filters.repo === 'all' || s.repo === filters.repo);
  const names = [...new Set(pool.map(s => s.runtime).filter(Boolean))].sort((a, b) => a.localeCompare(b, 'en'));
  const nav = $('rt-nav');
  if (names.length <= 1) { setHTML(nav, ''); return; }
  const items = [{ id: 'all', label: '全部', count: pool.length }]
    .concat(names.map(name => ({ id: name, label: name, count: pool.filter(s => s.runtime === name).length })));
  setHTML(nav, items.map(item =>
    `<button class="chip ${item.id === filters.runtime ? 'active' : ''}" type="button" data-rt="${esc(item.id)}">${esc(item.label)}<small>${item.count}</small></button>`
  ).join(''));
}
