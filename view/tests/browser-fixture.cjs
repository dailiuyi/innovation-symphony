// Run the existing UI smoke on GH-7 synthetic outputs, never a real service.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const http = require('node:http');
const path = require('node:path');
const {spawn} = require('node:child_process');
const fixture = path.resolve(process.argv[2] || '');
const web = path.resolve(__dirname, '../app/web');
const json = (res, value, status = 200) => {
  res.writeHead(status, {'Content-Type':'application/json; charset=utf-8', 'Cache-Control':'no-store'});
  res.end(JSON.stringify(value));
};

(async () => {
  assert(process.argv[2], 'usage: node view/tests/browser-fixture.cjs <checks-output>/fixture');
  assert.equal(require('playwright/package.json').version, '1.62.1');
  const snapshot = JSON.parse(await fs.readFile(path.join(fixture, 'fixture-snapshot.json')));
  const contexts = JSON.parse(await fs.readFile(path.join(fixture, 'fixture-contexts.json')));
  assert.equal(snapshot.tasks.length, 1);
  assert.equal(snapshot.sessions.length, 6);
  const bootstrap = {title:'GH-7 FIXTURE', interval:3600, port:0, rev:1, generated:'生成 Fixture',
    configPath:'fixture', configExists:false, stallHours:24, repos:[], pending:[], history:{},
    cost:{currency:'¥',enabled:false,inputPerM:0,cachedInputPerM:0,outputPerM:0},
    collection:{status:'ok',source:'fixture',lastSuccess:new Date().toISOString(),lastError:''}};
  const server = http.createServer(async (req, res) => {
    try {
      assert.equal(req.method, 'GET');
      const url = new URL(req.url, 'http://fixture.invalid');
      if (url.pathname === '/api/bootstrap') return json(res, bootstrap);
      if (url.pathname === '/api/snapshot') return json(res, snapshot);
      const match = url.pathname.match(/^\/api\/sessions\/([0-9a-f-]+)\/context$/);
      if (match) {
        if (!contexts[match[1]]) return json(res, {status:'missing'}, 404);
        const result = structuredClone(contexts[match[1]]);
        const type = url.searchParams.get('type') || 'all', q = url.searchParams.get('q') || '';
        result.entries = result.entries.filter(entry => (type === 'all' || entry.type === type)
          && entry.text.toLowerCase().includes(q.toLowerCase()));
        result.page.filter = {type, q};
        return json(res, result);
      }
      let file;
      if (url.pathname === '/') file = path.join(web, 'index.html');
      else if (url.pathname.startsWith('/assets/')) file = path.resolve(web, '.' + decodeURIComponent(url.pathname));
      else if (/^\/prototypes\/context-[0-9a-f-]+\.html$/.test(url.pathname))
        file = path.join(fixture, 'rendered', path.basename(url.pathname));
      else return json(res, {error:'fixture route missing'}, 404);
      assert(file.startsWith(web + path.sep) || file.startsWith(path.join(fixture, 'rendered') + path.sep));
      const bytes = await fs.readFile(file);
      res.writeHead(200, {'Content-Type': {'.html':'text/html; charset=utf-8', '.js':'text/javascript; charset=utf-8',
        '.css':'text/css; charset=utf-8'}[path.extname(file)] || 'application/octet-stream'});
      res.end(bytes);
    } catch (error) {json(res, {error:String(error)}, 500);}
  });
  let passed = false;
  try {
    await new Promise((resolve, reject) => {server.once('error', reject); server.listen(0, '127.0.0.1', resolve);});
    const child = spawn(process.execPath, [path.join(__dirname, 'browser-smoke.cjs'), '--url',
      'http://127.0.0.1:' + server.address().port, '--out', path.join(fixture, 'browser')], {stdio:'inherit'});
    const code = await new Promise((resolve, reject) => {child.once('error', reject); child.once('exit', resolve);});
    assert.equal(code, 0, 'fixture browser smoke failed');
    passed = true;
  } finally {
    await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    await fs.writeFile(path.join(fixture, 'browser-fixture-result.json'), JSON.stringify({passed,
      synthetic:true, real_windows_wsl:false, formal_acceptance:false}) + '\n');
  }
})().catch(error => {console.error(error); process.exitCode = 1;});
