// Story detail slide-over + agent context transcript overlay.
// demo 原型：只回答「这条任务怎么走过来」「每一轮为什么没过、谁在跑」。

import {
  $, esc, setHTML, setText, fmt, prAnchor, stepLabel, beatSteps,
  contextUrl, stallBadgeInfo,
} from './fmt.js';
import { state, selection, persist, storyById, taskById, showRuntime, displayId } from './data.js';
import { roundsModel, reviewAttempts, attemptLabel } from './rounds.js';

// 展开状态：轮次/原文的 details 在面板重绘后保持展开，避免看的时候被刷新收起来。
const openKeys = new Set();
let lastPaneKey = '';

$('detail-pane').addEventListener('toggle', event => {
  const el = event.target;
  const key = el && el.dataset ? el.dataset.openKey : '';
  if (!key) return;
  if (el.open) openKeys.add(key); else openKeys.delete(key);
}, true);

function restoreOpenState() {
  document.querySelectorAll('#detail-pane details[data-open-key]').forEach(el => {
    el.open = openKeys.has(el.dataset.openKey);
  });
}

export function openDetail(storyId) {
  // Un-hide first: renderDetail skips while the overlay is hidden.
  $('detail-overlay').hidden = false;
  selection.story = storyId;
  const story = storyById(storyId);
  if (story && (story.beats || []).length) {
    if (!(story.beats || []).some(b => b.taskId === selection.beat)) {
      selection.beat = story.beats[story.beats.length - 1].taskId;
    }
  }
  persist();
  renderDetail();
}

export function closeDetail() {
  $('detail-overlay').hidden = true;
}

export function renderDetail() {
  if ($('detail-overlay').hidden) return;
  const story = storyById(selection.story);
  if (!story) { closeDetail(); return; }
  const beats = story.beats || [];
  if (!beats.some(b => b.taskId === selection.beat)) selection.beat = (beats[beats.length - 1] || {}).taskId || null;
  const cur = taskById(selection.beat);

  const paneKey = `${selection.story}|${selection.beat}`;
  if (paneKey !== lastPaneKey) { openKeys.clear(); lastPaneKey = paneKey; }

  const lastBeatTask = taskById((story.beats || [])[story.beats.length - 1]?.taskId);
  const stallInfo = stallBadgeInfo(lastBeatTask, state.boot.stallHours);
  const head = `<div class="detail-head">
    <div class="dh-main">
      <span class="badge ${esc(story.badge)}">${esc(story.outcome)}</span>
      <h2>${esc(story.title)}</h2>
      <div class="dh-meta">${esc(story.meta)}</div>
      ${stallInfo ? `<div class="dh-meta stall-line">⏱ 停在${esc(lastBeatTask.statusLabel || '人工')}已 ${esc(stallInfo)}</div>` : ''}
    </div>
    <button class="icon-btn" type="button" id="detail-close" title="关闭">✕</button>
  </div>`;

  const prRow = story.pr && story.pr.url ? `<div class="pr-row">${prAnchor(story.pr)}</div>` : '';

  const rail = beats.map((b, i) => {
    const last = i === beats.length - 1;
    const selected = b.taskId === selection.beat;
    const steps = beatSteps(b, story, last);
    const tone = steps.length ? steps[steps.length - 1].tone : 'run';
    const side = [b.label, b.duration && b.duration !== '—' ? b.duration : ''].filter(Boolean).join(' · ');
    const step = steps[steps.length - 1] || { title: b.statusLabel || '这一拍', why: '', tone };
    return `<button class="node ${tone}${selected ? ' selected' : ''}" type="button" data-beat="${esc(b.taskId)}">
        <span class="idx">${i + 1}</span>
        <span>
          <div class="node-title">${esc(stepLabel(step))}${selected ? ' <span class="watching">正在看</span>' : ''}</div>
          ${step.why ? `<div class="node-sub">${esc(step.why)}</div>` : ''}
          <span class="node-kicker">${esc(side)}</span>
        </span>
      </button>`;
  }).join('');

  const ending = `<div class="ending ${esc(story.outcomeKind || '')}">${esc(story.outcome)} · ${esc(story.outcomeDetail || '')}</div>`;

  const execution = cur?.execution;
  const recorded = value => value == null ? '未记录' : String(value);
  const flag = value => value == null ? '未记录' : (value ? '是' : '否');
  const executionRow = execution ? `<p class="muted">失败类别：${esc(recorded(execution.failureCategory))} · 原阶段重试：${esc(recorded(execution.stageRetries))} · Coder 返工：${esc(recorded(execution.reworkCount))} · Agent 次数：${esc(recorded(execution.agentAttempts))} · 补证 Agent 额度占用：${esc(recorded(execution.externalProbeReservations))}<br>源码保存：${esc(flag(execution.sourceSaved))} · 导出完成：${esc(flag(execution.exportComplete))} · 清理完成：${esc(flag(execution.cleanupComplete))}<br>外部等待：${esc(flag(execution.externalWaiting))} · 最近阶段：${esc(recorded(execution.latestStage))} · 耗时：${esc(recorded(execution.latestStageSeconds))} 秒</p>` : '';

  const curSection = cur ? `
    <div>
      <div class="section-label">当前拍 · ${esc(cur.statusLabel || '回执')}</div>
      ${cur.reason ? `<div class="callout">${esc(cur.reason)}</div>` : ''}
      <p class="result" style="margin-top:8px">${esc(cur.result || '')}</p>
      ${executionRow}
    </div>` : '';

  const preflight = (story.preflight || []).length
    ? `<div><div class="section-label">预检</div><p class="muted" style="margin:0">${(story.preflight || []).map(s => `<a href="${esc(contextUrl(s.href))}">预检 ${esc(displayId(s))}</a>`).join(' · ')}</p></div>` : '';

  setHTML($('detail-pane'), head + `<div class="detail-body">
    ${prRow}
    <div><div class="section-label">这条任务怎么走过来</div><div class="rail">${rail}</div>${ending}</div>
    ${curSection}${returnsSection(cur)}${preflight}
  </div>`);
  restoreOpenState();
}

// ---------- 轮次：每一轮能点开看原文与当轮 agent ----------

function roleChips(sessions) {
  const counts = {};
  for (const s of sessions) counts[s.role] = (counts[s.role] || 0) + 1;
  return Object.entries(counts)
    .map(([role, n]) => `<span class="r-chip">${esc(role)} ${role === 'Review' ? `最新 1${n > 1 ? ` · 历史 ${n - 1}` : ''}` : n}</span>`).join('');
}

function returnsSection(cur) {
  if (!cur) return '';
  const model = roundsModel(cur);
  if (!model.length) return '';
  const rejected = model.filter(r => r.kind === 'rejected').length;
  const approved = model.filter(r => r.kind === 'approved').length;
  const open = model.filter(r => r.kind === 'open').length;
  const protocol = model.filter(r => r.kind === 'protocol').length;
  const count = model.filter(r => r.n != null).length;
  const tally = [`${rejected} 轮打回`, approved ? `${approved} 轮批准` : '', protocol ? `${protocol} 轮协议失败` : '', open ? `${open} 项进行中或未确认` : '']
    .filter(Boolean).join(' · ');
  return `<div>
    <div class="section-label">轮次 · ${count} 轮（${esc(tally)}）· 点开看证据与会话</div>
    <div class="round-list">${model.map(r => roundBlock(r, cur)).join('')}</div>
    <p class="muted" style="margin:8px 0 0">${model.some(r => r.authoritative) ? '轮次按控制器回执与会话关联记录归类；同一轮的重试不会新增轮次。' : '旧记录缺少控制器轮次，会话按编码顺序作估计归类。'}默认显示最新审查，此前尝试可展开查看。审查结论以控制器回执或 review.json 为准。</p>
  </div>`;
}

function roundBlock(r, cur) {
  const key = r.n == null ? 'round-loose' : `round-${r.n}`;
  const title = r.n == null ? (r.title || '归属未记录') : `第 ${r.n} 轮 · ${r.title}`;
  const source = r.source ? `<span class="r-src">${esc(r.source)}</span>` : '';
  const body = `
    <div class="round-body">
      <div class="round-block">
        <div class="round-label">这一轮的证据 · ${r.evidence.length} 份</div>
        ${r.evidence.length ? r.evidence.map(evidenceBlock).join('')
          : `<p class="muted" style="margin:0">本次采集未发现这一轮的检查或审查结果文件；会话与尝试记录见下方。</p>`}
      </div>
      ${r.sessions.length ? `<div class="round-block">
        <div class="round-label">${r.n == null ? '未关联的会话' : '这一轮的会话'}</div>
        ${roundSessions(r, cur)}
      </div>` : ''}
    </div>`;
  return `<details class="round ${r.tone}" data-open-key="${esc(key)}">
      <summary>
        <span class="r-title">${esc(title)}</span>
        <span class="r-why">${esc(r.why || '')}</span>
        ${source}
        <span class="r-roles">${roleChips(r.sessions)}</span>
      </summary>
      ${body}
    </details>`;
}

function roundSessions(r, cur) {
  const others = r.sessions.filter(s => s.role !== 'Review');
  const reviews = reviewAttempts(r.sessions);
  const latest = reviews.at(-1);
  const history = reviews.slice(0, -1);
  const card = (s, index) => `<div class="review-attempt"><div class="attempt-label">审查尝试 ${index + 1} · ${esc(attemptLabel(s))}${s.stageAttempt > 1 ? ' · 失败重试' : index > 0 ? ' · 重新审查' : ''}</div>${agentCard(s, cur)}</div>`;
  return `<div class="scards">${others.map(s => agentCard(s, cur)).join('')}</div>
    ${latest ? `<div class="round-label review-latest">最新审查</div><div class="scards latest-review">${card(latest, reviews.length - 1)}</div>` : ''}
    ${history.length ? `<details class="review-history" data-open-key="review-history-${r.n ?? 'unassigned'}"><summary>查看此前 ${history.length} 次审查（重试与重审记录）</summary><div class="scards">${history.map(card).join('')}</div></details>` : ''}`;
}

// 证据原文：check-*.log 或 review.json，可再展开看全文。
function evidenceBlock(ev) {
  const approved = ev.approved;
  const verdict = approved === true ? '<span class="tag ok">批准</span>'
    : approved === false ? '<span class="tag bad">拒绝</span>' : '';
  const under = (ev.under || []).length ? `<div class="ev-under">低于 100%：${esc(ev.under.join('、'))}</div>` : '';
  const tailNote = ev.tail ? '<p class="muted" style="margin:4px 0 0">命令失败时控制器只保留输出末尾 4000 个字符，更前面的失败用例名不在原文里。</p>' : '';
  const body = ev.body || '';
  const shown = body.length > 40000 ? `${body.slice(0, 40000)}\n…（原文更长，此处截断显示）` : body;
  const raw = shown ? `<details class="ev-body" data-open-key="ev-${esc(ev.name)}">
      <summary>查看原文 · ${fmt(ev.bytes)} B</summary>
      <pre class="logs">${esc(shown)}</pre>
    </details>` : '';
  return `<article class="ev">
    <div class="ev-head"><b>${esc(ev.name)}</b>${verdict}<span class="ev-bytes">${fmt(ev.bytes)} B</span></div>
    <div class="ev-sum">${esc(ev.summary || '')}</div>
    ${under}${tailNote}${raw}
  </article>`;
}

function agentCard(s, cur) {
  const roleCls = s.role === 'Review' ? 'b-review' : s.role === '编码' ? 'b-running' : s.role === '诊断' ? 'b-diagnose' : s.role === '未识别' ? 'b-blocked' : '';
  const usage = s.tokens ? `入 ${fmt(s.tokens.input_tokens)} / 出 ${fmt(s.tokens.output_tokens)}` : '用量未记';
  const head = s.promptHead || s.title || s.note || '（没有可展示的指令）';
  const note = s.note ? `<span class="note-line">${esc(s.note)}</span>` : '';
  const runtimeBit = showRuntime() ? ` · ${esc(s.runtime)}` : '';
  return `<a class="acard" href="${esc(contextUrl(s.href))}" data-session="${esc(s.id)}" data-title="${esc((cur ? cur.issueLabel : '') + ' ' + s.role + '上下文')}">
    <div class="acard-top">
      <span class="badge ${roleCls}">${esc(s.role)}</span>
      <strong>${esc(displayId(s))}</strong>
      <span class="acard-meta">${esc(s.issue || '')}${runtimeBit}</span>
      <span class="acard-time">${esc(s.start)} – ${esc(s.end)} · ${esc(s.duration)}</span>
    </div>
    <div class="acard-prompt" title="${esc(s.promptHead || '')}">${esc(head)}</div>
    <div class="acard-sub">${s.entries} 条 · ${s.counts.reasoning} 思考 · ${s.counts.tool} 工具 · ${usage}</div>
    ${note}
  </a>`;
}

// ---------- session transcript overlay ----------
export { openSession, closeSession, sessionOpen } from './context.js';
