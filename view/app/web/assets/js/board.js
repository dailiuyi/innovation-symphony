// 任务看板：任务状态、关联会话与本地浏览筛选。
import { $, esc, setHTML, setText, prAnchor, stallBadgeInfo } from './fmt.js';
import { state, visibleStories, selection, ensureSelection, showRuntime, taskById } from './data.js';

const COLUMNS = [
  { id: 'blocked', title: '需关注', hint: '任务受阻、Review 打回或等待跟进', kinds: ['blocked'] },
  { id: 'running', title: '进行中', hint: '当前任务仍在执行', kinds: ['running', 'other'] },
  { id: 'human', title: '待人审', hint: 'Review 已通过，等待人工处理 PR', kinds: ['human'] },
  { id: 'done', title: '已交付', hint: '已合并或已交付', kinds: ['done'] },
];

const SAFE_BADGES = new Set(['b-blocked', 'b-review', 'b-done', 'b-check', 'b-diagnose', 'b-running', 'b-queued']);
const boardView = {
  query: localStorage.getItem('board-query') || '',
  attentionOnly: localStorage.getItem('board-attention') === 'true',
  layout: localStorage.getItem('board-layout') === 'list' ? 'list' : 'board',
};

function stallBadge(task) {
  const text = stallBadgeInfo(task, state.boot.stallHours);
  if (!text) return '';
  return `<span class="stall" title="进入${esc(task.statusLabel)}已 ${esc(text)}">⏱ ${esc(text)}</span>`;
}

function mountBoardTools() {
  const tools = $('board-tools');
  if (!tools) return null;

  if (!tools.dataset.boardMounted) {
    setHTML(tools, `
      <div class="board-tools board-tools-row">
        <label class="board-search">
          <span class="board-search-label">搜索</span>
          <input class="board-search-input" data-board-search type="search" autocomplete="off"
            placeholder="搜索标题、Issue、仓库或 Agent 角色"
            aria-label="搜索任务标题、Issue、仓库或 Agent 角色">
        </label>
        <button class="board-filter" type="button" data-board-attention aria-pressed="false">仅需关注</button>
        <div class="board-layout" role="group" aria-label="显示方式">
          <button class="board-layout-option" type="button" data-board-layout="board" aria-pressed="true">看板</button>
          <button class="board-layout-option" type="button" data-board-layout="list" aria-pressed="false">紧凑列表</button>
        </div>
        <button class="board-clear" type="button" data-board-clear hidden>清除看板筛选</button>
      </div>`);
    tools.dataset.boardMounted = 'true';

    // Toolbar events stay delegated here so polling can redraw the board without
    // removing the focused search input or resetting its caret.
    tools.addEventListener('input', event => {
      const input = event.target.closest('[data-board-search]');
      if (!input) return;
      boardView.query = input.value;
      localStorage.setItem('board-query', boardView.query);
      renderBoardView();
    });

    tools.addEventListener('click', event => {
      const target = event.target instanceof Element ? event.target : null;
      if (!target) return;

      if (target.closest('[data-board-clear]')) {
        boardView.query = '';
        boardView.attentionOnly = false;
        localStorage.setItem('board-query', '');
        localStorage.setItem('board-attention', 'false');
        renderBoardView();
        return;
      }

      if (target.closest('[data-board-attention]')) {
        boardView.attentionOnly = !boardView.attentionOnly;
        localStorage.setItem('board-attention', String(boardView.attentionOnly));
        renderBoardView();
        return;
      }

      const layoutButton = target.closest('[data-board-layout]');
      if (layoutButton) {
        const layout = layoutButton.dataset.boardLayout;
        if (layout !== 'board' && layout !== 'list') return;
        boardView.layout = layout;
        localStorage.setItem('board-layout', layout);
        renderBoardView();
      }
    });
  }

  const input = tools.querySelector('[data-board-search]');
  if (input && document.activeElement !== input && input.value !== boardView.query) {
    input.value = boardView.query;
  }
  const attention = tools.querySelector('[data-board-attention]');
  if (attention) attention.setAttribute('aria-pressed', String(boardView.attentionOnly));
  tools.querySelectorAll('[data-board-layout]').forEach(button => {
    button.setAttribute('aria-pressed', String(button.dataset.boardLayout === boardView.layout));
  });
  const clear = tools.querySelector('[data-board-clear]');
  if (clear) clear.hidden = !boardView.query.trim() && !boardView.attentionOnly;
  return tools;
}

function storySessions(story) {
  const seen = new Set();
  const sessions = [];
  for (const beat of story.beats || []) {
    const task = beat.taskId ? taskById(beat.taskId) : null;
    for (const session of (task && task.sessions) || []) {
      const id = String(session && session.id || '');
      if (!id || seen.has(id)) continue;
      seen.add(id);
      sessions.push(session);
    }
  }
  return sessions.map((session, index) => ({
    session,
    index,
    timestamp: Date.parse(session.lastTs || session.firstTs || ''),
  })).sort((a, b) => {
    const aValid = Number.isFinite(a.timestamp);
    const bValid = Number.isFinite(b.timestamp);
    if (aValid && bValid) return a.timestamp - b.timestamp || a.index - b.index;
    if (aValid !== bValid) return aValid ? 1 : -1;
    return a.index - b.index;
  }).map(item => item.session);
}

function searchText(story) {
  const values = [story.issueLabel, story.repo, story.runtime, story.title, story.outcome, story.outcomeDetail];
  for (const beat of story.beats || []) {
    values.push(beat.label, beat.statusLabel, beat.handoff);
    const task = beat.taskId ? taskById(beat.taskId) : null;
    if (!task) continue;
    values.push(task.issueLabel, task.statusLabel, task.result);
    for (const session of task.sessions || []) values.push(session.role);
  }
  return values.filter(Boolean).join(' ').toLocaleLowerCase();
}

function filteredStories(stories) {
  const query = boardView.query.trim().toLocaleLowerCase();
  return stories.filter(story => {
    if (boardView.attentionOnly && story.outcomeKind !== 'blocked') return false;
    return !query || searchText(story).includes(query);
  });
}

export function renderBoardView() {
  ensureSelection();
  mountBoardTools();
  const available = visibleStories();
  const stories = filteredStories(available);
  const count = kind => stories.filter(story => story.outcomeKind === kind).length;
  setHTML($('stats'), `
    <div class="stat k-blocked"><div class="key">需关注</div><div class="value">${count('blocked')}</div></div>
    <div class="stat k-running"><div class="key">进行中</div><div class="value">${count('running') + count('other')}</div></div>
    <div class="stat k-human"><div class="key">待人审</div><div class="value">${count('human')}</div></div>
    <div class="stat k-done"><div class="key">已交付</div><div class="value">${count('done')}</div></div>`);

  const board = $('board');
  if (board) board.classList.toggle('is-compact-list', boardView.layout === 'list');
  setHTML(board, COLUMNS.map(col => {
    const items = stories.filter(story => col.kinds.includes(story.outcomeKind));
    const emptyText = boardView.query.trim() || boardView.attentionOnly
      ? '当前筛选下没有任务'
      : '这一列还没有任务';
    const cards = items.map(story => cardHTML(story)).join('') || `<div class="empty-col">${esc(emptyText)}</div>`;
    return `<div class="column col-${col.id}">
      <div class="col-head"><span class="col-mark"></span><span>${esc(col.title)}</span><b>${items.length}</b></div>
      <p class="col-hint">${esc(col.hint)}</p>
      <div class="cards">${cards}</div>
    </div>`;
  }).join(''));

  const hasLocalFilter = Boolean(boardView.query.trim() || boardView.attentionOnly);
  const note = hasLocalFilter
    ? `显示 ${stories.length} / ${available.length} 条当前仓库与运行时筛选结果 · 点卡片打开任务详情。`
    : `${available.length} / ${state.stories.length} 条任务 · 同一仓库、同一运行时、同一 Issue 是一条。`;
  setText($('board-note'), note);
}

function cardHTML(story) {
  const beats = story.beats || [];
  const lastBeat = beats[beats.length - 1] || {};
  const why = lastBeat.handoff || story.outcomeDetail || story.outcome || '';
  const runtimePill = showRuntime() ? `<span class="runtime">${esc(story.runtime || '')}</span>` : '';
  const stall = stallBadge(lastBeat.taskId ? taskById(lastBeat.taskId) : null);
  const badge = SAFE_BADGES.has(story.badge) ? story.badge : '';
  const sessions = storySessions(story);
  const agentFoot = sessions.length
    ? ` · 累计 ${sessions.length} 次会话 · 最近角色 ${esc(sessions[sessions.length - 1].role || '未记录')}`
    : ' · 未关联 Agent 会话';

  return `<div class="card-wrap">
    <button class="card${story.id === selection.story ? ' selected' : ''}" type="button" data-story="${esc(story.id)}">
      <div class="card-top">${runtimePill}<span class="top-right">${stall}<span class="badge ${badge}">${esc(story.outcome)}</span></span></div>
      <div class="issue">${esc(story.issueLabel)} <span class="card-repo">${esc(story.repo || '—')}</span></div>
      <div class="card-title">${esc(story.title)}</div>
      <div class="card-why">${esc(why)}</div>
      <div class="card-foot">${esc(story.attempts)} 次尝试${agentFoot}</div>
    </button>
    ${prAnchor(story.pr)}
  </div>`;
}
