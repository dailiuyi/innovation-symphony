// Synthetic updates stay in Playwright routes; no runtime or fixture file is written.
const assert = require('node:assert/strict');

async function nativeReading(page, origin, snapshot, session) {
  const endpoint = `/api/sessions/${session.id}/context`;
  const source = await (await page.request.get(origin + endpoint)).json();
  const tool = source.entries.find(entry => entry.type === 'tool');
  assert(tool, 'refresh regression needs a parsed tool record');
  let version = 1, requests = 0;
  const pattern = `**${endpoint}?*`;
  await page.route(pattern, async route => {
    requests++;
    const url = new URL(route.request().url());
    const type = url.searchParams.get('type'), q = url.searchParams.get('q') || '';
    const end = Number(url.searchParams.get('before') || 120);
    const start = Math.max(0, end - Number(url.searchParams.get('limit') || 50));
    const entries = Array.from({length: end - start}, (_, offset) => ({...tool,
      index: start + offset,
      text: `GH7_READING_ENTRY_${String(start + offset).padStart(3, '0')} v${version}\n`
        + (tool.text + '\n').repeat(20)}))
      .filter(entry => (type === 'all' || type === entry.type) && entry.text.includes(q));
    await route.fulfill({json: {...source, entries,
      page: {...source.page, nextBefore: start || null, hasOlder: start > 0, filter: {type, q}}}});
  });
  const reading = () => page.evaluate(() => ({
    text: document.getElementById('context-entries').innerText,
    scroll: document.getElementById('session-content').scrollTop,
    type: document.getElementById('context-type').value,
    query: document.getElementById('context-search').value,
    selection: [document.getElementById('context-search').selectionStart,
      document.getElementById('context-search').selectionEnd],
    tab: document.querySelector('[data-context-tab].active').dataset.contextTab,
    href: location.hash,
    older: !!document.querySelector('[data-context-older]'),
    readingTop: document.querySelector('.context-entry').getBoundingClientRect().top,
  }));
  try {
    await page.locator('[data-context-refresh]').click();
    await page.waitForFunction(() => document.getElementById('context-entries').textContent.includes('GH7_READING_ENTRY_070 v1'));
    const queryResponse = page.waitForResponse(res => res.url().includes(endpoint) && new URL(res.url()).searchParams.get('q') === 'GH7_READING_ENTRY');
    await page.locator('#context-search').fill('GH7_READING_ENTRY');
    await queryResponse;
    await page.waitForFunction(() => !document.querySelector('.context-loading'));
    await page.locator('[data-context-older]').click();
    await page.waitForFunction(() => document.getElementById('context-entries').textContent.includes('GH7_READING_ENTRY_020 v1'));
    await page.evaluate(() => {
      document.getElementById('context-search').focus();
      document.getElementById('context-search').setSelectionRange(2, 8);
      document.getElementById('session-content').scrollTop = 320;
    });
    const before = await reading(), count = requests;
    assert(before.scroll > 0 && before.older, 'exercise a scrolled, older transcript page');
    version = 2;
    const updated = structuredClone(snapshot);
    const marker = 'GH7_REFRESH_SNAPSHOT_V2';
    updated.sessions.find(item => item.id === session.id).promptHead = marker;
    await page.route('**/api/snapshot', route => route.fulfill({json: updated}));
    const response = page.waitForResponse(res => new URL(res.url()).pathname === '/api/snapshot');
    // The board is inert while the reader is open; dispatch its real refresh handler.
    await page.locator('#refresh-now').evaluate(el => el.click());
    await (await response).finished();
    // Receiving HTTP 200 is insufficient: wait until the new snapshot has rendered.
    await page.waitForFunction(async ({id, marker}) => {
      const {state} = await import('/assets/js/data.js');
      return state.sessions.find(item => item.id === id)?.promptHead === marker;
    }, {id: session.id, marker});
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    assert.deepEqual(await reading(), before, 'completed snapshot update preserves content, older page, scroll, filters and selection');
    assert.equal(requests, count, 'background update must not re-read the pinned transcript');
    // Prove newer content exists and explicit re-read actually receives it.
    await page.locator('[data-context-refresh]').click();
    await page.waitForFunction(() => document.getElementById('context-entries').textContent.includes('GH7_READING_ENTRY_070 v2'));
    assert.equal(await page.locator('#context-type').inputValue(), 'tool');
    assert.equal(await page.locator('#context-search').inputValue(), 'GH7_READING_ENTRY');
  } finally {
    await page.unroute(pattern);
    await page.unroute('**/api/snapshot');
  }
}

async function generatedReading(context, board, origin, session) {
  const url = origin + '/prototypes/' + session.href;
  const response = await board.request.get(url);
  assert.equal(response.status(), 200);
  const rendered = await response.text();
  // Extend the real generated document with deterministic long records. Its viewer
  // and production refreshSilent script remain intact; short source records cannot
  // exercise scroll restoration or collapsed output restoration on their own.
  const html = await board.evaluate(rendered => {
    const doc = new DOMParser().parseFromString(rendered, 'text/html');
    const messages = doc.getElementById('messages'), tree = doc.getElementById('tree-container');
    // Drive each refresh explicitly so a periodic tick cannot consume a version
    // between installing its response and awaiting refreshSilent().
    const refresh = [...doc.scripts].find(script => script.textContent.includes('window.refreshSilent ='));
    if (!refresh) throw new Error('generated page is missing the production refresh script');
    refresh.textContent = refresh.textContent.replace(/setInterval\(refreshSilent, \d+ \* 1000\)/,
      'setInterval(refreshSilent, 3600 * 1000)');
    // 120 matching nodes overflow the real sidebar after search/filtering at the
    // smoke viewport. Forty 20px rows fit inside its ~815px tree container.
    for (let i = 0; i < 120; i++) {
      tree.insertAdjacentHTML('beforeend', `<a class="tree-node tree-role-tool" href="#gh7-reading-${i}">GH7 reading ${i}</a>`);
      const output = (`GH7 retained output ${i}\n`).repeat(12)
        + (i === 0 ? '<span id="gh7-reading-anchor">GH7 visible reading anchor</span>\n' : '')
        + (`GH7 retained output ${i}\n`).repeat(68);
      messages.insertAdjacentHTML('beforeend', `<details id="gh7-reading-${i}"><summary>GH7 reading ${i}</summary><div class="tool-output expandable" onclick="this.classList.toggle('expanded')"><pre class="output-preview">GH7 preview ${i}</pre><pre class="output-full">${output}</pre></div></details>`);
    }
    messages.insertAdjacentHTML('beforeend', '<p id="gh7-update">GH7 generated version 1</p>');
    return '<!DOCTYPE html>\n' + doc.documentElement.outerHTML;
  }, rendered);
  const transcript = await context.newPage();
  const errors = [];
  transcript.on('pageerror', error => errors.push(error.message));
  let version = 1, requests = 0;
  const token = number => String(number).repeat(20);
  await transcript.route(url, route => {
    requests++;
    if (version === 'unavailable') return route.fulfill({status: 503, body: 'fixture unavailable'});
    if (version === 'malformed') return route.fulfill({contentType: 'text/html', body: '<html><body>missing transcript regions</body></html>'});
    const body = html.replace(/data-transcript="[0-9a-f]{20}"/, `data-transcript="${token(version)}"`)
      .replace('GH7 generated version 1', `GH7 generated version ${version}`);
    return route.fulfill({contentType: 'text/html', body});
  });
  const reading = () => transcript.evaluate(() => ({
    page: window.scrollY,
    href: location.href,
    tree: document.getElementById('tree-container').scrollTop,
    search: document.getElementById('tree-search').value,
    filter: document.querySelector('.filter-btn.active').dataset.filter,
    active: document.querySelector('.tree-node.active')?.getAttribute('href'),
    open: document.getElementById('gh7-reading-0').open,
    expanded: document.querySelector('#gh7-reading-0 .tool-output').classList.contains('expanded'),
    text: document.querySelector('#gh7-reading-0 .output-full').innerText,
    readingTop: document.querySelector('#gh7-reading-0 .output-full').getBoundingClientRect().top,
    anchorTop: document.getElementById('gh7-reading-anchor').getBoundingClientRect().top,
  }));
  const settled = () => transcript.evaluate(() => new Promise(resolve =>
    requestAnimationFrame(() => requestAnimationFrame(resolve))));
  try {
    await transcript.goto(url);
    await transcript.waitForFunction(() => typeof window.refreshSilent === 'function');
    await transcript.locator('.filter-btn[data-filter="all"]').click();
    await transcript.locator('#tree-search').fill('GH7 reading');
    await transcript.locator('.tree-node[href="#gh7-reading-0"]').click();
    await transcript.locator('#gh7-reading-0 .tool-output').click();
    const overflow = await transcript.evaluate(() => ({
      page: document.scrollingElement.scrollHeight > document.scrollingElement.clientHeight,
      tree: document.getElementById('tree-container').scrollHeight > document.getElementById('tree-container').clientHeight,
    }));
    assert(overflow.page && overflow.tree, 'filtered fixture must overflow the actual page and tree scroll containers');
    await transcript.evaluate(() => {
      // The viewer's main grows with its content; the document scrolls. Cancel
      // the tree click's smooth navigation and place a real output line in view.
      const anchor = document.getElementById('gh7-reading-anchor');
      window.scrollTo({top: window.scrollY + anchor.getBoundingClientRect().top - 160, behavior: 'instant'});
      document.getElementById('tree-container').scrollTop = 80;
      window.gh7NoNavigation = true;
    });
    await settled();
    await transcript.waitForFunction(() => window.scrollY > 0 && document.getElementById('tree-container').scrollTop > 0);
    const before = await reading();
    await settled();
    assert.deepEqual(await reading(), before, 'transcript and tree scrolling have settled before refresh');
    assert(before.open && before.expanded && before.page > 0 && before.tree > 0,
      'exercise expanded output and nonzero transcript/tree positions');
    assert(before.anchorTop > 0 && before.anchorTop < await transcript.evaluate(() => innerHeight),
      'exercise a visible line inside the expanded output');
    for (const next of [2, 'malformed', 'unavailable', 3]) {
      version = next;
      const count = requests;
      const changed = await transcript.evaluate(() => window.refreshSilent());
      assert(requests > count, 'refreshSilent must fetch the generated page');
      assert.equal(changed, typeof next === 'number', 'apply updates, reject malformed/failed reads and allow retry');
      await settled();
      assert.deepEqual(await reading(), before, 'generated page preserves reading state after completed refresh');
      assert.equal(await transcript.evaluate(() => window.gh7NoNavigation), true, 'refresh must not navigate');
      const expected = next === 3 ? 3 : 2;
      assert.equal(await transcript.locator('body').getAttribute('data-transcript'), token(expected));
      assert.equal(await transcript.locator('#gh7-update').innerText(), `GH7 generated version ${expected}`);
    }
    assert.deepEqual(errors, [], 'generated transcript has no browser script errors');
  } finally { await transcript.close(); }
}

module.exports = {nativeReading, generatedReading};
