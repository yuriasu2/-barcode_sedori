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

// ---------------------------------------------------------------------------
// 最終レビュー指摘の修正(2): 残量補正時にキューを流す + 新参の追い越し防止
// ---------------------------------------------------------------------------

test('keepaThrottle: reportTokensLeftの上方補正で古いgrantTimerに引きずられず即座にキューが流れる', async (t) => {
  // capacity=1・refillPerMin=30 → 自然補充なら1トークンに2000ms(60000/30)かかる想定。
  // 待機者を積んだ時点でその2000ms後にgrantTimerが予約されるが、
  // reportTokensLeftで残量が上方補正されたら古い予約を待たずに即時許可されるべき。
  configure(t, { capacity: 1, refillPerMin: 30, depth: 10, timeoutMs: 5000 });
  await keepaThrottle.acquire('free'); // 枯渇させる(tokens=0)
  const waiterPromise = keepaThrottle.acquire('free'); // キューへ。約2000ms後のgrantTimerが予約される
  await new Promise((r) => setTimeout(r, 20)); // waiterが確実にキューに入るのを待つ

  const started = Date.now();
  await keepaThrottle.reportTokensLeft(5); // 実残量5と判明(上方補正)
  const result = await waiterPromise;

  assert.deepEqual(result, { allowed: true });
  assert.ok(
    Date.now() - started < 500,
    `補正から${Date.now() - started}ms経っても即時に流れていない(古いgrantTimerの待ち時間に引きずられている)`
  );
});

// ---------------------------------------------------------------------------
// 適応ブレーキ(設計書§2.6): 消費速度監視による予防的な遅延
// ---------------------------------------------------------------------------

/** capacity=100・refillPerMin=60(floor=1000ms)のコアを作り、free acquireをn回消費させる。 */
async function primeConsumption(t, n) {
  configure(t, { capacity: 100, refillPerMin: 60, depth: 50, timeoutMs: 8000 });
  for (let i = 0; i < n; i += 1) {
    // eslint-disable-next-line no-await-in-loop
    await keepaThrottle.acquire('free');
  }
}

test('keepaThrottle: 適応ブレーキ - 消費履歴が無ければ残量が少なくてもブレーキ0(即時許可)', async (t) => {
  // 消費履歴なし(grantTimestamps空) → rate=0 → net=0-refillPerMin<=0 → ブレーキは常に0。
  // 残量自体は少ない(capacity=2)状態でも即時許可されることを確認する。
  configure(t, { capacity: 2, refillPerMin: 60, depth: 10, timeoutMs: 5000 });
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

test('keepaThrottle: 適応ブレーキ - 既定値5/分ではfloorMs(12000ms)がtimeoutMs-1秒でクランプされる', async (t) => {
  // 現行本番値のrefillPerMin=5だと素のfloorMs(60000/5=12000ms)は、既定timeoutMs(8000ms)は
  // おろかこのテスト用timeoutMs=2000msも大きく超える。cap=min(floorMs, timeoutMs-1000)に
  // よってブレーキが最大でも(timeoutMs-1000)=1000ms近辺でクランプされることを確認する。
  //
  // ThrottleCoreを直接操作するホワイトボックステスト(高消費状態を作るのに実際に
  // acquireをループで70回以上回すと、rateがrefillPerMin=5を超えた時点からループ自体にも
  // ブレーキが掛かり始め、cap=1000ms級の遅延が数十回積み重なって検証に何十秒もかかって
  // しまう。既存の「残量補正直後の新参acquire」テストと同じ作法でgrantTimestamps/tokensを
  // 直接セットし、高消費状態を一瞬で再現する)。
  const { ThrottleCore } = keepaThrottle;
  const core = new ThrottleCore({ refillPerMin: 5, capacity: 100, depth: 50, timeoutMs: 2000 });
  t.after(() => core.destroy());

  // 直近60秒に55回grantされ、残量5という高消費状態を再現(rate=55, net=50, tte=5/50=0.1分)。
  const now = Date.now();
  core.tokens = 5;
  core.lastRefillAt = now;
  for (let i = 0; i < 55; i += 1) core.grantTimestamps.push(now);

  const started = Date.now();
  const result = await core.acquire('free');
  const elapsed = Date.now() - started;

  assert.deepEqual(result, { allowed: true });
  assert.ok(elapsed >= 500, `クランプが効きすぎて即時許可された(${elapsed}ms)`);
  assert.ok(elapsed < 2000, `テスト用timeoutMs(2000ms)未満で返っていない(${elapsed}ms)`);
});

// ---------------------------------------------------------------------------
// デモモード: seedDemoState + マルチインスタンス分離('demo'は'global'に影響しない)
// ---------------------------------------------------------------------------

test('ThrottleCore.seedDemoState: tokensのみ指定するとtokensだけ変わりgrantTimestampsは変わらない', () => {
  const { ThrottleCore } = keepaThrottle;
  const core = new ThrottleCore({ refillPerMin: 60, capacity: 100, depth: 10, timeoutMs: 1000 });
  core.grantTimestamps = [1, 2, 3];
  core.seedDemoState({ tokens: 7 });
  assert.equal(core.tokens, 7);
  assert.deepEqual(core.grantTimestamps, [1, 2, 3]);
  core.destroy();
});

test('ThrottleCore.seedDemoState: ratePerMinのみ指定するとgrantTimestampsだけ変わりtokensは変わらない', () => {
  const { ThrottleCore } = keepaThrottle;
  const core = new ThrottleCore({ refillPerMin: 60, capacity: 100, depth: 10, timeoutMs: 1000 });
  core.tokens = 42;
  core.seedDemoState({ ratePerMin: 5 });
  assert.equal(core.tokens, 42);
  assert.equal(core.grantTimestamps.length, 5);
  core.destroy();
});

test('ThrottleCore.seedDemoState: tokens・ratePerMinを両方指定すると両方反映される', () => {
  const { ThrottleCore } = keepaThrottle;
  const core = new ThrottleCore({ refillPerMin: 60, capacity: 100, depth: 10, timeoutMs: 1000 });
  core.seedDemoState({ tokens: 3, ratePerMin: 8 });
  assert.equal(core.tokens, 3);
  assert.equal(core.grantTimestamps.length, 8);
  core.destroy();
});

test('ThrottleCore.seedDemoState: どちらも未指定ならtokens/grantTimestampsは変わらない(refillPerMinは常に0固定される)', () => {
  const { ThrottleCore } = keepaThrottle;
  const core = new ThrottleCore({ refillPerMin: 60, capacity: 100, depth: 10, timeoutMs: 1000 });
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
  const core = new ThrottleCore({ refillPerMin: 60, capacity: 100, depth: 10, timeoutMs: 1000 });
  core.seedDemoState({ tokens: 0 });
  // refillPerMin=60(1秒に1個)なら本来なら数十ms後には回復し得るが、
  // refillPerMinが0に固定されているため、未来の時刻を渡しても残量は0のまま。
  const farFuture = Date.now() + 5 * 60 * 1000; // 5分後
  assert.equal(core.peekTokens(farFuture), 0);
  core.destroy();
});

test('ThrottleCore.seedDemoState: refillPerMinを明示指定すると、その値で補充が進む(時間経過でトークンが実際に増える)', () => {
  const { ThrottleCore } = keepaThrottle;
  const core = new ThrottleCore({ refillPerMin: 60, capacity: 100, depth: 10, timeoutMs: 1000 });
  core.seedDemoState({ tokens: 0, refillPerMin: 30 }); // 1秒に0.5個 = 2秒で1個
  assert.equal(core.config.refillPerMin, 30);
  const twoSecondsLater = Date.now() + 2000;
  assert.equal(core.peekTokens(twoSecondsLater), 1, '明示指定したrefillPerMinで補充が進んでいない');
  core.destroy();
});

test('ThrottleCore.seedDemoState: refillPerMin未指定なら従来通り0固定される(自然回復しない)', () => {
  const { ThrottleCore } = keepaThrottle;
  const core = new ThrottleCore({ refillPerMin: 60, capacity: 100, depth: 10, timeoutMs: 1000 });
  core.seedDemoState({ tokens: 0 });
  assert.equal(core.config.refillPerMin, 0);
  const farFuture = Date.now() + 5 * 60 * 1000;
  assert.equal(core.peekTokens(farFuture), 0);
  core.destroy();
});

test('ThrottleCore.seedDemoState: refillPerMinに負値を渡しても0固定にフォールバックする', () => {
  const { ThrottleCore } = keepaThrottle;
  const core = new ThrottleCore({ refillPerMin: 60, capacity: 100, depth: 10, timeoutMs: 1000 });
  core.seedDemoState({ tokens: 0, refillPerMin: -5 });
  assert.equal(core.config.refillPerMin, 0);
  core.destroy();
});

test('keepaThrottle: instance="demo"へのseedDemoStateはinstance省略(=global)に影響しない', async (t) => {
  configure(t, { capacity: 10, refillPerMin: 60, depth: 0, timeoutMs: 1000 });
  // demoだけ残量0にする
  await keepaThrottle.seedDemoState({ tokens: 0 });
  // globalはconfigureで作った満タン状態のまま → 即時許可されるはず
  assert.deepEqual(await keepaThrottle.acquire('free'), { allowed: true });
});

test('keepaThrottle: acquire(priority, "demo")はacquire(priority)(=global省略時)と別状態', async (t) => {
  configure(t, { capacity: 1, refillPerMin: 60, depth: 0, timeoutMs: 1000 });
  // demoインスタンスを枯渇させる
  assert.deepEqual(await keepaThrottle.acquire('free', 'demo'), { allowed: true });
  assert.deepEqual(await keepaThrottle.acquire('free', 'demo'), { allowed: false, reason: 'depth' });
  // globalは影響を受けず、まだ残量があるので許可される
  assert.deepEqual(await keepaThrottle.acquire('free'), { allowed: true });
});

test('keepaThrottle: 残量補正直後の新参acquireは、キュー内の待機者を追い越して即時許可されない', async (t) => {
  // ThrottleCoreを直接操作するホワイトボックステスト。
  // refillPerMin=1・待機者を積んでから外部要因(reportTokensLeft等)でトークンが1個
  // 補充されたのと同じ状況を再現し、その直後に新参がacquireした場合の挙動を見る。
  const { ThrottleCore } = keepaThrottle;
  const core = new ThrottleCore({ refillPerMin: 1, capacity: 5, depth: 10, timeoutMs: 200 });
  t.after(() => core.destroy());

  core.tokens = 0;
  const proWaiterPromise = core.acquire('pro');
  await new Promise((r) => setTimeout(r, 10)); // proが確実にキューに入るのを待つ
  assert.equal(core.queueLength(), 1);

  // 補正でトークンが1個入ったのと同じ状況(grantTickを経由しない直接更新)を再現。
  core.tokens = 1;

  const freeResult = await core.acquire('free');
  // 新参(free)がキュー内で待っているpro(優先度が上)を追い越して許可されてはいけない。
  assert.notDeepEqual(freeResult, { allowed: true });

  const proResult = await proWaiterPromise;
  assert.deepEqual(proResult, { allowed: true });
});
