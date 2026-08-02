'use strict';

const test = require('node:test');
const assert = require('node:assert');

const keepaThrottle = require('../src/keepaThrottle');

/** 各テストの前に環境変数を設定してコアを作り直すヘルパ。t.afterで必ず復元する。 */
function configure(t, { refillPerMin, depth, timeoutMs, capacity }) {
  const saved = {
    KEEPA_REFILL_PER_MIN: process.env.KEEPA_REFILL_PER_MIN,
    KEEPA_QUEUE_DEPTH: process.env.KEEPA_QUEUE_DEPTH,
    KEEPA_QUEUE_TIMEOUT_MS: process.env.KEEPA_QUEUE_TIMEOUT_MS,
    KEEPA_BUCKET_CAPACITY: process.env.KEEPA_BUCKET_CAPACITY,
  };
  if (refillPerMin !== undefined) process.env.KEEPA_REFILL_PER_MIN = String(refillPerMin);
  if (depth !== undefined) process.env.KEEPA_QUEUE_DEPTH = String(depth);
  if (timeoutMs !== undefined) process.env.KEEPA_QUEUE_TIMEOUT_MS = String(timeoutMs);
  if (capacity !== undefined) process.env.KEEPA_BUCKET_CAPACITY = String(capacity);
  keepaThrottle._resetForTest();
  t.after(() => {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
    keepaThrottle._resetForTest();
  });
}

test('keepaThrottle: 残量がある間は即時allowed', async (t) => {
  configure(t, { capacity: 2, refillPerMin: 60, depth: 10, timeoutMs: 1000 });
  assert.deepEqual(await keepaThrottle.acquire('free'), { allowed: true });
  assert.deepEqual(await keepaThrottle.acquire('free'), { allowed: true });
});

test('keepaThrottle: 枯渇するとキューに入り、補充で順に許可される', async (t) => {
  // capacity=1: 1件目で枯渇。refillPerMin=600 → 100msに1トークン補充。
  configure(t, { capacity: 1, refillPerMin: 600, depth: 10, timeoutMs: 5000 });
  assert.deepEqual(await keepaThrottle.acquire('free'), { allowed: true });
  const started = Date.now();
  const result = await keepaThrottle.acquire('free');
  assert.deepEqual(result, { allowed: true });
  // 即時ではなく補充を待ったこと(≒100ms)を確認。CIの揺らぎを見て50ms以上とする。
  assert.ok(Date.now() - started >= 50, '補充を待たずに許可された');
});

test('keepaThrottle: キュー内ではProがfreeより先に許可される', async (t) => {
  configure(t, { capacity: 1, refillPerMin: 600, depth: 10, timeoutMs: 5000 });
  await keepaThrottle.acquire('free'); // 枯渇させる
  const order = [];
  const freeWaiter = keepaThrottle.acquire('free').then(() => order.push('free'));
  const proWaiter = keepaThrottle.acquire('pro').then(() => order.push('pro'));
  await Promise.all([freeWaiter, proWaiter]);
  assert.deepEqual(order, ['pro', 'free']);
});

test('keepaThrottle: キュー深さ超過は即時 reason=depth で拒否', async (t) => {
  configure(t, { capacity: 1, refillPerMin: 1, depth: 1, timeoutMs: 60000 });
  await keepaThrottle.acquire('free'); // 枯渇
  const queued = keepaThrottle.acquire('free'); // depth 1/1 を占有(補充は1分後なので待ち続ける)
  const rejected = await keepaThrottle.acquire('free'); // 満杯 → 即拒否
  assert.deepEqual(rejected, { allowed: false, reason: 'depth' });
  keepaThrottle._resetForTest(); // queuedを破棄(テストをぶら下げない)
  await queued; // resetで解決される(allowed:falseでよい)
});

test('keepaThrottle: 待ちがtimeoutMsを超えると reason=timeout で拒否', async (t) => {
  configure(t, { capacity: 1, refillPerMin: 1, depth: 10, timeoutMs: 100 });
  await keepaThrottle.acquire('free'); // 枯渇(補充は1分後=間に合わない)
  const started = Date.now();
  const result = await keepaThrottle.acquire('free');
  assert.deepEqual(result, { allowed: false, reason: 'timeout' });
  assert.ok(Date.now() - started >= 90, 'タイムアウトまで待っていない');
});

test('keepaThrottle: reportTokensLeftで推定残量が補正される', async (t) => {
  configure(t, { capacity: 10, refillPerMin: 1, depth: 0, timeoutMs: 100 });
  await keepaThrottle.reportTokensLeft(0); // 実残量0と報告
  // depth=0なのでキューに入れず即拒否になる=残量0が反映されている証拠
  assert.deepEqual(await keepaThrottle.acquire('free'), { allowed: false, reason: 'depth' });
});

test('keepaThrottle: reportExhaustedで残量0になる', async (t) => {
  configure(t, { capacity: 10, refillPerMin: 1, depth: 0, timeoutMs: 100 });
  await keepaThrottle.reportExhausted();
  assert.deepEqual(await keepaThrottle.acquire('free'), { allowed: false, reason: 'depth' });
});

test('keepaThrottle: DO経路はbindingのfetchへ委譲する', async (t) => {
  const calls = [];
  const binding = {
    idFromName: (name) => ({ name }),
    get: () => ({
      fetch: async (url) => {
        calls.push(url);
        return new Response(JSON.stringify({ allowed: true }), { status: 200 });
      },
    }),
  };
  keepaThrottle._setDurableBinding(binding);
  t.after(() => keepaThrottle._setDurableBinding(undefined));
  assert.deepEqual(await keepaThrottle.acquire('pro'), { allowed: true });
  assert.ok(calls[0].includes('/acquire') && calls[0].includes('priority=pro'));
});

test('keepaThrottle: DO障害時はallowed:trueで倒す(可用性優先)', async (t) => {
  const binding = {
    idFromName: (name) => ({ name }),
    get: () => ({ fetch: async () => { throw new Error('DO unreachable'); } }),
  };
  keepaThrottle._setDurableBinding(binding);
  t.after(() => keepaThrottle._setDurableBinding(undefined));
  const result = await keepaThrottle.acquire('free');
  assert.equal(result.allowed, true);
});
