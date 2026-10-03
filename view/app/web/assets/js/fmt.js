// 共享的格式化与「这一拍」语意 helper：看板卡片、详情面板、Agent 上下文页都用它。
// 只保留 demo 原型在用的部分；被砍功能（统计/日志/消耗图/状态变迁）的 helper 已移除。

export const $ = id => document.getElementById(id);

export const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));

export const fmt = n => Number(n || 0).toLocaleString('zh-CN');

// ISO 时间 → 停留时长的中文短语
function stallText(iso) {
  const ms = Date.now() - Date.parse(iso);
  if (!isFinite(ms) || ms < 0) return '';
  const h = ms / 3.6e6;
  if (h >= 48) return Math.round(h / 24) + ' 天';
  if (h >= 1) return Math.round(h) + ' 小时';
  const m = Math.round(ms / 6e4);
  return m >= 1 ? m + ' 分钟' : '1 分钟';
}

const STALL_STATUSES = ['awaiting_human', 'awaiting_review', 'pr_ready'];

// 等人任务停留超过阈值（小时）时返回时长短语；阈值 0 表示立即告警。
export function stallBadgeInfo(task, stallHours) {
  if (!task || !STALL_STATUSES.includes(task.status) || !task.statusSince) return null;
  const text = stallText(task.statusSince);
  const hours = (Date.now() - Date.parse(task.statusSince)) / 3.6e6;
  if (!text || hours < (stallHours ?? 24)) return null;
  return text;
}

export function setHTML(el, html) {
  if (!el || el._sig === html) return false;
  el._sig = html;
  el.innerHTML = html;
  return true;
}
export function setText(el, text) {
  const value = text == null ? '' : String(text);
  if (!el || el._sig === value) return false;
  el._sig = value;
  el.textContent = value;
  return true;
}

// Payload hrefs are bare context-<short>.html names; resolve under /prototypes/.
// Idempotent: already-absolute or already-prefixed hrefs pass through untouched.
export const contextUrl = href => {
  const h = String(href || '');
  if (!h || h === '#') return '#';
  if (/^https?:\/\//.test(h) || h.startsWith('/prototypes/')) return h;
  return '/prototypes/' + h.replace(/^\/+/, '');
};

function prLabel(pr) {
  const n = pr.number ? ` #${pr.number}` : '';
  if (pr.state === 'merged') return `查看已合并的 PR${n}`;
  if (pr.state === 'closed' || pr.state === 'changes') return `查看打回的 PR${n}`;
  if (pr.draft) return `处理草稿 PR${n}`;
  return `处理 PR${n}`;
}
export function prAnchor(pr) {
  if (!pr || !pr.url) return '';
  return `<a class="pr-link" href="${esc(pr.url)}" target="_blank" rel="noopener">${esc(prLabel(pr))}</a>`;
}

function returnTone(kind) {
  return kind === 'review' ? 'review' : 'bad';
}
export function stepLabel(step) {
  return step.n ? `第 ${step.n} 轮 · ${step.title}` : step.title;
}
export function beatSteps(beat, story, isLast) {
  const steps = (beat.returns || []).map(item => ({ tone: returnTone(item.kind), title: item.title, why: item.why || '', n: item.n || 0 }));
  const pr = beat.pr && beat.pr.state;
  if (pr === 'merged' || beat.status === 'done' || beat.status === 'merged') steps.push({ tone: 'good', title: pr === 'merged' ? '已合并' : '已交付', why: '' });
  else if (pr === 'open' || (isLast && story.outcomeKind === 'human' && pr !== 'closed' && pr !== 'changes')) steps.push({ tone: 'good', title: '等待处理 PR', why: '打开链接处理这次 PR' });
  else if (['coding', 'checking', 'review', 'reviewing', 'recovering'].includes(beat.status)) steps.push({ tone: 'run', title: beat.statusLabel || '进行中', why: '' });
  else if (!steps.length) steps.push({ tone: beatTone(beat, story, isLast), title: beatTitle(beat, story, isLast), why: beatSub(beat) });
  return steps;
}
function beatTitle(beat, story, isLast) {
  const pr = beat.pr && beat.pr.state;
  if (pr === 'merged') return '已合并';
  if (pr === 'closed' || pr === 'changes') return '人工打回';
  if (isLast && pr === 'open') return '等待处理 PR';
  const reason = beat.reason || '';
  if (reason.includes('response_timeout')) return '编码超时';
  if (reason.includes('mvp_candidate_or_baseline_changed')) return '检查后作废';
  if (reason.includes('mvp_review_not_approved')) return 'Review 拒绝';
  if (reason.includes('mvp_check_failed')) return '检查未通过';
  if (isLast && story.outcomeKind === 'human') return 'Review 批准';
  if (isLast && story.outcomeKind === 'done') return story.outcome;
  return beat.statusLabel || '这一拍';
}
function beatSub(beat) {
  const pr = beat.pr && beat.pr.state;
  if (pr === 'merged') return '人工已合并';
  if (pr === 'closed' || pr === 'changes') return '人工没有通过，这次要重做';
  if (pr === 'open') return '打开 PR 做人工处理';
  const reason = beat.reason || '';
  if (reason.includes('response_timeout')) return '这一拍没有留下编码或 Review 会话';
  if (reason.includes('mvp_candidate_or_baseline_changed')) return '检查已经通过，之后候选或基线变了';
  if (reason.includes('mvp_review_not_approved')) return beat.gap || 'Review 没有批准';
  if (reason.includes('mvp_check_failed')) return '自动检查没有通过';
  if (beat.gap) return beat.gap;
  if (beat.status === 'awaiting_human') return 'Review 已批准，停在人工这一步';
  return beat.statusLabel || '';
}
function beatTone(beat, story, isLast) {
  const pr = beat.pr && beat.pr.state;
  if (pr === 'merged') return 'good';
  if (pr === 'closed' || pr === 'changes') return 'bad';
  const reason = beat.reason || '';
  if (reason.includes('mvp_review_not_approved')) return 'review';
  if (isLast && (story.outcomeKind === 'human' || story.outcomeKind === 'done')) return 'good';
  if (isLast && story.outcomeKind === 'running') return 'run';
  if (beat.status === 'awaiting_human' || beat.status === 'awaiting_review' || beat.status === 'pr_ready') return 'good';
  if (beat.status === 'blocked') return 'bad';
  return 'run';
}

export function tokenBlock(list) {
  const ti = list.reduce((n, s) => n + (s.tokens && s.tokens.input_tokens || 0), 0);
  const tc = list.reduce((n, s) => n + (s.tokens && s.tokens.cached_input_tokens || 0), 0);
  const to = list.reduce((n, s) => n + (s.tokens && s.tokens.output_tokens || 0), 0);
  return `输入 ${fmt(ti)} · 缓存 ${fmt(tc)} · 输出 ${fmt(to)}`;
}
