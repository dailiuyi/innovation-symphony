// Synthetic DOM/API regression; browser acceptance runs separately.
import { test } from 'node:test';
import { mountModelSettings, dirty, depthLabel } from '../app/web/assets/js/model-settings.js';
test('model settings drafts, cancel, failures, conflicts and persistence', async () => {
const assert = (condition, message) => { if (!condition) throw new Error(message); };
const copy = value => JSON.parse(JSON.stringify(value));
if (!globalThis.structuredClone) globalThis.structuredClone = copy;
let root, focused = null;
class Control {
  constructor(id, value = '') { this.id = id; this.value = value; this.handlers = {}; }
  addEventListener(type, handler) { this.handlers[type] = handler; }
  focus() { focused = this; }
  async fire(type, value = this.value) { this.value = value; await this.handlers[type]?.({target: this}); }
}
root = {
  dataset: {}, controls: {}, html: '',
  set innerHTML(html) {
    this.html = html; this.controls = {};
    for (const match of html.matchAll(/<(input|button|select)\b[^>]*id="([^"]+)"[^>]*>/g)) this.controls[match[2]] = new Control(match[2]);
  },
  get innerHTML() { return this.html; },
  contains(element) { return element && this.controls[element.id] === element; },
  querySelector(selector) { return this.controls[selector.slice(1)] || null; },
};
globalThis.document = {getElementById: id => id === 'model-settings' ? root : null, get activeElement() { return focused; }};
let confirm = false, confirmations = 0;
if (!globalThis.window) globalThis.window = {};
const storage = new Map();
Object.assign(globalThis.window, {localStorage: {getItem: key => storage.get(key), setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key)}, addEventListener() {}, confirm() { confirmations++; return confirm; }});
const selection = (preset, model, effort) => ({preset, model, parameters: effort === undefined ? {} : {reasoning_effort: effort}});
const choice = (preset, model, effort, mode = 'effort', state = 'available') => ({selection: selection(preset, model, effort), provider: 'deepseek', credential_ref: 'env:FIXTURE', version: 1, reasoning_mode: mode, state});
const options = [choice('p', 'a', 'high'), choice('p', 'a', 'max'), choice('p', 'b', 'low'), choice('p', 'switch', 'none', 'switch'), choice('p', 'switch', 'high', 'switch'), choice('p', 'fixed', undefined, 'fixed'), choice('p', 'unknown', undefined, 'unknown', 'pending_validation')];
const repo = revision => ({revision, workflow_version: 'fixture', defaults: {coder: 'p', reviewer: 'p'}, effective_defaults: {coder: selection('p', 'a', 'high'), reviewer: selection('p', 'a', 'max')}, roles: {coder: options, reviewer: options}});
let state = {a: repo(0), b: repo(0)}, calls = [], failure = null;
globalThis.fetch = async (url, init) => {
  calls.push({url, init});
  if (failure) return {ok: false, status: failure, json: async () => ({error: 'safe_fixture_failure'})};
  if (url.endsWith('/repositories')) return {ok: true, json: async () => ({repositories: [{id:'a', repository:'owner/a'}, {id:'b', repository:'owner/b'}]})};
  const id = url.split('/').at(-1);
  if (init.body) { const body = JSON.parse(init.body); state[id] = {...state[id], defaults: body.defaults, revision: body.revision + 1}; }
  return {ok: true, json: async () => copy(state[id])};
};
const control = id => { const value = root.controls['model-' + id]; assert(value, 'Missing control: ' + id); return value; };
mountModelSettings();
control('token').value = 'synthetic_admin';
await control('login').fire('click');
assert(!dirty(), 'Login must not create a draft');
await control('repository').fire('change', 'a');
assert(!dirty(), 'Legacy defaults must normalize to exact effective role values');
const beforeCalls = calls.length;
control('coder-model').focus();
await control('coder-model').fire('change', 'b');
assert(dirty() && root.html.includes('请重新选择'), 'Model change clears the incompatible old depth');
assert(focused === control('coder-model'), 'Keyboard focus survives repaint');
assert(calls.length === beforeCalls, 'Draft changes do not save or trigger tasks');
await control('coder-effort').fire('change', JSON.stringify({reasoning_effort:'low'}));
assert(root.html.includes('有未保存修改'), 'Dirty feedback missing');
await control('repository').fire('change', 'b');
assert(confirmations === 1 && dirty(), 'Declining switch preserves the draft');
failure = 409;
await control('save').fire('click');
assert(dirty() && root.html.includes('版本冲突'), 'Conflict must preserve the draft');
assert(state.a.revision === 0, 'Failure changed persisted defaults');
failure = 503;
await control('save').fire('click');
assert(dirty() && root.html.includes('操作失败'), 'Transport failure must preserve the draft');
failure = null;
await control('save').fire('click');
assert(!dirty() && root.html.includes('保存成功'), 'Success feedback or clean state missing');
assert(state.a.defaults.coder.model === 'b' && state.a.defaults.reviewer === 'p', 'An untouched legacy role must retain its original preset default semantics');
assert(state.b.revision === 0, 'Saving one repository changed another');
const savedCall = calls.filter(x => x.init.body).at(-1);
const savedBody = JSON.parse(savedCall.init.body);
assert(savedBody.revision === 0 && savedBody.workflow_version === 'fixture', 'CAS/workflow identity omitted');
assert(savedCall.init.headers.Authorization === 'Bearer synthetic_admin', 'Authentication omitted');
await control('coder-model').fire('change', 'fixed');
await control('coder-effort').fire('change', '{}');
assert(dirty() && root.html.includes('此渠道不支持调节'), 'Fixed capability display missing');
await control('cancel').fire('click');
assert(!dirty() && root.html.includes('已取消修改'), 'Cancel must restore saved values');
await control('coder-model').fire('change', 'switch');
confirm = true;
await control('repository').fire('change', 'b');
assert(!dirty(), 'Accepted repository switch must discard unsaved changes');
await control('repository').fire('change', 'a');
assert(root.html.includes('配置版本 1'), 'Re-read did not show persisted configuration');
for (const [id, updates] of [['a', [['coder', 'switch', {reasoning_effort:'none'}], ['reviewer', 'fixed', {}]]], ['b', [['coder', 'b', {reasoning_effort:'low'}], ['reviewer', 'switch', {reasoning_effort:'high'}]]]]) {
  await control('repository').fire('change', id);
  for (const [role, model, parameters] of updates) {
    const previous = copy(state);
    await control(role + '-model').fire('change', model);
    await control(role + '-effort').fire('change', JSON.stringify(parameters));
    await control('save').fire('click');
    assert(!dirty(), 'Save left a dirty role: ' + id + '/' + role);
    assert(state[id].revision === previous[id].revision + 1, 'Role save revision mismatch');
    assert(JSON.stringify(state[id].defaults[role]) === JSON.stringify(selection('p', model, parameters.reasoning_effort)), 'Saved role mismatch');
    const other = role === 'coder' ? 'reviewer' : 'coder';
    assert(JSON.stringify(state[id].defaults[other]) === JSON.stringify(previous[id].defaults[other]), 'Other role changed');
    const otherRepo = id === 'a' ? 'b' : 'a';
    assert(JSON.stringify(state[otherRepo]) === JSON.stringify(previous[otherRepo]), 'Other repository changed');
  }
}
for (const id of ['a', 'b']) {
  await control('repository').fire('change', id);
  assert(!dirty() && root.html.includes('配置版本 ' + state[id].revision), 'All persisted roles must reread cleanly');
}
assert(depthLabel(options[3]) === '关闭思考 (none)', 'Off control mislabeled');
assert(depthLabel(options[4]) === '开启思考 (high)', 'Switch control mislabeled');
assert(depthLabel(options[6]) === '思考能力未知', 'Unknown capability mislabeled');
assert(depthLabel(choice('legacy', 'gpt-legacy', null, 'fixed')) === '未指定思考参数（沿用预设）', 'Legacy null must not be labeled as depth or disabled thinking');
assert(!root.html.includes('synthetic_admin'), 'Token leaked into rendered content');
assert(storage.get('symphony.model-settings.admin-token') === 'synthetic_admin', 'Successful login must be remembered');
await control('logout').fire('click');
assert(!storage.has('symphony.model-settings.admin-token') && control('token'), 'Logout must clear saved login');
console.log('Model settings interaction regression passed (synthetic DOM/API).');

});
