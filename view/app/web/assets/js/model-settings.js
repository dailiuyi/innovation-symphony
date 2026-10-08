// Administrator token lives only in this page's memory. Elixir owns persistence.
import { esc } from './fmt.js';
let token = '', repositories = [], current = '', saved = null, draft = {}, busy = false;
let message = '', started = false;
const roles = ['coder', 'reviewer'];
const canonical = value => value && typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])])) : value;
const equal = (a, b) => JSON.stringify(canonical(a)) === JSON.stringify(canonical(b));
export function dirty() { return !!saved && !equal(draft, normalizedDefaults(saved)); }
function normalizedDefaults(data) {
  return Object.fromEntries(roles.map(role => {
    const value = data.defaults[role];
    if (typeof value !== 'string') return [role, value];
    const choices = data.roles[role].filter(x => x.selection.preset === value && x.state === 'available');
    // The backend includes the precise effective default, even if unavailable.
    return [role, data.effective_defaults[role] || choices[0]?.selection || null];
  }));
}
async function request(path, body) {
  const response = await fetch('/api/model-settings/' + path, {
    method: body ? 'POST' : 'GET', cache: 'no-store',
    headers: { Authorization: 'Bearer ' + token, ...(body ? {'Content-Type': 'application/json'} : {}) },
    ...(body ? {body: JSON.stringify(body)} : {}),
  });
  const data = await response.json();
  if (!response.ok) throw new Error(response.status === 409 ? '版本冲突或正在保存，请重新读取后修改。原配置保留。' : (data.error || '配置服务不可用'));
  return data;
}
export function mountModelSettings() {
  const root = document.getElementById('model-settings');
  if (!root || root.dataset.mounted) return;
  root.dataset.mounted = 'true';
  paint();
  if (!started) {
    window.addEventListener('beforeunload', event => { if (dirty()) { event.preventDefault(); event.returnValue = ''; } });
    started = true;
  }
}
function paint() {
  const root = document.getElementById('model-settings');
  if (!root) return;
  const focused = root.contains(document.activeElement) ? document.activeElement.id : null;
  root.innerHTML = `<h3>仓库默认模型</h3><p>仅管理新领取任务的默认配置。在途任务继续使用冻结配置。</p>
    ${!token ? '<label>管理员访问令牌 <input id="model-token" type="password" autocomplete="off"></label><button id="model-login" type="button">读取受管仓库</button>' : `
    <label>受管仓库 <select id="model-repository" ${busy ? 'disabled' : ''}><option value="">选择仓库</option>${repositories.map(r => `<option value="${esc(r.id)}" ${r.id === current ? 'selected' : ''}>${esc(r.repository)}</option>`).join('')}</select></label>
    ${saved ? `<p>配置版本 ${saved.revision} · ${dirty() ? '有未保存修改' : '已保存'}</p>${roles.map(renderRole).join('')}
    <button id="model-save" type="button" ${busy || !dirty() || roles.some(r => !draft[r]?.preset || !draft[r]?.model || !draft[r]?.parameters) ? 'disabled' : ''}>保存</button>
    <button id="model-cancel" type="button" ${busy ? 'disabled' : ''}>取消修改</button>` : ''}
    <button id="model-reload" type="button" ${busy ? 'disabled' : ''}>重新读取</button>`}
    <p role="status" aria-live="polite">${esc(message)}</p>`;
  root.querySelector('#model-login')?.addEventListener('click', async () => {
    token = root.querySelector('#model-token').value;
    await perform(async () => { repositories = (await request('repositories')).repositories; message = '请选择仓库'; }, true);
  });
  root.querySelector('#model-repository')?.addEventListener('change', async event => {
    const id = event.target.value;
    if (dirty() && !window.confirm('当前仓库有未保存修改，放弃修改并切换？')) { paint(); return; }
    if (!id) { current = ''; saved = null; paint(); return; }
    await perform(async () => { const data = await request('repositories/' + id); current = id; accept(data); });
  });
  root.querySelector('#model-cancel')?.addEventListener('click', () => { draft = structuredClone(normalizedDefaults(saved)); message = '已取消修改'; paint(); });
  root.querySelector('#model-reload')?.addEventListener('click', async () => {
    if (dirty() && !window.confirm('放弃未保存修改并读取当前配置？')) return;
    await perform(async () => { repositories = (await request('repositories')).repositories; if (current) accept(await request('repositories/' + current)); });
  });
  root.querySelector('#model-save')?.addEventListener('click', async () => {
    await perform(async () => {
      const original = normalizedDefaults(saved);
      const defaults = Object.fromEntries(roles.map(role => [role,
        equal(draft[role], original[role]) ? saved.defaults[role] : draft[role],
      ]));
      accept(await request('repositories/' + current, {revision: saved.revision, workflow_version: saved.workflow_version, defaults}));
      message = '保存成功，只影响新领取任务';
    });
  });
  if (focused) root.querySelector('#' + focused)?.focus();
  for (const role of roles) {
    for (const field of ['preset', 'model', 'effort']) root.querySelector(`#model-${role}-${field}`)?.addEventListener('change', event => change(role, field, event.target.value));
  }
}
function accept(data) { saved = data; draft = structuredClone(normalizedDefaults(data)); message = '已读取当前配置'; }
async function perform(action, login = false) {
  if (busy) return;
  busy = true; paint();
  try { await action(); } catch (error) { message = '操作失败：' + error.message; if (login) token = ''; }
  finally { busy = false; paint(); }
}
function renderRole(role) {
  const available = saved.roles[role].filter(x => x.state === 'available');
  const selection = draft[role] || {};
  const matching = available.filter(x => x.selection.preset === selection.preset && x.selection.model === selection.model);
  const choose = (field, values, selected) => `<label>${field === 'preset' ? '服务预设' : field === 'model' ? '模型' : '思考控制（实际值）'} <select id="model-${role}-${field}" ${busy ? 'disabled' : ''}><option value="">请选择</option>${values.map(([value, text]) => `<option value="${esc(value)}" ${value === selected ? 'selected' : ''}>${esc(text)}</option>`).join('')}</select></label>`;
  const unique = values => [...new Map(values.map(x => [x[0], x])).values()];
  const currentOption = saved.roles[role].find(x => equal(x.selection, selection));
  return `<fieldset><legend>${role === 'coder' ? '编码 coder' : '独立审查 reviewer'}</legend>
    ${choose('preset', unique(available.map(x => [x.selection.preset, `${x.selection.preset} · ${x.provider} · ${x.credential_ref} · v${x.version}`])), selection.preset)}
    ${choose('model', unique(available.filter(x => x.selection.preset === selection.preset).map(x => [x.selection.model, x.selection.model])), selection.model)}
    ${choose('effort', matching.map(x => [JSON.stringify(x.selection.parameters), depthLabel(x)]), selection.parameters ? JSON.stringify(selection.parameters) : '')}
    <p>当前配置：${esc(selection.preset || '未选择')} / ${esc(selection.model || '未选择')} / ${esc(JSON.stringify(selection.parameters || {}))}</p><p>${esc(currentOption?.state || '当前选择不可用')} ${esc(currentOption?.reason || '')}</p>
    <details><summary>目录与验证状态</summary>${saved.roles[role].map(x => `<p>${esc(x.selection.preset)} / ${esc(x.selection.model)} / ${esc(depthLabel(x))}：${esc(x.state)} ${esc(x.reason || '')}</p>`).join('') || '<p>没有登记模型能力</p>'}</details></fieldset>`;
}
export function depthLabel(option) {
  const effort = option.selection.parameters.reasoning_effort;
  if (option.reasoning_mode === 'unknown') return '思考能力未知';
  if (effort === undefined) return '此渠道不支持调节';
  if (effort === 'none') return '关闭思考 (none)';
  if (option.reasoning_mode === 'switch') return `开启思考 (${effort})`;
  return `深度 ${effort}`;
}
function change(role, field, value) {
  const previous = draft[role] || {};
  // Never silently carry a depth across a model/channel change.
  if (field === 'preset') draft[role] = {preset: value};
  else if (field === 'model') draft[role] = {preset: previous.preset, model: value};
  else {
    const option = saved.roles[role].find(x => x.state === 'available' && x.selection.preset === previous.preset && x.selection.model === previous.model && JSON.stringify(x.selection.parameters) === value);
    draft[role] = option ? structuredClone(option.selection) : {preset: previous.preset, model: previous.model};
  }
  message = field === 'effort' ? '有未保存修改' : '模型或渠道已变化，请重新选择支持的思考控制';
  paint();
}
