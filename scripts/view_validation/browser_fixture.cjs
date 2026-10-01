// Windows-only synthetic UI preparation. No existing browser/profile/service is used.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const {readOrdinary, checkOutput, installRefreshObserver, refreshCompletion, verifyInputs, verifyUnchanged, finish} = require('./browser_inputs.cjs');
const args = process.argv.slice(2);
const option = name => {
  const index = args.indexOf(name);
  assert(index >= 0 && args[index + 1], `missing ${name}`);
  return args[index + 1];
};
const sha = data => crypto.createHash('sha256').update(data).digest('hex');
const verifyOnly = args.includes('--verify-only');

(async () => {
  const rootInput = option('--validation-root'), outInput = option('--output');
  await checkOutput(rootInput, outInput);
  const root = path.resolve(rootInput), out = path.resolve(outInput);
  const chrome = verifyOnly ? null : path.resolve(option('--chrome'));
  const pwRoot = verifyOnly ? null : path.resolve(option('--playwright-root'));
  const validationBytes = await readOrdinary(path.join(root, 'validation-result.json'));
  const validation = JSON.parse(validationBytes);
  assert(validation.passed && validation.formal_acceptance === false && validation.preparation_pseudo_candidate === true,
    'UI fixture requires a successful, marked synthetic validation preparation');
  const verified = await verifyInputs(root, validation);
  const scriptBytes = await readOrdinary(__filename);
  const bindingBytes = await readOrdinary(path.join(__dirname, 'browser_inputs.cjs'));
  assert.equal(sha(scriptBytes), validation.validator_files['browser_fixture.cjs'], 'browser script differs from validation binding');
  assert.equal(sha(bindingBytes), validation.validator_files['browser_inputs.cjs'], 'browser binding helper differs from validation binding');
  const verifyFinal = async () => {
    await verifyUnchanged(root, validationBytes, validation);
    assert.equal(sha(await readOrdinary(__filename)), sha(scriptBytes), 'browser script changed');
    assert.equal(sha(await readOrdinary(path.join(__dirname, 'browser_inputs.cjs'))), sha(bindingBytes), 'browser helper changed');
  };
  await fs.mkdir(out, {recursive: false});
  if (verifyOnly) {
    await verifyFinal();
    const report = {kind:'windows_fixture_browser_input_preparation', passed:true, formal_acceptance:false,
      preparation_pseudo_candidate:true, production_task:false, real_browser_executed:false,
      input_validation_sha256:sha(validationBytes), browser_inputs_sha256:verified.sha256,
      verified_files:verified.files, script_sha256:sha(scriptBytes), binding_script_sha256:sha(bindingBytes)};
    await fs.writeFile(path.join(out,'browser-result.json'), JSON.stringify(report,null,2)+'\n');
    process.stdout.write(JSON.stringify(report)+'\n');
    return;
  }
  const fixtureRoot = path.join(root, 'frozen-python');
  const snapshotBytes = verified.buffers.get('frozen-python/fixture-snapshot.json');
  const contextBytes = verified.buffers.get('frozen-python/fixture-contexts.json');
  const snapshot = JSON.parse(snapshotBytes);
  const contexts = JSON.parse(contextBytes);
  assert.equal(snapshot.tasks.length, 1);
  assert.equal(snapshot.sessions.length, 6);
  const web = path.join(root, 'frozen-stage', 'app', 'web');
  const {chromium} = require(pwRoot);
  const playwrightVersion = require(path.join(pwRoot, 'package.json')).version;
  assert.equal(playwrightVersion, '1.62.1');
  assert.equal(path.basename(chrome).toLowerCase(), 'chrome.exe');
  const checks = [], errors = [];
  const report = {kind:'windows_fixture_browser_preparation', formal_acceptance:false,
    preparation_pseudo_candidate:true, production_task:false, passed:false,
    real_wsl_executed:false, existing_services_touched:false, private_profile:true,
    input_validation_sha256:sha(validationBytes), snapshot_sha256:sha(snapshotBytes),
    contexts_sha256:sha(contextBytes), script_sha256:sha(scriptBytes), binding_script_sha256:sha(bindingBytes),
    browser_inputs_sha256:verified.sha256, verified_files:verified.files,
    node:process.version, playwright:playwrightVersion, playwright_root:pwRoot, chrome_executable:chrome,
    candidate_sha:validation.candidate_before.sha, source_package:validation.source_package};
  const bootstrap = {title:'PREPARATION FIXTURE ONLY', interval:3600, port:0, rev:1,
    generated:'生成 Fixture', configPath:'fixture-only', configExists:false, stallHours:24,
    cost:{currency:'¥', enabled:false, inputPerM:0, cachedInputPerM:0, outputPerM:0},
    repos:[{name:'fixture/project', alias:'Fixture', glob:'/fixture-unused', enabled:true}], pending:[], history:{},
    collection:{status:'ok', source:'fixture', lastSuccess:new Date().toISOString(), lastError:''}};
  const json = (response, value, status=200) => {
    response.writeHead(status, {'Content-Type':'application/json; charset=utf-8', 'Cache-Control':'no-store'});
    response.end(JSON.stringify(value));
  };
  const server = http.createServer(async (request, response) => {
    try {
      const url = new URL(request.url, 'http://fixture.invalid');
      if (url.pathname === '/api/bootstrap') return json(response, bootstrap);
      if (url.pathname === '/api/snapshot') return json(response, snapshot);
      const match = url.pathname.match(/^\/api\/sessions\/([A-Za-z0-9._-]+)\/context$/);
      if (match) {
        if (!contexts[match[1]]) return json(response, {status:'missing'}, 404);
        const result = structuredClone(contexts[match[1]]);
        const type = url.searchParams.get('type') || 'all', q = url.searchParams.get('q') || '';
        result.entries = result.entries.filter(entry => (type === 'all' || entry.type === type) &&
          (entry.text || '').toLowerCase().includes(q.toLowerCase()));
        result.page.filter = {type, q};
        return json(response, result);
      }
      let file;
      if (url.pathname === '/' || url.pathname === '/index.html') file = path.join(web, 'index.html');
      else if (url.pathname.startsWith('/assets/')) file = path.resolve(web, '.' + decodeURIComponent(url.pathname));
      else if (/^\/prototypes\/context-[0-9a-f-]+\.html$/.test(url.pathname))
        file = path.join(fixtureRoot, 'rendered', path.basename(url.pathname));
      else {response.writeHead(404); return response.end('fixture route not found');}
      assert(file.startsWith(web + path.sep) || file.startsWith(path.join(fixtureRoot, 'rendered') + path.sep));
      const relative = path.relative(root, file).split(path.sep).join('/');
      const data = verified.buffers.get(relative);
      assert(data, 'unbound fixture file cannot be served');
      response.writeHead(200, {'Content-Type':({'.html':'text/html; charset=utf-8', '.js':'text/javascript; charset=utf-8',
        '.css':'text/css; charset=utf-8'})[path.extname(file)] || 'application/octet-stream'});
      response.end(data);
    } catch {response.writeHead(500); response.end('fixture request rejected');}
  });
  let context;
  try {
    await new Promise((resolve, reject) => {server.once('error', reject); server.listen(0, '127.0.0.1', resolve);});
    const origin = 'http://127.0.0.1:' + server.address().port;
    report.fixture_origin = origin;
    const privateHome = path.join(out, 'private-home');
    await fs.mkdir(privateHome);
    const privateRoaming = path.join(privateHome, 'AppData', 'Roaming');
    const privateLocal = path.join(privateHome, 'AppData', 'Local');
    const privateTemp = path.join(privateHome, 'Temp');
    await Promise.all([privateRoaming, privateLocal, privateTemp].map(directory => fs.mkdir(directory, {recursive:true})));
    const env = Object.fromEntries(['PATH','SystemRoot','WINDIR','COMSPEC','PATHEXT'].filter(key => process.env[key]).map(key => [key,process.env[key]]));
    Object.assign(env, {HOME:privateHome,USERPROFILE:privateHome,TEMP:privateTemp,TMP:privateTemp,APPDATA:privateRoaming,LOCALAPPDATA:privateLocal});
    context = await chromium.launchPersistentContext(path.join(out, 'private-profile'), {
      executablePath:chrome, headless:true, chromiumSandbox:true, env,
      viewport:{width:1440,height:960}, reducedMotion:'reduce'});
    report.browser_version = context.browser().version();
    await context.route('**/*', route => new URL(route.request().url()).origin === origin ? route.continue() : route.abort());
    const page = await context.newPage();
    await page.addInitScript(installRefreshObserver);
    page.on('pageerror', error => errors.push(error.message));
    const visible = selector => page.locator(selector).first().waitFor({state:'visible',timeout:10000});
    const taskId = snapshot.stories[0].id;
    const coder = snapshot.sessions.find(session => session.role === '编码');
    assert(coder, 'fixture coder is mandatory');
    await page.goto(origin + '/#/story/' + taskId);
    await visible('#detail-pane .detail-head');
    assert(await page.locator('#detail-pane details.round').count() >= 19);
    assert((await page.locator('#detail-pane').innerText()).includes('19'));
    checks.push('task deep link and controller rounds');
    await page.goto(origin + '/#/agents/' + coder.id);
    await visible('.context-metadata');
    assert((await page.locator('#context-overview').innerText()).includes('synthetic validation'));
    await page.goBack(); await visible('#detail-pane .detail-head');
    await page.goForward(); await visible('.context-metadata');
    checks.push('session deep link and browser back/forward');
    await page.locator('[data-context-tab="transcript"]').click();
    await visible('.context-entry');
    await page.locator('#context-type').selectOption('tool');
    await visible('.context-entry');
    const filteredResponse = page.waitForResponse(response => {
      const url = new URL(response.url());
      return url.pathname.endsWith('/context') && url.searchParams.get('q') === 'FIXTURE_TOOL';
    });
    await page.locator('#context-search').fill('FIXTURE_TOOL');
    await filteredResponse;
    await visible('.context-entry');
    const rereadResponse = page.waitForResponse(response => {
      const url = new URL(response.url());
      return url.pathname.endsWith('/context') && url.searchParams.get('q') === 'FIXTURE_TOOL';
    });
    await page.locator('[data-context-refresh]').click();
    await rereadResponse;
    await visible('.context-entry');
    assert.equal(await page.locator('#context-type').inputValue(), 'tool');
    assert.equal(await page.locator('#context-search').inputValue(), 'FIXTURE_TOOL');
    checks.push('visible session reread preserves transcript reading filters');
    const refreshBefore = await page.evaluate(() => globalThis.__viewFixtureRefreshObserver.sequence);
    // The app is inert behind the open session. Exercise its background refresh
    // handler without claiming that its covered toolbar is pointer-accessible.
    await page.locator('#refresh-now').dispatchEvent('click');
    await page.waitForFunction(refreshCompletion, refreshBefore, {timeout:10000});
    assert.equal(await page.locator('#context-type').inputValue(), 'tool');
    assert.equal(await page.locator('#context-search').inputValue(), 'FIXTURE_TOOL');
    checks.push('background snapshot refresh preserves transcript reading filters');
    await page.keyboard.press('Escape');
    await page.locator('#session-overlay').waitFor({state:'hidden'});
    await page.locator('#agent-search').fill(coder.id);
    await page.locator('#agent-groups .acard').click(); await visible('.context-metadata');
    assert(await page.locator('#context-overview').isVisible());
    assert.equal(await page.locator('#context-transcript').isVisible(), false);
    checks.push('close and reopen resets context pane safely');
    await page.screenshot({path:path.join(out,'context-desktop.png')});
    await page.setViewportSize({width:390,height:844});
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    await page.screenshot({path:path.join(out,'context-mobile.png')});
    checks.push('390px context layout has no horizontal overflow');
    await page.keyboard.press('Escape');
    await page.goto(origin + '/#/story/' + taskId); await visible('#detail-pane .detail-head');
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    await page.screenshot({path:path.join(out,'task-mobile.png')});
    checks.push('390px task layout has no horizontal overflow');
    assert.deepEqual(errors, []);
    report.passed = true;
  } catch (error) {report.error = String(error.stack || error);}
  finally {
    await finish({context, server, report, out, checks, errors, verifyFinal});
  }
  process.stdout.write(JSON.stringify({kind:report.kind,passed:report.passed,formal_acceptance:false,
    preparation_pseudo_candidate:true,checks,error:report.error})+'\n');
  if (!report.passed) process.exitCode=1;
})().catch(error => {process.stderr.write(JSON.stringify({kind:'windows_fixture_browser_preparation',passed:false,
  formal_acceptance:false,preparation_pseudo_candidate:true,error:String(error.stack || error)})+'\n'); process.exitCode=1;});
