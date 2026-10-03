import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';

const source = await readFile(new URL('../app/web/assets/js/rounds.js', import.meta.url), 'utf8');
const { roundsModel, reviewAttempts, attemptLabel } = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));

const review = (attempt, outcome = 'invalid_review', round = 19) => ({
  id: `review-${attempt}`, role: 'Review', round, attempt, attemptOutcome: outcome,
  verdict: { approved: false, summary: `old rejection ${attempt}` },
});
const fixture = () => ({
  status: 'blocked', reason: ':mvp_invalid_review', roundsAuthority: 'controller',
  rounds: Array.from({ length: 19 }, (_, i) => ({ round: i + 1, controller: true })),
  sessions: [
    { id: 'coder-1', role: '编码', round: 1 },
    { id: 'coder-retry', role: '编码', round: 1 },
    { id: 'coder-last', role: '编码', round: 19 },
    review(41), review(42), review(43), review(44, 'running'),
  ],
  evidence: [{ name: 'round-1/check-1.log', exit: 1, summary: 'old failed check' }],
  returns: [{ n: 1, kind: 'script', title: '脚本审查未通过', why: 'old failed check' }],
});

test('actual controller round keeps coder and reviewer retries together', () => {
  const rows = roundsModel(fixture());
  assert.equal(rows.length, 19);
  assert.equal(rows.at(-1).n, 19);
  assert.equal(rows.at(-1).sessions.filter(s => s.role === 'Review').length, 4);
  assert.equal(rows[0].sessions.length, 2);
  assert.equal(rows.at(-1).kind, 'protocol');
});

test('current recheck overrides earlier raw rejections and failed checks', () => {
  const cur = fixture();
  cur.status = 'reviewing'; cur.reason = '';
  cur.evidence.push({ name: 'round-19/check-1.log', exit: 124, summary: 'previous timeout' });
  cur.returns.push({ n: 19, title: 'old timeout', kind: 'script' });
  const last = roundsModel(cur).at(-1);
  assert.equal(last.title, 'Review 中');
  assert.equal(last.kind, 'open');
  assert(!last.why.includes('old rejection'));
});

test('raw review verdict never becomes a controller decision', () => {
  const cur = fixture();
  cur.reason = ''; cur.status = 'unknown';
  cur.sessions = [review(44, 'completed')];
  assert.equal(roundsModel(cur).at(-1).kind, 'open');
  cur.rounds[18].review = { approved: true, summary: 'accepted by controller' };
  assert.equal(roundsModel(cur).at(-1).kind, 'approved');
});

test('unmapped sessions remain separate without guessed controller rounds', () => {
  const cur = fixture();
  cur.sessions.push({ role: '编码', id: 'unmapped' });
  const rows = roundsModel(cur);
  assert.equal(rows.at(-1).n, null);
  assert.equal(rows.at(-1).sessions[0].id, 'unmapped');
  assert.equal(rows.filter(r => r.n != null).length, 19);
});

test('review history selects the latest attempt and labels protocol failure', () => {
  const rows = reviewAttempts([review(43), review(41), review(44, 'completed'), review(42)]);
  assert.equal(rows.at(-1).id, 'review-44');
  assert.equal(attemptLabel(rows[0]), '协议校验失败');
  assert.equal(attemptLabel(rows.at(-1)), '会话完成');
});

test('a failed latest protocol attempt supersedes an earlier accepted review', () => {
  const cur = fixture();
  cur.sessions = [review(43)];
  cur.rounds[18].review = { approved: false, summary: 'earlier decision' };
  assert.equal(roundsModel(cur).at(-1).kind, 'protocol');
});

test('legacy session-only opinions remain explicitly unconfirmed', () => {
  const rows = roundsModel({ sessions: [{ role: '编码' }, review(1, 'unknown', null)] });
  assert.equal(rows[0].title, 'Review 会话意见（未确认）');
  assert.equal(rows[0].kind, 'open');
});

test('explicit legacy authority preserves ordinal session grouping', () => {
  const rows = roundsModel({ roundsAuthority: 'legacy', rounds: [{ round: 1 }], sessions: [{ role: '编码' }, review(1, 'unknown', null)] });
  assert.equal(rows.length, 1);
  assert.equal(rows[0].sessions.length, 2);
  assert.equal(rows[0].authoritative, false);
});

test('orphan evidence and sessions cannot invent controller rounds or decisions', () => {
  const cur = fixture();
  cur.sessions.push(review(90, 'completed', 99));
  cur.evidence.push({ name: 'round-100/review.json', approved: false });
  cur.returns.push({ n: 101, kind: 'review', title: 'orphan rejection' });
  const rows = roundsModel(cur);
  assert.equal(rows.filter(r => r.n != null).length, 19);
  assert.equal(rows.at(-1).n, null);
  assert.equal(rows.at(-1).kind, 'open');
  assert.equal(rows.at(-1).title, '归属未记录');
});

test('accepted review is visible during the reviewing-to-conclude window', () => {
  const cur = fixture();
  cur.status = 'reviewing'; cur.reason = '';
  cur.sessions = [review(44, 'completed')];
  cur.rounds[18].review = { approved: false, summary: 'controller decision' };
  assert.equal(roundsModel(cur).at(-1).kind, 'rejected');
});
