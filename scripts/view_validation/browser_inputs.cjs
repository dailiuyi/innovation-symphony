// Pure input binding and cleanup helpers. Importing this module starts no browser.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const sha = data => crypto.createHash('sha256').update(data).digest('hex');
const canonical = value => Buffer.from(JSON.stringify(Object.fromEntries(Object.keys(value).sort().map(key =>
  [key, value[key] && typeof value[key] === 'object' && !Array.isArray(value[key]) ?
    JSON.parse(canonical(value[key])) : value[key]]))) + '\n');

async function noLinks(file) {
  for (let current = path.resolve(file);;) {
    const stat = await fs.lstat(current);
    assert(!stat.isSymbolicLink(), 'linked fixture paths are forbidden');
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
}

async function readOrdinary(file) {
  await noLinks(file);
  const stat = await fs.lstat(file);
  assert(stat.isFile() && stat.size <= 16 * 1024 * 1024, 'fixture input must be a bounded ordinary file');
  return fs.readFile(file);
}


async function checkOutput(root, out) {
  for (const value of [root, out]) assert(typeof value === 'string' &&
    !/^(?:[\\/]{2}[?.][\\/]|[\\/]\?\?[\\/])/.test(value), 'Windows device/namespaced paths are forbidden');
  const normalized = value => process.platform === 'win32' ? path.resolve(value).toLowerCase() : path.resolve(value);
  const outside = (base, target) => {
    const relative = path.relative(normalized(base), normalized(target));
    assert(relative && (relative === '..' || relative.startsWith('..' + path.sep) || path.isAbsolute(relative)),
      'browser output must be outside the validation root');
  };
  outside(root, out);
  await noLinks(path.resolve(root));
  // The output is new; still check every existing ancestor before any mkdir/write.
  let nearest;
  const suffix = [];
  for (let current = path.resolve(out);;) {
    try {
      assert(!(await fs.lstat(current)).isSymbolicLink(), 'linked output ancestors are forbidden');
      if (!nearest) nearest = current;
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      if (!nearest) suffix.unshift(path.basename(current));
    }
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  assert(nearest, 'output has no existing canonical ancestor');
  outside(await fs.realpath(path.resolve(root)), path.join(await fs.realpath(nearest), ...suffix));
}


// Self-contained so Playwright can serialize this as a page init script.
function installRefreshObserver(host = globalThis) {
  if (host.__viewFixtureRefreshObserver) return;
  const proto = host.EventTarget.prototype;
  const add = proto.addEventListener, remove = proto.removeEventListener;
  const targets = new WeakMap();
  const state = {sequence:0, records:[]};
  host.__viewFixtureRefreshObserver = state;
  const capture = options => Boolean(typeof options === 'boolean' ? options : options && options.capture);
  proto.addEventListener = function(type, callback, options) {
    if (type !== 'click' || this.id !== 'refresh-now' || !callback ||
        !['function','object'].includes(typeof callback)) return add.call(this,type,callback,options);
    let callbacks = targets.get(this);
    if (!callbacks) {callbacks = new WeakMap(); targets.set(this,callbacks);}
    let captures = callbacks.get(callback);
    if (!captures) {captures = new Map(); callbacks.set(callback,captures);}
    const key = capture(options);
    let wrapped = captures.get(key);
    if (!wrapped) {
      wrapped = function(...args) {
        const record = {sequence:++state.sequence, settled:false, promise:false, error:null};
        state.records.push(record);
        let result;
        try {result = typeof callback === 'function' ? callback.apply(this,args) : callback.handleEvent.apply(callback,args);}
        catch (error) {record.settled=true; record.error=String(error.stack || error); throw error;}
        if (!(result instanceof host.Promise)) {
          record.settled=true; record.error='refresh click handler must return a Promise';
          return result;
        }
        record.promise=true;
        result.then(() => {record.settled=true;}, error => {record.settled=true; record.error=String(error.stack || error);});
        return result;
      };
      captures.set(key,wrapped);
    }
    return add.call(this,type,wrapped,options);
  };
  proto.removeEventListener = function(type, callback, options) {
    if (type !== 'click') return remove.call(this,type,callback,options);
    const wrapped = targets.get(this)?.get(callback)?.get(capture(options));
    return remove.call(this,type,type === 'click' && wrapped ? wrapped : callback,options);
  };
}

function refreshCompletion(before, host = globalThis) {
  const state = host.__viewFixtureRefreshObserver;
  if (!state) throw new Error('refresh completion observer is missing');
  const records = state.records.filter(record => record.sequence > before);
  if (!records.length) return false;
  for (const record of records) {
    if (!record.promise || record.error) throw new Error(record.error || 'refresh click did not return a Promise');
  }
  return records.every(record => record.settled);
}

async function enumerate(directory) {
  await noLinks(directory);
  assert((await fs.lstat(directory)).isDirectory(), 'fixture directory is missing');
  const files = [];
  for (const name of (await fs.readdir(directory)).sort()) {
    const item = path.join(directory, name), stat = await fs.lstat(item);
    assert(!stat.isSymbolicLink(), 'linked fixture entries are forbidden');
    if (stat.isDirectory()) files.push(...await enumerate(item));
    else {assert(stat.isFile(), 'special fixture entries are forbidden'); files.push(item);}
  }
  return files;
}

function inputPath(name) {
  assert(typeof name === 'string' && name === path.posix.normalize(name) && !name.startsWith('/') &&
    !/[\\:\0]/.test(name) && !name.split('/').some(part => part === '..' || part === '.'), 'unsafe fixture manifest path');
  assert(name.startsWith('frozen-stage/app/web/') || name.startsWith('frozen-python/rendered/') ||
    ['frozen-python/fixture-snapshot.json', 'frozen-python/fixture-contexts.json'].includes(name), 'unexpected fixture input scope');
  assert(!name.split('/').some(part => ['.local','.codex','.aws','auth.json','credentials'].includes(part.toLowerCase())),
    'private fixture metadata is forbidden');
}

async function verifyInputs(root, validation) {
  assert(validation.passed === true && validation.formal_acceptance === false && validation.preparation_pseudo_candidate === true,
    'browser fixture requires successful marked synthetic preparation');
  const binding = validation.browser_inputs;
  assert(binding && binding.schema_version === 1 && binding.files && typeof binding.files === 'object', 'browser input binding is missing');
  for (const [name, row] of Object.entries(binding.files)) {
    inputPath(name);
    assert(Number.isSafeInteger(row.bytes) && row.bytes >= 0 && row.bytes <= 16 * 1024 * 1024 &&
      /^[0-9a-f]{64}$/.test(row.sha256), 'invalid fixture file binding');
  }
  assert.equal(sha(canonical(binding.files)), binding.sha256, 'browser manifest digest differs');
  const actual = [...await enumerate(path.join(root, 'frozen-stage/app/web')),
    ...await enumerate(path.join(root, 'frozen-python/rendered')),
    path.join(root, 'frozen-python/fixture-snapshot.json'), path.join(root, 'frozen-python/fixture-contexts.json')];
  const names = actual.map(file => path.relative(root, file).split(path.sep).join('/')).sort();
  assert.deepEqual(names, Object.keys(binding.files).sort(), 'browser inputs added or removed since validation');
  assert(names.includes('frozen-stage/app/web/index.html'), 'browser entrypoint is not bound');
  const buffers = new Map(), rows = {};
  for (const name of names) {
    const data = await readOrdinary(path.join(root, name));
    rows[name] = {bytes:data.length, sha256:sha(data)};
    assert.deepEqual(rows[name], binding.files[name], 'browser input bytes changed since validation');
    buffers.set(name, data);
  }
  return {buffers, sha256:sha(canonical(rows)), files:names.length};
}

async function verifyUnchanged(root, validationBytes, validation) {
  assert.equal(sha(await readOrdinary(path.join(root, 'validation-result.json'))), sha(validationBytes), 'validation report changed');
  return verifyInputs(root, validation);
}

async function finish({context, server, report, out, checks, errors, verifyFinal}) {
  const failed = (label, error) => {
    report.passed = false;
    (report.cleanup_errors ||= []).push(label + ': ' + String(error.stack || error));
  };
  try {
    if (context) {
      try {await context.close(); report.own_browser_closed = true;}
      catch (error) {report.own_browser_closed = false; failed('browser close failed', error);}
    }
  } finally {
    try {
      if (server) {
        try {
          if (server.listening) await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
          report.own_fixture_service_closed = true;
        } catch (error) {report.own_fixture_service_closed = false; failed('fixture service close failed', error);}
      }
    } finally {
      try {
        if (verifyFinal) {
          try {await verifyFinal(); report.fixture_inputs_unchanged = true;}
          catch (error) {report.fixture_inputs_unchanged = false; failed('fixture input verification failed', error);}
        }
      } finally {
        report.checks = checks; report.browser_errors = errors;
        await fs.writeFile(path.join(out, 'browser-result.json'), JSON.stringify(report, null, 2) + '\n');
      }
    }
  }
}

module.exports = {sha, canonical, readOrdinary, checkOutput, installRefreshObserver, refreshCompletion,
  verifyInputs, verifyUnchanged, finish};
