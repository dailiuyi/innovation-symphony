// Agent 上下文页 + 设置页。

import { $, esc, setHTML, setText, fmt, contextUrl } from './fmt.js';
import { state, visibleSessions, showRuntime, displayId } from './data.js';

const ROLE_ORDER = ['编码', 'Review', '诊断', '预检', '未识别'];
let agentRoleFilter = localStorage.getItem('agent-role') || 'all';
let agentQuery = '';
let agentSort = localStorage.getItem('agent-sort') || 'recent';
const roleBadge = role => role === 'Review' ? 'b-review' : role === '编码' ? 'b-running' : role === '诊断' ? 'b-diagnose' : role === '未识别' ? 'b-blocked' : '';

// ---------- Agent 上下文页 ----------
// demo 原型只做一件事：让研发一眼看到每个 agent 的上下文。
// 每个 agent = 一次 Codex 会话，卡片给出角色、指令开头（symphony 下发的
// prompt 模板，更新 symphony 时先看这里）、Issue、时长与完整上下文入口。
export function renderAgentsPage() {
  const sessions = visibleSessions();
  const roles = [...new Set(sessions.map(s => s.role || '未识别'))];
  const tools = [{ id: 'all', label: '全部', count: sessions.length }]
    .concat(ROLE_ORDER.filter(role => roles.includes(role)).map(role => ({
      id: role, label: role, count: sessions.filter(s => (s.role || '未识别') === role).length,
    })));
  setHTML($('agent-tools'), tools.map(item =>
    `<button class="chip ${item.id === agentRoleFilter ? 'active' : ''}" type="button" aria-pressed="${item.id === agentRoleFilter}" data-srole="${esc(item.id)}">${esc(item.label)}<small>${item.count}</small></button>`
  ).join(''));

  const query = agentQuery.trim().toLocaleLowerCase();
  const pool = sessions.filter(s => (agentRoleFilter === 'all' || (s.role || '未识别') === agentRoleFilter)
    && (!query || [s.id, s.role, s.issue, s.repo, s.runtime, s.model, s.promptHead, s.prompt, s.title, s.lastOutput, s.note].join(' ').toLocaleLowerCase().includes(query)));
  pool.sort((a, b) => (agentSort === 'oldest' ? 1 : -1) * (String(a.firstTs || '').localeCompare(String(b.firstTs || '')) || sessions.indexOf(a) - sessions.indexOf(b)));
  setHTML($('agent-groups'), pool.map(agentCard).join('') || `<div class="empty-state"><span class="empty-symbol">◎</span><h3>${sessions.length ? '没有匹配的会话' : '还没有采集到 Agent 会话'}</h3><p>${sessions.length ? '尝试其他关键词，或清除筛选查看全部会话。' : '采集到运行时的会话后，会在这里展示。'}</p>${sessions.length ? '<button class="btn" type="button" data-agent-reset>清除筛选</button>' : ''}</div>`);
  setText($('agent-note'), `显示 ${pool.length} / ${sessions.length} 个会话 · 每个 Agent 对应一次会话，列表搜索已采集的摘要；全文请在会话记录中搜索。`);
  $('agent-sort').value = agentSort;
}

function agentCard(s) {
  const roleCls = roleBadge(s.role);
  const usage = s.tokens ? `输入 ${fmt(s.tokens.input_tokens)} · 输出 ${fmt(s.tokens.output_tokens)}` : 'Token 用量未记录';
  const head = s.promptHead || s.title || s.note || '（没有可展示的指令）';
  const output = s.lastOutput || s.note || '尚未采集到可见的 Agent 输出';
  const date = s.firstTs ? new Date(s.firstTs).toLocaleString('zh-CN', {month:'2-digit', day:'2-digit', hour:'2-digit', minute:'2-digit', hour12:false, timeZone:'Asia/Shanghai'}) : `${s.start || '—'} – ${s.end || '—'}`;
  const verdict = s.verdict && typeof s.verdict.approved === 'boolean' ? `<span class="tag ${s.verdict.approved ? 'ok' : 'bad'}">Review ${s.verdict.approved ? '批准' : '未通过'}</span>` : '';
  return `<a class="acard" href="${esc(contextUrl(s.href))}" data-session="${esc(s.id)}" data-title="${esc((s.issue ? s.issue + ' ' : '') + s.role + '上下文')}">
    <div class="acard-top">
      <span class="badge ${roleCls}">${esc(s.role)}</span>
      <strong>${esc(s.issue || '预检 / 未关联任务')}</strong>${verdict}
      <span class="acard-time">${esc(date)}</span>
    </div>
    <div class="agent-origin">${esc(s.repo || '未关联仓库')}${showRuntime() ? ` · ${esc(s.runtime)}` : ''}<span>${esc(displayId(s))}</span></div>
    <div class="agent-excerpt"><span class="excerpt-label">下发指令</span><div class="acard-prompt">${esc(head)}</div></div>
    <div class="agent-excerpt output"><span class="excerpt-label">最近输出</span><p>${esc(output)}</p></div>
    <div class="acard-sub"><span>${esc(s.model || '模型未记录')} · ${esc(s.duration || '—')}</span><span>${fmt((s.counts || {}).tool)} 次工具调用</span></div>
    <div class="agent-card-foot"><span>${usage}</span><span class="open-context">查看上下文 ↗</span></div>
  </a>`;
}

export function setAgentRoleFilter(role) {
  agentRoleFilter = role;
  localStorage.setItem('agent-role', role);
  renderAgentsPage();
}

export function setAgentQuery(query) { agentQuery = query; renderAgentsPage(); }
export function setAgentSort(sort) { agentSort = sort; localStorage.setItem('agent-sort', sort); renderAgentsPage(); }
export function resetAgentFilters() { agentQuery = ''; $('agent-search').value = ''; setAgentRoleFilter('all'); }

// ---------- 设置页（demo：只读展示配置与接入情况） ----------
export function renderSettingsPage() {
  const boot = state.boot || {};
  const repos = boot.repos || [];
  const pending = boot.pending || [];
  setHTML($('settings-body'), `
    <div class="panel">
      <h3>接入配置</h3>
      <p>配置文件：<code>${esc(boot.configPath || 'app/config.toml')}</code>${boot.configExists ? '' : ' <span class="muted">（还没有创建，全部用默认值）</span>'}</p>
      <p>标题 <code>${esc(boot.title || '')}</code> · 采集间隔 <code>${esc(String(boot.interval || ''))}s</code> · 端口 <code>${esc(String(boot.port || ''))}</code></p>
      ${repos.length ? `<table>
        <tr><th>仓库</th><th>显示名</th><th>运行时 glob</th><th>启用</th></tr>
        ${repos.map(r => `<tr><td>${esc(r.name)}</td><td>${esc(r.alias || '—')}</td><td><code>${esc(r.glob || '默认')}</code></td><td>${r.enabled ? '是' : '否'}</td></tr>`).join('')}
      </table>` : '<p class="muted">还没有 [[repos]] 条目：看板显示所有从回执里发现的仓库。</p>'}
      <p class="muted" style="margin-top:8px">demo 原型只读；改配置请直接编辑 config.toml 后重启服务。</p>
    </div>
    <div class="panel">
      <h3>待接入</h3>
      ${pending.length ? pending.map(item => `<p><code>${esc(item.repo)}</code> · 运行时 ${esc(item.runtime)}</p>`).join('') : '<p class="muted">没有待接入的仓库。</p>'}
    </div>
    <div class="panel">
      <h3>原型范围</h3>
      <p>任务进度、轮次证据、Agent 指令与会话记录来自运行时产物。未记录的字段会标明缺失。</p>
      <p>看板只读。任务启动、重试、模型配置与 Prompt 修改由 Symphony 负责。</p>
      <p>数据接口是本原型内部约定。未来合并时再根据 Symphony 的稳定接口适配，当前不承诺产品级接口。</p>
    </div>`);
}
