// Native browser acceptance on synthetic management data, never account evidence.
const assert = require('node:assert/strict');
const selection = (preset, model, effort) => ({preset, model, parameters:{reasoning_effort:effort}});
const choices = ['p', 'q'].flatMap(preset => ['alpha', 'beta'].flatMap(model => ['low', 'high'].map(effort => ({
  selection:selection(preset, model, effort), provider:'openai', credential_ref:'env:FIXTURE',
  version:1, reasoning_mode:'effort', state:'available',
}))));
choices.push({selection:selection('legacy', 'gpt-legacy', null), default_value:'legacy',
  provider:'openai', credential_ref:'env:FIXTURE', version:1, reasoning_mode:'fixed', state:'available'});
const token = 'synthetic_browser_admin';
function settingsFixture(json) {
  const state = Object.fromEntries(['a', 'b'].map(id => [id, {revision:0, workflow_version:'fixture-' + id,
    defaults:{coder:id === 'a' ? 'legacy' : selection('p', 'alpha', 'high'), reviewer:id === 'a' ? 'legacy' : selection('p', 'alpha', 'high')},
    effective_defaults:{coder:id === 'a' ? selection('legacy', 'gpt-legacy', null) : selection('p', 'alpha', 'high'), reviewer:id === 'a' ? selection('legacy', 'gpt-legacy', null) : selection('p', 'alpha', 'high')},
    roles:{coder:choices, reviewer:choices}}]));
  return async (req, res, pathname) => {
    if (req.headers.authorization !== 'Bearer ' + token) return json(res, {error:'unauthorized'}, 401);
    if (pathname === '/api/model-settings/repositories' && req.method === 'GET')
      return json(res, {repositories:['a', 'b'].map(id => ({id, repository:'owner/' + id}))});
    const id = pathname.match(/^\/api\/model-settings\/repositories\/([ab])$/)?.[1];
    if (!id) return json(res, {error:'missing_repository'}, 404);
    if (req.method === 'POST') {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      const body = JSON.parse(Buffer.concat(chunks));
      if (body.revision !== state[id].revision || body.workflow_version !== state[id].workflow_version)
        return json(res, {error:'conflict'}, 409);
      assert.deepEqual(Object.keys(body).sort(), ['defaults', 'revision', 'workflow_version']);
      const effective = {};
      for (const role of ['coder', 'reviewer']) {
        const value = body.defaults[role];
        const option = choices.find(x => JSON.stringify(x.default_value ?? x.selection) === JSON.stringify(value));
        assert(option, 'only exact validated combinations or legacy strings may be saved');
        effective[role] = option.selection;
      }
      state[id] = {...state[id], defaults:body.defaults, effective_defaults:effective, revision:body.revision + 1};
    } else assert.equal(req.method, 'GET');
    return json(res, state[id]);
  };
}
async function settingsReading(page) {
  await page.setViewportSize({width:390, height:844});
  await page.goto(page.url().split('#')[0] + '#/settings');
  const field = id => page.locator('#model-' + id);
  const status = async text => page.waitForFunction(text => document.querySelector('#model-settings [role=status]')?.textContent.includes(text), text);
  const focus = async id => assert.equal(await field(id).evaluate(el => el === document.activeElement), true, 'focus: ' + id);
  const clean = async () => assert.equal(await field('save').isDisabled(), true);
  const choose = async (id, value, expected = value) => {
    const options = await field(id).locator('option').evaluateAll(els => els.map(el => el.value));
    const index = options.indexOf(value);
    assert(index > 0, 'available native option: ' + id + '/' + value);
    await field(id).focus();
    // End handles b directly so no asynchronous a request interrupts navigation.
    if (id === 'repository' && index === options.length - 1) await page.keyboard.press('End');
    else {
      await page.keyboard.press('Home');
      for (let n = 0; n < index; n++) await page.keyboard.press('ArrowDown');
    }
    await page.waitForFunction(({id, value}) => {
      const el = document.getElementById('model-' + id);
      return el?.value === value && !el.disabled;
    }, {id, value:expected});
    await focus(id);
  };
  const enter = async id => { await field(id).focus(); await page.keyboard.press('Enter'); };
  const read = async id => { await choose('repository', id); await status('已读取'); await clean(); };
  const parameter = effort => JSON.stringify({reasoning_effort:effort});
  const checkRole = async (role, preset, model, effort) => {
    assert.equal(await field(role + '-preset').inputValue(), preset);
    assert.equal(await field(role + '-model').inputValue(), model);
    assert.equal(await field(role + '-effort').inputValue(), parameter(effort));
  };
  await field('token').waitFor({state:'visible'});
  await field('token').focus(); await page.keyboard.type('invalid_admin'); await page.keyboard.press('Tab');
  await focus('login'); await page.keyboard.press('Enter'); await status('unauthorized');
  await focus('login');
  assert.equal(await field('token').inputValue(), '', 'failed login clears the token');
  await field('token').focus(); await page.keyboard.type(token); await page.keyboard.press('Tab');
  await focus('login'); await page.keyboard.press('Enter'); await status('请选择仓库'); await focus('repository');
  await read('a');
  for (const role of ['coder', 'reviewer']) await checkRole(role, 'legacy', 'gpt-legacy', null);
  assert.match(await page.locator('#model-settings').innerText(), /未指定思考参数/);
  assert.doesNotMatch(await page.locator('#model-settings').innerText(), /当前选择不可用|深度 null/);
  assert.equal(await field('coder-effort').locator('option').count(), 2, 'no invented explicit depth or empty parameter choice');
  await choose('coder-preset', 'q');
  assert.equal(await field('save').isDisabled(), true);
  await page.keyboard.press('Tab'); await focus('coder-model');
  await choose('coder-model', 'beta');
  assert.equal(await field('coder-effort').inputValue(), '');
  await page.keyboard.press('Tab'); await focus('coder-effort');
  await choose('coder-effort', parameter('low')); await status('有未保存');
  assert.equal(await field('save').isEnabled(), true);
  page.once('dialog', async dialog => { assert.match(dialog.message(), /未保存/); await dialog.dismiss(); });
  await choose('repository', 'b', 'a');
  await status('有未保存'); await checkRole('coder', 'q', 'beta', 'low');
  const endpoint = page.url().split('#')[0] + 'api/model-settings/repositories/a';
  const headers = {Authorization:'Bearer ' + token};
  const initial = await (await page.request.get(endpoint, {headers})).json();
  // A separate writer advances the real fixture revision; the stale page gets 409.
  assert.equal((await page.request.post(endpoint, {headers, data:{revision:initial.revision,
    workflow_version:initial.workflow_version, defaults:initial.defaults}})).status(), 200);
  await enter('save'); await status('版本冲突');
  await checkRole('coder', 'q', 'beta', 'low'); assert.equal(await field('save').isEnabled(), true);
  assert.deepEqual((await (await page.request.get(endpoint, {headers})).json()).defaults, initial.defaults);
  await page.route('**/api/model-settings/repositories/a', async route => {
    if (route.request().method() === 'POST') return route.fulfill({status:503, json:{error:'fixture_unavailable'}});
    await route.continue();
  });
  await enter('save'); await status('fixture_unavailable'); await checkRole('coder', 'q', 'beta', 'low');
  await page.unroute('**/api/model-settings/repositories/a');
  await enter('cancel'); await status('已取消'); await checkRole('coder', 'legacy', 'gpt-legacy', null); await clean();
  await enter('reload'); await status('已读取');
  assert.match(await page.locator('#model-settings').innerText(), /配置版本 1/);
  for (const [id, targets] of [['a', [['coder', 'q', 'beta', 'low'], ['reviewer', 'q', 'alpha', 'low']]],
                               ['b', [['coder', 'p', 'beta', 'high'], ['reviewer', 'q', 'beta', 'low']]]]) {
    await read(id);
    for (const [role, preset, model, effort] of targets) {
      await choose(role + '-preset', preset); await choose(role + '-model', model);
      await choose(role + '-effort', parameter(effort));
      if (id === 'a' && role === 'coder') {
        await page.route('**/api/model-settings/repositories/a', async route => {
          if (route.request().method() === 'POST') return route.fulfill({status:503, json:{error:'retry_unavailable'}});
          await route.continue();
        });
        await enter('save'); await status('retry_unavailable');
        await checkRole(role, preset, model, effort); await focus('save');
        assert.deepEqual((await (await page.request.get(endpoint, {headers})).json()).defaults, initial.defaults);
        await page.unroute('**/api/model-settings/repositories/a');
      }
      await enter('save'); await status('保存成功'); await clean(); await focus('repository');
      await checkRole(role, preset, model, effort);
    }
  }
  await read('a'); await checkRole('coder', 'q', 'beta', 'low'); await checkRole('reviewer', 'q', 'alpha', 'low');
  assert.match(await page.locator('#model-settings').innerText(), /配置版本 3/);
  await choose('coder-model', 'alpha');
  page.once('dialog', async dialog => { assert.match(dialog.message(), /未保存/); await dialog.accept(); });
  await read('b'); await checkRole('coder', 'p', 'beta', 'high'); await checkRole('reviewer', 'q', 'beta', 'low');
  assert.match(await page.locator('#model-settings').innerText(), /配置版本 2/);
  const otherRepo = await (await page.request.get(endpoint.replace(/a$/, 'b'), {headers})).json();
  await read('a');
  for (const role of ['coder', 'reviewer']) {
    const before = await (await page.request.get(endpoint, {headers})).json();
    await choose(role + '-preset', 'legacy'); await choose(role + '-model', 'gpt-legacy');
    await choose(role + '-effort', parameter(null));
    await page.route('**/api/model-settings/repositories/a', async route => {
      if (route.request().method() === 'POST') return route.fulfill({status:503, json:{error:'legacy_retry_unavailable'}});
      await route.continue();
    });
    await enter('save'); await status('legacy_retry_unavailable'); await checkRole(role, 'legacy', 'gpt-legacy', null);
    assert.deepEqual((await (await page.request.get(endpoint, {headers})).json()), before, 'failed legacy save preserves values');
    await page.unroute('**/api/model-settings/repositories/a');
    await enter('save'); await status('保存成功'); await clean();
    const after = await (await page.request.get(endpoint, {headers})).json();
    assert.equal(after.defaults[role], 'legacy', 'legacy null must save using original preset semantics');
    assert.deepEqual(after.effective_defaults[role], selection('legacy', 'gpt-legacy', null));
    const other = role === 'coder' ? 'reviewer' : 'coder';
    assert.deepEqual(after.defaults[other], before.defaults[other]);
    assert.deepEqual((await (await page.request.get(endpoint.replace(/a$/, 'b'), {headers})).json()), otherRepo);
  }
  // Refresh restores the remembered login and repository automatically.
  await page.reload(); await status('已读取当前配置');
  await checkRole('coder', 'legacy', 'gpt-legacy', null); await checkRole('reviewer', 'legacy', 'gpt-legacy', null);
  assert.doesNotMatch(await page.locator('#model-settings').innerText(), /当前选择不可用|深度 null/);
  await read('b'); await checkRole('coder', 'p', 'beta', 'high'); await checkRole('reviewer', 'q', 'beta', 'low');
  assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'narrow settings overflow');
  for (const id of ['repository', 'coder-preset', 'coder-model', 'coder-effort', 'reviewer-preset', 'reviewer-model', 'reviewer-effort', 'cancel', 'reload']) {
    await field(id).scrollIntoViewIfNeeded();
    assert(await field(id).isVisible() && await field(id).isEnabled(), 'narrow operable: ' + id);
    const box = await field(id).boundingBox();
    assert(box.width > 0 && box.x >= 0 && box.x + box.width <= 390, 'narrow bounds: ' + id);
    await field(id).focus(); await focus(id);
  }
  assert.equal(await page.evaluate(value => [localStorage, sessionStorage].some(storage =>
    Object.values(storage).some(entry => entry.includes(value))), token), true, 'successful login should persist in this browser');
  await field('logout').click(); await field('token').waitFor({state:'visible'});
  assert.equal(await page.evaluate(() => localStorage.getItem('symphony.model-settings.admin-token')), null);
}
module.exports = {settingsFixture, settingsReading};
