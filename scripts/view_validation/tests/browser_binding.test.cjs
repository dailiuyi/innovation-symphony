// All data and cleanup objects here are synthetic; no browser or server starts.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const {sha, canonical, checkOutput, installRefreshObserver, refreshCompletion, verifyInputs, verifyUnchanged, finish} = require('../browser_inputs.cjs');
const {spawnSync} = require('node:child_process');
const vm = require('node:vm');

async function fixture(fn) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'view-browser-binding-'));
  try {
    const content = {
      'frozen-stage/app/web/index.html':'SYNTHETIC_HTML',
      'frozen-stage/app/web/assets/app.js':'SYNTHETIC_SCRIPT',
      'frozen-python/rendered/context-00000007.html':'SYNTHETIC_CONTEXT',
      'frozen-python/fixture-snapshot.json':'{"fixture":true}',
      'frozen-python/fixture-contexts.json':'{"fixture":true}'
    }, files = {};
    for (const [name, text] of Object.entries(content)) {
      const data = Buffer.from(text), target = path.join(root, name);
      await fs.mkdir(path.dirname(target), {recursive:true}); await fs.writeFile(target, data);
      files[name] = {bytes:data.length, sha256:sha(data)};
    }
    const validation = {passed:true, formal_acceptance:false, preparation_pseudo_candidate:true,
      browser_inputs:{schema_version:1, files, sha256:sha(canonical(files))}};
    const bytes = Buffer.from(JSON.stringify(validation));
    await fs.writeFile(path.join(root,'validation-result.json'), bytes);
    await fn({root, content, validation, bytes});
  } finally {
    assert.equal(path.dirname(path.resolve(root)), path.resolve(os.tmpdir()));
    assert(path.basename(root).startsWith('view-browser-binding-'));
    await fs.rm(root, {recursive:true, force:true});
  }
}

test('bound input verification returns only authenticated cached bytes', async () => fixture(async ({root, content, validation, bytes}) => {
  const verified = await verifyInputs(root, validation);
  assert.equal(verified.files, Object.keys(content).length);
  assert.equal(verified.sha256, validation.browser_inputs.sha256);
  assert.equal(verified.buffers.get('frozen-stage/app/web/index.html').toString(), 'SYNTHETIC_HTML');
  await verifyUnchanged(root, bytes, validation);
}));

test('web, rendered HTML, snapshot and contexts mutations reject the old report', async () => fixture(async ({root, content, validation}) => {
  for (const [name, text] of Object.entries(content)) {
    await fs.writeFile(path.join(root,name), text + '_CHANGED');
    await assert.rejects(() => verifyInputs(root,validation), /bytes changed/);
    await fs.writeFile(path.join(root,name), text);
  }
}));

test('extra and missing files reject before serving', async () => fixture(async ({root, validation}) => {
  const extra = path.join(root,'frozen-stage/app/web/ignored-extra.js');
  await fs.writeFile(extra,'SYNTHETIC_EXTRA');
  await assert.rejects(() => verifyInputs(root,validation), /added or removed/);
  await fs.unlink(extra);
  await fs.unlink(path.join(root,'frozen-python/rendered/context-00000007.html'));
  await assert.rejects(() => verifyInputs(root,validation), /added or removed/);
}));

test('unsafe manifest paths and changed validation bytes reject', async () => fixture(async ({root, validation, bytes}) => {
  const unsafe = structuredClone(validation);
  unsafe.browser_inputs.files['../private/auth.json'] = {bytes:0,sha256:sha(Buffer.alloc(0))};
  unsafe.browser_inputs.sha256 = sha(canonical(unsafe.browser_inputs.files));
  await assert.rejects(() => verifyInputs(root,unsafe), /unsafe fixture manifest path/);
  await fs.writeFile(path.join(root,'validation-result.json'), JSON.stringify({...validation, changed:true}));
  await assert.rejects(() => verifyUnchanged(root,bytes,validation), /validation report changed/);
}));

test('browser close failure still closes own service and writes a failing report', async () => fixture(async ({root}) => {
  let closed = false;
  const report = {passed:true,formal_acceptance:false,preparation_pseudo_candidate:true};
  const context = {close:async () => {throw new Error('SYNTHETIC_CLOSE_FAILURE');}};
  const server = {listening:true,close:callback => {closed=true;callback();}};
  await finish({context,server,report,out:root,checks:['synthetic'],errors:[],verifyFinal:async()=>{}});
  const stored = JSON.parse(await fs.readFile(path.join(root,'browser-result.json')));
  assert(closed); assert.equal(stored.own_browser_closed,false); assert.equal(stored.own_fixture_service_closed,true);
  assert.equal(stored.passed,false); assert.equal(stored.formal_acceptance,false);
  assert.match(stored.cleanup_errors[0],/SYNTHETIC_CLOSE_FAILURE/);
}));

test('final input rejection still closes own service and persists failure', async () => fixture(async ({root}) => {
  const report = {passed:true,formal_acceptance:false,preparation_pseudo_candidate:true};
  let closed=false;
  await finish({server:{listening:true,close:callback=>{closed=true;callback();}},report,out:root,checks:[],errors:[],
    verifyFinal:async()=>{throw new Error('SYNTHETIC_CHANGED_AFTER_RUN');}});
  const stored=JSON.parse(await fs.readFile(path.join(root,'browser-result.json')));
  assert(closed); assert.equal(stored.passed,false); assert.equal(stored.fixture_inputs_unchanged,false);
}));

test('output guard rejects validation root and all descendants before creating output', async () => fixture(async ({root}) => {
  const nested = path.join(root,'frozen-stage/app/web/review-output');
  for (const out of [root,nested]) await assert.rejects(() => checkOutput(root,out), /outside the validation root/);
  if (process.platform === 'win32') await assert.rejects(() => checkOutput(root.toUpperCase(),nested), /outside the validation root/);
  await assert.rejects(() => fs.access(nested), {code:'ENOENT'});
  await checkOutput(root, root + '-safe-sibling');
}));

test('output guard rejects existing linked ancestors using only mocked metadata', async () => fixture(async ({root}) => {
  const original = fs.lstat;
  const out = root + '-outside/new-output';
  const fakeAncestor = path.resolve(root + '-outside');
  fs.lstat = async name => path.resolve(name) === fakeAncestor ? {isSymbolicLink:()=>true} : original(name);
  try {await assert.rejects(() => checkOutput(root,out), /linked output ancestors/);}
  finally {fs.lstat = original;}
  await assert.rejects(() => fs.access(out), {code:'ENOENT'});
}));

test('verify-only CLI rejects bound output before directory or report creation', async () => fixture(async ({root}) => {
  const out = path.join(root,'frozen-stage/app/web/forbidden-cli-output');
  const result = spawnSync(process.execPath,[path.join(__dirname,'../browser_fixture.cjs'),
    '--validation-root',root,'--output',out,'--verify-only'],{encoding:'utf8',timeout:10000});
  assert.equal(result.status,1);
  assert.match(result.stderr,/outside the validation root/);
  assert.equal(JSON.parse(result.stderr.trim()).formal_acceptance,false);
  await assert.rejects(() => fs.access(out), {code:'ENOENT'});
}));

test('Windows namespace prefixes reject before resolve or filesystem access', async () => fixture(async ({root}) => {
  const slash = String.fromCharCode(92);
  const prefixes = [slash+slash+'?'+slash,slash+slash+'.'+slash,slash+'??'+slash,'//?/'];
  const original = fs.lstat;
  fs.lstat = async () => {throw new Error('filesystem access before namespace rejection');};
  try {
    for (const prefix of prefixes) {
      await assert.rejects(() => checkOutput(prefix+root,root+'-output'), /device\/namespaced/);
      await assert.rejects(() => checkOutput(root,prefix+root+'-output'), /device\/namespaced/);
    }
  } finally {fs.lstat=original;}
  const result = spawnSync(process.execPath,[path.join(__dirname,'../browser_fixture.cjs'),
    '--validation-root',prefixes[0]+root,'--output',root+'-output','--verify-only'],{encoding:'utf8',timeout:10000});
  assert.equal(result.status,1); assert.match(result.stderr,/device\/namespaced/);
  await assert.rejects(() => fs.access(root+'-output'), {code:'ENOENT'});
}));

test('canonical output ancestor alias into bound web rejects before mkdir', async () => fixture(async ({root}) => {
  const alias = root+'-canonical-alias', out=path.join(alias,'new-report');
  const originalStat=fs.lstat, originalRealpath=fs.realpath;
  fs.lstat = async name => path.resolve(name)===path.resolve(alias) ? {isSymbolicLink:()=>false} : originalStat(name);
  fs.realpath = async name => path.resolve(name)===path.resolve(alias) ? path.join(root,'frozen-stage/app/web') : originalRealpath(name);
  try {await assert.rejects(() => checkOutput(root,out), /outside the validation root/);}
  finally {fs.lstat=originalStat; fs.realpath=originalRealpath;}
  await assert.rejects(() => fs.access(out), {code:'ENOENT'});
  await assert.rejects(() => fs.access(path.join(root,'frozen-stage/app/web/new-report')), {code:'ENOENT'});
}));

function deferred() {
  let resolve,reject;
  const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});
  return {promise,resolve,reject};
}

function refreshHost() {
  class FakeTarget {
    constructor(id) {this.id=id;this.listeners=[];}
    addEventListener(type,callback,options) {
      const capture=Boolean(typeof options==='boolean'?options:options&&options.capture);
      if (!this.listeners.some(row=>row.type===type&&row.callback===callback&&row.capture===capture))
        this.listeners.push({type,callback,capture});
      return 'ADD_RESULT';
    }
    removeEventListener(type,callback,options) {
      const capture=Boolean(typeof options==='boolean'?options:options&&options.capture);
      this.listeners=this.listeners.filter(row=>!(row.type===type&&row.callback===callback&&row.capture===capture));
      return 'REMOVE_RESULT';
    }
    dispatch(event) {
      return this.listeners.filter(row=>row.type===event.type).map(row=>typeof row.callback==='function'?
        row.callback.call(this,event):row.callback.handleEvent.call(row.callback,event));
    }
  }
  return {EventTarget:FakeTarget,Promise};
}

test('serialized refresh observer waits for deferred handler and sees late filter reset', async () => {
  const host=refreshHost();
  vm.runInNewContext('('+installRefreshObserver.toString()+')(host)',{host});
  const target=new host.EventTarget('refresh-now'), gate=deferred(), event={type:'click'}, filter={type:'tool'};
  let returned;
  assert.equal(target.addEventListener('click',function(actual) {
    assert.equal(this,target);assert.equal(actual,event);
    returned=gate.promise.then(()=>{filter.type='all';}); return returned;
  }), 'ADD_RESULT');
  assert.equal(target.dispatch(event)[0],returned);
  assert.equal(vm.runInNewContext('('+refreshCompletion.toString()+')(0,host)',{host}),false);
  assert.equal(filter.type,'tool');
  gate.resolve(); await returned;
  assert.equal(refreshCompletion(0,host),true); assert.equal(filter.type,'all');
});

test('refresh completion waits for every newly invoked listener Promise', async () => {
  const host=refreshHost(); installRefreshObserver(host);
  const target=new host.EventTarget('refresh-now'), first=deferred(), second=deferred();
  target.addEventListener('click',()=>first.promise);target.addEventListener('click',()=>second.promise);
  const before=host.__viewFixtureRefreshObserver.sequence;
  assert.deepEqual(target.dispatch({type:'click'}),[first.promise,second.promise]);
  assert.equal(refreshCompletion(before,host),false);
  first.resolve();await first.promise;assert.equal(refreshCompletion(before,host),false);
  second.resolve();await second.promise;assert.equal(refreshCompletion(before,host),true);
  assert.equal(host.__viewFixtureRefreshObserver.records.length,2);
});

test('rejected refresh handler Promise fails the completion barrier', async () => {
  const host=refreshHost();installRefreshObserver(host);
  const target=new host.EventTarget('refresh-now'), gate=deferred();
  target.addEventListener('click',()=>gate.promise);
  assert.equal(target.dispatch({type:'click'})[0],gate.promise);
  gate.reject(new Error('SYNTHETIC_REFRESH_REJECTION'));
  await assert.rejects(gate.promise,/SYNTHETIC_REFRESH_REJECTION/);
  assert.throws(()=>refreshCompletion(0,host),/SYNTHETIC_REFRESH_REJECTION/);
});

test('non-Promise and thrown refresh handlers fail closed', () => {
  const host=refreshHost();installRefreshObserver(host);
  const target=new host.EventTarget('refresh-now');
  target.addEventListener('click',()=>undefined);target.dispatch({type:'click'});
  assert.throws(()=>refreshCompletion(0,host),/must return a Promise/);
  const other=refreshHost();installRefreshObserver(other);
  const throws=new other.EventTarget('refresh-now');
  throws.addEventListener('click',()=>{throw new Error('SYNTHETIC_REFRESH_THROW');});
  assert.throws(()=>throws.dispatch({type:'click'}),/SYNTHETIC_REFRESH_THROW/);
  assert.throws(()=>refreshCompletion(0,other),/SYNTHETIC_REFRESH_THROW/);
});

test('refresh wrappers preserve add/remove callback identity and other targets', async () => {
  const host=refreshHost();installRefreshObserver(host);
  const target=new host.EventTarget('refresh-now'), callback=()=>Promise.resolve('done');
  target.addEventListener('click',callback,false);target.addEventListener('click',callback,false);
  target.addEventListener('click',callback,true);
  assert.equal(target.listeners.length,2);
  assert.equal(target.removeEventListener('click',callback,false),'REMOVE_RESULT');
  const results=target.dispatch({type:'click'});assert.equal(results.length,1);await results[0];
  assert.equal(refreshCompletion(0,host),true);
  target.removeEventListener('click',callback,true);assert.equal(target.listeners.length,0);
  const object={handleEvent:function() {assert.equal(this,object);return Promise.resolve();}};
  target.addEventListener('click',object);await target.dispatch({type:'click'})[0];
  target.removeEventListener('click',object);assert.equal(target.listeners.length,0);
  const outside=new host.EventTarget('other-target'), sequence=host.__viewFixtureRefreshObserver.sequence;
  outside.addEventListener('click',()=>123);assert.deepEqual(outside.dispatch({type:'click'}),[123]);
  assert.equal(host.__viewFixtureRefreshObserver.sequence,sequence);
});
