// Synthetic display acceptance only; never opens the external issue or MR URL.
const assert = require('node:assert/strict');
const {chromium} = require('playwright');

async function gitlabReading(origin, snapshot, launchOptions = {}) {
  const browser = await chromium.launch({headless:true, ...launchOptions});
  try {
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    const data = JSON.parse(JSON.stringify(snapshot).replaceAll('GH-7', 'GL-7'));
    const issueUrl = 'https://gitlab.example/team/subgroup/luca/-/issues/7';
    const pr = {kind:'merge_request', number:3, state:'unknown', draft:false,
      url:'https://gitlab.example/team/subgroup/luca/-/merge_requests/3'};
    const task = data.tasks[0], story = data.stories[0];
    Object.assign(task, {issueUrl, pr, repo:'team/subgroup/luca', status:'awaiting_review'});
    Object.assign(story, {issueUrl, pr, repo:'team/subgroup/luca', outcomeKind:'human'});
    Object.assign(story.beats.at(-1), {pr, status:'awaiting_review'});
    await page.route('**/api/snapshot', route => route.fulfill({json:data}));
    await page.goto(origin + '/#/story/' + encodeURIComponent(story.id));
    const detail = page.locator('#detail-pane');
    await detail.getByRole('link', {name:'查看 Issue GL-7', exact:true}).waitFor();
    assert.equal(await detail.getByRole('link', {name:'查看 Issue GL-7', exact:true}).getAttribute('href'), issueUrl);
    assert.equal(await detail.getByRole('link', {name:'处理 MR #3', exact:true}).getAttribute('href'), pr.url);
    assert.equal(await detail.locator('.node-title').filter({hasText:'等待处理 MR'}).count(), 1);
    assert.equal(await page.locator('.card .issue').first().textContent().then(text => text.includes('GL-7')), true);
    assert.deepEqual(errors, []);
    return {check:'GitLab issue deep link, native instance URLs, MR labels and no browser script errors',
      browser:browser.version(), synthetic:true};
  } finally {
    await browser.close();
  }
}
module.exports = {gitlabReading};
