// A session inspector independent of Symphony's execution/control interfaces.
import { $, esc, setHTML, setText, fmt, contextUrl } from './fmt.js';
import { state } from './data.js';

let selected = null;
let overview = null;
let tab = 'overview';
let type = 'all';
let query = '';
let cursor = null;
let controller = null;
let request = 0;
let returnFocus = null;
let searchTimer = null;
const TYPES = {all:'全部', message:'消息', tool:'工具', reasoning:'可见思考', event:'事件', meta:'上下文'};

export function sessionOpen() { return !$('session-overlay').hidden; }

export function openSession(id, title) {
  const session = state.sessions.find(s => s.id === id);
  if (!session) { closeSession(); return; }
  if (sessionOpen() && selected?.id === id) { selected = session; return; }
  if (!sessionOpen()) returnFocus = document.activeElement;
  selected = session;
  overview = null;
  tab = 'overview'; type = 'all'; query = ''; cursor = null;
  setText($('session-pane-title'), title || `${session.issue || 'Agent'} · ${session.role || '上下文'}`);
  const full = $('session-pane-open');
  full.href = contextUrl(session.href);
  full.hidden = !session.href || state.sessions.filter(s => s.id === id).length !== 1;
  $('session-overlay').hidden = false;
  $('app').inert = true;
  $('detail-overlay').inert = true;
  $('session-pane-close').focus();
  setHTML($('session-content'), `<div class="context-identity"><span class="eyebrow">SESSION / ${esc(session.role)}</span><h2>${esc(session.title || session.promptHead || session.issue || 'Agent 会话')}</h2><p>${esc(session.repo || '未关联仓库')} · ${esc(session.runtime)}<br><code>${esc(id)}</code></p><div class="context-actions"><button class="btn" type="button" data-context-link>复制会话链接</button><button class="btn" type="button" data-context-refresh>重新读取</button><button class="btn" type="button" data-context-export disabled>下载上下文摘要</button></div><p class="context-note">阅读期间保持当前内容；需要最新内容时点击「重新读取」。</p><span class="context-feedback" id="context-feedback" role="status"></span></div><nav class="context-tabs" aria-label="上下文视图"><button class="active" type="button" data-context-tab="overview" aria-pressed="true">概览</button><button type="button" data-context-tab="transcript" aria-pressed="false">会话记录</button></nav><div id="context-overview"></div><div id="context-transcript" hidden><div class="context-filters"><label class="search-field"><input id="context-search" type="search" maxlength="200" placeholder="搜索本页窗口的会话内容" aria-label="搜索会话记录"></label><select id="context-type" aria-label="记录类型">${Object.entries(TYPES).map(([key,label])=>`<option value="${key}">${label}</option>`).join('')}</select></div><div id="context-entries" aria-live="polite"></div></div>`);
  loadContext();
}

export function closeSession() {
  if (!sessionOpen()) return;
  request++;
  controller?.abort();
  clearTimeout(searchTimer);
  selected = null;
  overview = null;
  setHTML($('session-content'), '');
  $('session-overlay').hidden = true;
  $('app').inert = false;
  $('detail-overlay').inert = false;
  const previous = returnFocus;
  returnFocus = null;
  if (previous?.isConnected && previous.getClientRects().length) previous.focus();
}

async function loadContext(before = null) {
  if (!selected) return;
  controller?.abort();
  controller = new AbortController();
  const serial = ++request;
  const target = $(tab === 'overview' ? 'context-overview' : 'context-entries');
  setHTML(target, '<p class="context-loading">正在读取原始会话…</p>');
  const params = new URLSearchParams({limit:'50', type:tab === 'overview' ? 'all' : type});
  if (tab === 'transcript' && query.trim()) params.set('q', query.trim());
  if (before != null) params.set('before', before);
  try {
    const res = await fetch(`/api/sessions/${encodeURIComponent(selected.id)}/context?${params}`, {cache:'no-store', signal:controller.signal});
    const data = await res.json();
    if (serial !== request) return;
    if (!res.ok || data.status !== 'ok') {
      if (data.status === 'ambiguous') $('session-pane-open').hidden = true;
      throw new Error(data.status === 'ambiguous' ? '此会话 ID 对应多个来源，无法确定记录归属。请检查运行时会话标识。' : data.message || '当前会话的原始记录不可用，请等待下一次采集或检查本地缓存。');
    }
    $('session-pane-open').href = contextUrl(selected.href);
    $('session-pane-open').hidden = !selected.href || state.sessions.filter(s => s.id === selected.id).length !== 1;
    if (tab === 'overview') { overview = data; renderOverview(); $('session-content').querySelector('[data-context-export]').disabled = false; }
    else renderEntries(data);
  } catch (err) {
    if (err.name === 'AbortError' || serial !== request) return;
    setHTML(target, `<div class="context-error"><h3>无法读取上下文</h3><p>${esc(err.message)}</p><button class="btn" type="button" data-context-retry>重试</button></div>`);
  }
}

function renderOverview() {
  const s = overview.session || {};
  const latest = overview.latestAssistant;
  const stories = state.stories.filter(story => (story.beats || []).some(beat => state.tasks.find(t => t.id === beat.taskId)?.sessions?.some(item => item.id === selected.id)));
  const tokens = s.tokens;
  setHTML($('context-overview'), `<div class="context-metadata"><div><span>记录中的模型</span><b>${esc(s.model || '未记录')}</b></div><div><span>工作目录</span><b>${esc(s.workdir || '未记录')}</b></div><div><span>会话跨度</span><b>${esc(selected.duration || '未记录')}</b></div><div><span>Token 用量</span><b>${tokens ? `入 ${fmt(tokens.input_tokens)} / 出 ${fmt(tokens.output_tokens)}` : '未记录'}</b></div></div>
    ${stories.length ? `<section class="context-section"><h3>关联任务</h3>${stories.map(story=>`<a class="context-story" href="#/story/${encodeURIComponent(story.id)}" data-context-story>${esc(story.issueLabel)} · ${esc(story.title)}<span>${esc(story.outcome)} →</span></a>`).join('')}</section>` : '<p class="context-note">当前快照没有该会话与任务的关联记录。</p>'}
    <section class="context-section"><div class="context-section-head"><h3>下发指令</h3><button class="btn" type="button" data-context-copy>复制指令</button></div><p class="context-note">会话中首条用户指令，用于核对 Symphony 实际下发的任务内容。</p><pre class="context-text">${esc(s.issuedInstruction || '会话没有记录用户指令。')}</pre>${s.issuedInstructionTruncated ? '<p class="context-note">指令超过读取上限，此处为节选。</p>' : ''}</section>
    <section class="context-section"><h3>最近可见输出</h3><p class="context-note">${latest ? esc(latest.timestamp || '时间未记录') : '未记录'} · 最近一条输出可能是过程消息，请结合回执判断结果。</p><pre class="context-text">${esc(latest?.text || '尚未采集到可见的 Agent 输出。')}</pre>${latest?.truncated ? '<p class="context-note">输出较长，此处为节选。</p>' : ''}</section>
    <p class="context-source">来源 ${esc(s.source?.kind || 'codex_rollout')} · <code>${esc(s.source?.name || '未记录')}</code><br>查看与复制均不会修改运行时。记录反映采集时的内容。</p>`);
}

function renderEntries(data) {
  cursor = data.page?.nextBefore ?? null;
  const entries = data.entries || [];
  const body = entries.map(item=>`<article class="context-entry"><header><span class="badge ${item.role === 'assistant' ? 'b-running' : ''}">${esc(item.type === 'message' ? (item.role || '消息') : TYPES[item.type] || item.type)}</span><b>${esc(item.name || item.channel || '')}</b><span class="record-source">${esc(item.source || '')}</span><time>${esc(item.timestamp || '')}</time></header><pre class="context-text">${esc(item.text || '（没有可见文本）')}</pre>${item.truncated ? `<p class="context-note">记录较长，仅展示前 16,384 个字符。${item.matchBeyondPreview ? '搜索命中位于节选之外。' : ''}其余内容请打开「完整记录」。</p>` : ''}</article>`).join('');
  setHTML($('context-entries'), `<p class="context-note">本页 ${entries.length} 条 · 从最近记录向前读取，页内按发生顺序展示。搜索仅覆盖本次读取窗口；更多内容请继续向前读取。${data.page?.hasOlder ? '还有更早记录。' : ''} 同一消息的事件记录与响应记录会保留各自来源。</p>${body || '<div class="empty-state"><h3>本页没有匹配内容</h3><p>可以更改筛选，或继续读取更早的记录。</p></div>'}<div class="context-pagination"><button class="btn" type="button" data-context-latest>返回最近记录</button>${data.page?.hasOlder && cursor != null ? '<button class="btn" type="button" data-context-older>读取更早记录 ←</button>' : '<span class="muted">已到记录起点</span>'}</div>`);
}

async function copy(text, message) {
  try { await navigator.clipboard.writeText(text); setText($('context-feedback'), message); }
  catch { setText($('context-feedback'), '浏览器未允许复制，请选择文本后复制。'); }
}

function exportOverview() {
  if (!overview) return;
  const s = overview.session;
  const text = `# Agent 上下文摘要\n\n会话：${selected.id}\n角色：${selected.role}\n仓库：${selected.repo || '未记录'}\n来源：${s.source?.name || '未记录'}\n模型：${s.model || '未记录'}\n\n## 下发指令${s.issuedInstructionTruncated ? '（节选）' : ''}\n\n${s.issuedInstruction || '未记录'}\n\n## 最近可见输出${overview.latestAssistant?.truncated ? '（节选）' : ''}\n\n${overview.latestAssistant?.text || '未记录'}\n\n此文件是采集记录的摘要，不包含完整会话，不代表任务已完成。\n`;
  const url = URL.createObjectURL(new Blob([text], {type:'text/markdown;charset=utf-8'}));
  const a = document.createElement('a'); a.href = url; a.download = `agent-${selected.id}.md`; a.click(); setTimeout(()=>URL.revokeObjectURL(url), 1000);
}

$('session-content').addEventListener('click', e => {
  const button = e.target.closest('button, a');
  if (!button) return;
  if (button.hasAttribute('data-context-tab')) {
    tab = button.dataset.contextTab;
    $('context-overview').hidden = tab !== 'overview';
    $('context-transcript').hidden = tab !== 'transcript';
    document.querySelectorAll('[data-context-tab]').forEach(b=>{b.classList.toggle('active', b === button); b.setAttribute('aria-pressed', String(b === button));});
    if (tab === 'overview' && overview) { request++; controller?.abort(); renderOverview(); }
    else loadContext();
  } else if (button.hasAttribute('data-context-copy')) copy(overview?.session?.issuedInstruction || '', '指令已复制');
  else if (button.hasAttribute('data-context-link')) copy(`${location.origin}${location.pathname}#/agents/${encodeURIComponent(selected.id)}`, '会话链接已复制');
  else if (button.hasAttribute('data-context-export')) exportOverview();
  else if (button.hasAttribute('data-context-refresh')) { selected = state.sessions.find(s => s.id === selected.id) || selected; overview = null; clearTimeout(searchTimer); loadContext(); }
  else if (button.hasAttribute('data-context-older')) loadContext(cursor);
  else if (button.hasAttribute('data-context-latest') || button.hasAttribute('data-context-retry')) loadContext();
  else if (button.hasAttribute('data-context-story')) closeSession();
});
$('session-content').addEventListener('input', e => {
  if (e.target.id !== 'context-search') return;
  query = e.target.value;
  clearTimeout(searchTimer);
  // Stop the previous request as soon as the query changes.
  request++; controller?.abort();
  searchTimer = setTimeout(()=>loadContext(), 250);
});
$('session-content').addEventListener('change', e => { if (e.target.id === 'context-type') { type = e.target.value; clearTimeout(searchTimer); loadContext(); } });
$('session-pane').addEventListener('keydown', e => {
  if (e.key !== 'Tab') return;
  const items = [...$('session-pane').querySelectorAll('a[href],button:not([disabled]),input,select,summary')].filter(el=>el.getClientRects().length);
  const first = items[0], last = items.at(-1);
  if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last?.focus(); }
  else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first?.focus(); }
});
