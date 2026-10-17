// Pure presentation model: controller rounds and attempts are the source of truth.
export function reviewAttempts(sessions) {
  return sessions.filter(s => s.role === 'Review').sort((a, b) =>
    (a.attempt || 0) - (b.attempt || 0) || String(a.firstTs || '').localeCompare(String(b.firstTs || '')));
}

export function attemptLabel(session) {
  const labels = {
    invalid_review: '协议校验失败', completed: '会话完成', timeout: '超时',
    failed: '执行失败', running: '进行中', unknown: '结果未记录',
  };
  return labels[session.attemptOutcome] || '结果未记录';
}

function evidenceRound(ev) {
  if (Object.hasOwn(ev, 'round')) return Number.isInteger(ev.round) && ev.round > 0 ? ev.round : null;
  const match = /round-(\d+)\//.exec(String(ev.name || ''));
  return match ? Number(match[1]) : null;
}

function failure(ev) {
  return ev.approved === false || (ev.exit != null && ev.exit !== 0) || ev.tail || /[1-9]\d* 项失败/.test(ev.summary || '');
}

function facts(cur, row, n, sessions, evidence, ret, authoritative) {
  const common = { sessions, evidence, source: '', kind: 'open', tone: 'open', title: '等待控制器结论', why: '' };
  const reviews = reviewAttempts(sessions);
  const latest = reviews.at(-1);
  const activeRound = n != null && n === Math.max(...(cur.rounds || []).map(r => Number(r.round) || 0));
  const status = (activeRound && cur.status) || row?.status;
  const reason = (activeRound && cur.reason) || row?.reason || '';
  if (authoritative && n == null) {
    return { ...common, title: '归属未记录', why: '未找到会话与控制器轮次的关联记录，保留在此供查看。' };
  }
  // An in-progress recheck supersedes historical failures on this same candidate.
  const pendingReview = status === 'reviewing' && (latest?.attemptOutcome === 'running' || !row?.review);
  if (authoritative && activeRound && (['coding', 'checking', 'recovering'].includes(status) || pendingReview)) {
    const title = { coding: '编码中', checking: '检查中', reviewing: 'Review 中', recovering: '诊断中' }[status];
    return { ...common, title, why: status === 'reviewing' ? '以最新审查为准；此前尝试保留在历史记录中。' : '', source: '控制器回执' };
  }
  if (authoritative && (reason.includes('mvp_invalid_review') || latest?.attemptOutcome === 'invalid_review')) {
    return { ...common, kind: 'protocol', tone: 'review', title: '审查协议校验失败',
      why: '审查输出未被控制器接受，不能作为本轮的通过或打回结论。', source: '控制器回执' };
  }
  if (row?.review && typeof row.review.approved === 'boolean') {
    return { ...common, kind: row.review.approved ? 'approved' : 'rejected', tone: row.review.approved ? 'good' : 'review',
      title: row.review.approved ? 'Review 批准' : 'Review 未通过', why: row.review.summary || '', source: '控制器回执' };
  }
  // review.json records an accepted controller result, unlike raw session output.
  const opinion = evidence.filter(ev => typeof ev.approved === 'boolean').at(-1);
  if (opinion) {
    return { ...common, kind: opinion.approved ? 'approved' : 'rejected', tone: opinion.approved ? 'good' : 'review',
      title: opinion.approved ? 'Review 批准' : 'Review 未通过', why: opinion.summary || '', source: '审查证据' };
  }
  // A later accepted attempt must not inherit an earlier failed check from the same round.
  if (authoritative && latest?.attemptOutcome === 'completed') {
    return { ...common, why: '最新审查会话已完成，控制器尚未记录最终结论。', source: '控制器回执' };
  }
  if (ret) {
    return { ...common, kind: 'rejected', tone: ret.kind === 'review' ? 'review' : 'script',
      title: ret.title, why: ret.why || '', source: '检查回执' };
  }
  const failed = evidence.filter(failure).at(-1);
  if (failed) {
    return { ...common, kind: 'rejected', tone: 'script', title: '脚本审查未通过', why: failed.summary || '', source: '检查证据' };
  }
  if (reason && status === 'blocked') {
    return { ...common, title: '本轮受阻', why: reason, source: '控制器回执' };
  }
  if (!authoritative && latest?.verdict) {
    return { ...common, title: 'Review 会话意见（未确认）', why: latest.verdict.summary || '', source: '会话输出' };
  }
  if (n == null) return { ...common, title: '归属未记录', why: '未找到会话与控制器轮次的关联记录，保留在此供查看。' };
  return common;
}

export function roundsModel(cur) {
  const rows = cur?.rounds || [];
  const authoritative = cur?.roundsAuthority ? cur.roundsAuthority === 'controller' : rows.length > 0;
  const numbers = new Set(rows.map(r => r.round).filter(n => Number.isInteger(n) && n > 0));
  const bucketNumber = n => authoritative && !numbers.has(n) ? null : n;
  const buckets = new Map();
  const hasExplicitRound = (cur?.sessions || []).some(s => s.round != null);
  const isSingleControllerRound = authoritative && numbers.size === 1 && !hasExplicitRound;
  const singleRoundNum = isSingleControllerRound ? [...numbers][0] : null;
  let legacyN = 0;
  for (const s of cur?.sessions || []) {
    let n;
    if (authoritative) {
      if (s.round != null) {
        n = bucketNumber(s.round);
      } else if (isSingleControllerRound) {
        n = singleRoundNum;
      } else {
        n = null;
      }
    } else {
      if (s.role === '编码') legacyN += 1;
      n = legacyN || null;
    }
    if (!buckets.has(n)) buckets.set(n, []);
    buckets.get(n).push(s);
  }
  if (!authoritative) {
    for (const n of buckets.keys()) if (n != null) numbers.add(n);
    for (const ev of cur?.evidence || []) if (evidenceRound(ev) != null) numbers.add(evidenceRound(ev));
    for (const ret of cur?.returns || []) if (ret.n != null) numbers.add(ret.n);
  }
  if (buckets.has(null) || (cur?.returns || []).some(r => bucketNumber(r.n ?? null) == null) || (cur?.evidence || []).some(e => bucketNumber(evidenceRound(e)) == null)) numbers.add(null);
  return [...numbers].sort((a, b) => a == null ? 1 : b == null ? -1 : a - b).map(n => {
    const row = rows.find(r => r.round === n);
    const evidence = (cur?.evidence || []).filter(ev => bucketNumber(evidenceRound(ev)) === n);
    const ret = (cur?.returns || []).find(r => bucketNumber(r.n ?? null) === n);
    return { n, ...facts(cur, row, n, buckets.get(n) || [], evidence, ret, authoritative), authoritative };
  });
}
