'use strict';

const test = require('node:test');
const assert = require('node:assert');

const keepaThrottle = require('../src/keepaThrottle');

/** 各テストの前に環境変数を設定してコアを作り直すヘルパ。t.afterで必ず復元する。 */
function configure(t, { refillPerMin, capacity }) {
  const saved = {
    KEEPA_REFILL_PER_MIN: process.env.KEEPA_REFILL_PER_MIN,
    KEEPA_BUCKET_CAPACITY: process.env.KEEPA_BUCKET_CAPACITY,
  };
  if (refillPerMin !== undefined) process.env.KEEPA_REFILL_PER_MIN = String(refillPerMin);
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
  configure(t, { capacity: 2, refillPerMin: 60 });
  assert.deepEqual(await keepaThrottle.acquire('free'), { allowed: true });
  assert.deepEqual(await keepaThrottle.acquire('free'), { allowed: true });
});

test('keepaThrottle: 枯渇していれば即座に reason=exhausted で拒否される(キューに入らない)', async (t) => {
  configure(t, { capacity: 1, refillPerMin: 1 }); // 補充は1分後(間に合わない)
  assert.deepEqual(await keepaThrottle.acquire('free'), { allowed: true });
  const started = Date.now();
  const result = await keepaThrottle.acquire('free');
  assert.deepEqual(result, { allowed: false, reason: 'exhausted' });
  assert.ok(Date.now() - started < 200, `即座に拒否されていない(${Date.now() - started}ms待った)`);
});

test('keepaThrottle: 枯渇時はPro/freeどちらも同じく即座に拒否される(キューが無いので優先度は関係ない)', async (t) => {
  configure(t, { capacity: 1, refillPerMin: 1 });
  await keepaThrottle.acquire('free'); // 枯渇させる
  const [freeResult, proResult] = await Promise.all([
    keepaThrottle.acquire('free'),
    keepaThrottle.acquire('pro'),
  ]);
  assert.deepEqual(freeResult, { allowed: false, reason: 'exhausted' });
  assert.deepEqual(proResult, { allowed: false, reason: 'exhausted' });
});

test('keepaThrottle: reportTokensLeftで推定残量が補正される', async (t) => {
  configure(t, { capacity: 10, refillPerMin: 1 });
  await keepaThrottle.reportTokensLeft(0); // 実残量0と報告
  assert.deepEqual(await keepaThrottle.acquire('free'), { allowed: false, reason: 'exhausted' });
});

test('keepaThrottle: reportExhaustedで残量0になる', async (t) => {
  configure(t, { capacity: 10, refillPerMin: 1 });
  await keepaThrottle.reportExhausted();
  assert.deepEqual(await keepaThrottle.acquire('free'), { allowed: false, reason: 'exhausted' });
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

// ---------------------------------------------------------------------------
// 適応ブレーキ(設計書§2.6): 消費速度監視による予防的な遅延
// ---------------------------------------------------------------------------

/** capacity=100・refillPerMin=60(floor=1000ms)のコアを作り、free acquireをn回消費させる。 */
async function primeConsumption(t, n) {
  configure(t, { capacity: 100, refillPerMin: 60 });
  for (let i = 0; i < n; i += 1) {
    // eslint-disable-next-line no-await-in-loop
    await keepaThrottle.acquire('free');
  }
}

test('keepaThrottle: 適応ブレーキ - 消費履歴が無ければ残量が少なくてもブレーキ0(即時許可)', async (t) => {
  // 消費履歴なし(grantTimestamps空) → rate=0 → net=0-refillPerMin<=0 → ブレーキは常に0。
  // 残量自体は少ない(capacity=2)状態でも即時許可されることを確認する。
  configure(t, { capacity: 2, refillPerMin: 60 });
  const started = Date.now();
  const result = await keepaThrottle.acquire('free');
  assert.deepEqual(result, { allowed: true });
  assert.ok(Date.now() - started < 50, `消費履歴が無いのにブレーキが掛かった(${Date.now() - started}ms)`);
});

test('keepaThrottle: 適応ブレーキ - 消費レート>補充でTTEが安全圏(free=10分)を切ると遅延する', async (t) => {
  // 事前に70回acquireすると rate=70, tokens=30(=100-70), net=70-60=10 → tte=30/10=3分。
  // free の SAFE=10分を下回るため floorMs(1000ms) を上限に線形の遅延が入る:
  // delay = 1000 * (1 - 3/10) = 700ms 程度。
  await primeConsumption(t, 70);
  const started = Date.now();
  const result = await keepaThrottle.acquire('free');
  assert.deepEqual(result, { allowed: true });
  const elapsed = Date.now() - started;
  assert.ok(elapsed >= 300, `freeがブレーキで遅延していない(${elapsed}ms)`);
});

test('keepaThrottle: 適応ブレーキ - 同条件でもProはSAFE圏内(2分)のため遅延しない', async (t) => {
  // 同じtte=3分でも、Proの SAFE=2分より大きいためブレーキは掛からない(Pro優先の維持)。
  await primeConsumption(t, 70);
  const started = Date.now();
  const result = await keepaThrottle.acquire('pro');
  assert.deepEqual(result, { allowed: true });
  assert.ok(Date.now() - started < 50, `Proがブレーキで遅延した(${Date.now() - started}ms)`);
});

test('keepaThrottle: 適応ブレーキ後も残量があれば許可される({allowed:true})', async (t) => {
  await primeConsumption(t, 70);
  const result = await keepaThrottle.acquire('free');
  assert.deepEqual(result, { allowed: true });
});

test('keepaThrottle: 適応ブレーキ - 既定値5/分ではfloorMs(12000ms)がBRAKE_CAP_MSでクランプされる', async (t) => {
  // refillPerMin=5だと素のfloorMs(60000/5=12000ms)はBRAKE_CAP_MS(4000ms)を大きく超える。
  // cap=min(floorMs, BRAKE_CAP_MS)によってブレーキが最大でも4000ms近辺でクランプされることを確認する。
  const { ThrottleCore } = keepaThrottle;
  const core = new ThrottleCore({ refillPerMin: 5, capacity: 100 });
  t.after(() => core.destroy());

  const now = Date.now();
  core.tokens = 5;
  core.lastRefillAt = now;
  for (let i = 0; i < 55; i += 1) core.grantTimestamps.push(now); // 高消費状態を再現(rate=55, net=50, tte=0.1分)

  const started = Date.now();
  const result = await core.acquire('free');
  const elapsed = Date.now() - started;

  assert.deepEqual(result, { allowed: true });
  assert.ok(elapsed >= 3000, `クランプが効きすぎて即時許可された(${elapsed}ms)`);
  assert.ok(elapsed < 4500, `BRAKE_CAP_MS(4000ms)を大きく超えて待たされた(${elapsed}ms)`);
});

// ---------------------------------------------------------------------------
// デモモード: seedDemoState + マルチインスタンス分離('demo'は'global'に影響しない)
// ---------------------------------------------------------------------------

test('ThrottleCore.seedDemoState: tokensのみ指定するとtokensだけ変わりgrantTimestampsは変わらない', () => {
  const { ThrottleCore } = keepaThrottle;
  const core = new ThrottleCore({ refillPerMin: 60, capacity: 100 });
  core.grantTimestamps = [1, 2, 3];
  core.seedDemoState({ tokens: 7 });
  assert.equal(core.tokens, 7);
  assert.deepEqual(core.grantTimestamps, [1, 2, 3]);
  core.destroy();
});

test('ThrottleCore.seedDemoState: ratePerMinのみ指定するとgrantTimestampsだけ変わりtokensは変わらない', () => {
  const { ThrottleCore } = keepaThrottle;
  const core = new ThrottleCore({ refillPerMin: 60, capacity: 100 });
  core.tokens = 42;
  core.seedDemoState({ ratePerMin: 5 });
  assert.equal(core.tokens, 42);
  assert.equal(core.grantTimestamps.length, 5);
  core.destroy();
});

test('ThrottleCore.seedDemoState: tokens・ratePerMinを両方指定すると両方反映される', () => {
  const { ThrottleCore } = keepaThrottle;
  const core = new ThrottleCore({ refillPerMin: 60, capacity: 100 });
  core.seedDemoState({ tokens: 3, ratePerMin: 8 });
  assert.equal(core.tokens, 3);
  assert.equal(core.grantTimestamps.length, 8);
  core.destroy();
});

test('ThrottleCore.seedDemoState: どちらも未指定ならtokens/grantTimestampsは変わらない(refillPerMinは常に0固定される)', () => {
  const { ThrottleCore } = keepaThrottle;
  const core = new ThrottleCore({ refillPerMin: 60, capacity: 100 });
  core.tokens = 10;
  core.grantTimestamps = [1, 2];
  core.seedDemoState({});
  assert.equal(core.tokens, 10);
  assert.deepEqual(core.grantTimestamps, [1, 2]);
  assert.equal(core.config.refillPerMin, 0);
  core.destroy();
});

test('ThrottleCore.seedDemoState: 呼ぶとrefillPerMinが0になり、時間が経ってもtokensが自然回復しない', () => {
  const { ThrottleCore } = keepaThrottle;
  const core = new ThrottleCore({ refillPerMin: 60, capacity: 100 });
  core.seedDemoState({ tokens: 0 });
  // refillPerMin=60(1秒に1個)なら本来なら数十ms後には回復し得るが、
  // refillPerMinが0に固定されているため、未来の時刻を渡しても残量は0のまま。
  const farFuture = Date.now() + 5 * 60 * 1000; // 5分後
  assert.equal(core.peekTokens(farFuture), 0);
  core.destroy();
});

test('ThrottleCore.seedDemoState: refillPerMinを明示指定すると、その値で補充が進む(時間経過でトークンが実際に増える)', () => {
  const { ThrottleCore } = keepaThrottle;
  const core = new ThrottleCore({ refillPerMin: 60, capacity: 100 });
  core.seedDemoState({ tokens: 0, refillPerMin: 30 }); // 1秒に0.5個 = 2秒で1個
  assert.equal(core.config.refillPerMin, 30);
  const twoSecondsLater = Date.now() + 2000;
  assert.equal(core.peekTokens(twoSecondsLater), 1, '明示指定したrefillPerMinで補充が進んでいない');
  core.destroy();
});

test('ThrottleCore.seedDemoState: refillPerMin未指定なら従来通り0固定される(自然回復しない)', () => {
  const { ThrottleCore } = keepaThrottle;
  const core = new ThrottleCore({ refillPerMin: 60, capacity: 100 });
  core.seedDemoState({ tokens: 0 });
  assert.equal(core.config.refillPerMin, 0);
  const farFuture = Date.now() + 5 * 60 * 1000;
  assert.equal(core.peekTokens(farFuture), 0);
  core.destroy();
});

test('ThrottleCore.seedDemoState: refillPerMinに負値を渡しても0固定にフォールバックする', () => {
  const { ThrottleCore } = keepaThrottle;
  const core = new ThrottleCore({ refillPerMin: 60, capacity: 100 });
  core.seedDemoState({ tokens: 0, refillPerMin: -5 });
  assert.equal(core.config.refillPerMin, 0);
  core.destroy();
});

test('keepaThrottle: instance="demo"へのseedDemoStateはinstance省略(=global)に影響しない', async (t) => {
  configure(t, { capacity: 10, refillPerMin: 60 });
  // demoだけ残量0にする
  await keepaThrottle.seedDemoState({ tokens: 0 });
  // globalはconfigureで作った満タン状態のまま → 即時許可されるはず
  assert.deepEqual(await keepaThrottle.acquire('free'), { allowed: true });
});

test('keepaThrottle: acquire(priority, "demo")はacquire(priority)(=global省略時)と別状態', async (t) => {
  configure(t, { capacity: 1, refillPerMin: 60 });
  // demoインスタンスを枯渇させる
  assert.deepEqual(await keepaThrottle.acquire('free', 'demo'), { allowed: true });
  assert.deepEqual(await keepaThrottle.acquire('free', 'demo'), { allowed: false, reason: 'exhausted' });
  // globalは影響を受けず、まだ残量があるので許可される
  assert.deepEqual(await keepaThrottle.acquire('free'), { allowed: true });
});
