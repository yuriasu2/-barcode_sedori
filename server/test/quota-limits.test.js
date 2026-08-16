'use strict';

/**
 * quotaLimits.js(無料枠3設定のKV読み出し)のテスト。
 * KVモックとglobalThis.__adsKvの差し替え方はnotice.test.jsに合わせている
 * (同じADS_CONFIG namespaceを別キーで使うため)。
 */

const test = require('node:test');
const assert = require('node:assert/strict');

const quotaLimits = require('../src/quotaLimits');
const deviceQuota = require('../src/deviceQuota');
const routes = require('../src/routes');

/** globalThis.__adsKv に差し込むモックKV。get呼び出しを記録する。 */
function createMockKv(store = {}) {
  const data = new Map(Object.entries(store));
  return {
    getCalls: [],
    async get(key) {
      this.getCalls.push(key);
      return data.has(key) ? data.get(key) : null;
    },
    async put(key, value) {
      data.set(key, value);
    },
  };
}

/** KVを差し込んで実行し、必ず元へ戻す。キャッシュも前後でクリアする(テスト間の汚染防止)。 */
function withAdsKv(kv, fn) {
  const saved = globalThis.__adsKv;
  globalThis.__adsKv = kv;
  quotaLimits._resetCache();
  return Promise.resolve()
    .then(fn)
    .finally(() => {
      globalThis.__adsKv = saved;
      quotaLimits._resetCache();
    });
}

function createMockRes() {
  return {
    statusCode: 200,
    body: undefined,
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(body) {
      this.body = body;
      return this;
    },
  };
}

const VALID = { baseDailyUnits: 3, unitsPerAd: 10, maxDailyUnits: 50 };
// 環境変数が未設定のテスト環境での既定値(wrangler.jsonc の vars と同じ)。
const ENV_DEFAULT = { base: 5, perAd: 5, max: 100 };

// ---------------------------------------------------------------------------
// フォールバック
// ---------------------------------------------------------------------------

test('loadLimits: KV未設定(バインディングなし)なら環境変数(既定値)へフォールバック', async () => {
  await withAdsKv(null, async () => {
    assert.deepEqual(await quotaLimits.loadLimits(), ENV_DEFAULT);
  });
});

test('loadLimits: キーが無ければ環境変数へフォールバック', async () => {
  const kv = createMockKv({});
  await withAdsKv(kv, async () => {
    assert.deepEqual(await quotaLimits.loadLimits(), ENV_DEFAULT);
    assert.deepEqual(kv.getCalls, ['quota-limits']);
  });
});

test('loadLimits: JSONが壊れていれば環境変数へフォールバック', async () => {
  await withAdsKv(createMockKv({ 'quota-limits': '{壊れたJSON' }), async () => {
    assert.deepEqual(await quotaLimits.loadLimits(), ENV_DEFAULT);
  });
});

// ---------------------------------------------------------------------------
// 正常系
// ---------------------------------------------------------------------------

test('loadLimits: KVの値が反映される', async () => {
  await withAdsKv(createMockKv({ 'quota-limits': JSON.stringify(VALID) }), async () => {
    assert.deepEqual(await quotaLimits.loadLimits(), { base: 3, perAd: 10, max: 50 });
  });
});

test('loadLimits: baseDailyUnits=0(広告を見ないと使えない設定)は有効', async () => {
  const json = JSON.stringify({ baseDailyUnits: 0, unitsPerAd: 5, maxDailyUnits: 100 });
  await withAdsKv(createMockKv({ 'quota-limits': json }), async () => {
    assert.deepEqual(await quotaLimits.loadLimits(), { base: 0, perAd: 5, max: 100 });
  });
});

test('loadLimits: base === max(広告で増やせない設定)は有効', async () => {
  const json = JSON.stringify({ baseDailyUnits: 20, unitsPerAd: 5, maxDailyUnits: 20 });
  await withAdsKv(createMockKv({ 'quota-limits': json }), async () => {
    assert.deepEqual(await quotaLimits.loadLimits(), { base: 20, perAd: 5, max: 20 });
  });
});

// ---------------------------------------------------------------------------
// バリデーション(1項目でも不正なら全項目フォールバック)
// ---------------------------------------------------------------------------

const INVALID_CASES = [
  ['baseが負数', { baseDailyUnits: -1, unitsPerAd: 5, maxDailyUnits: 100 }],
  ['unitsPerAdが0', { baseDailyUnits: 5, unitsPerAd: 0, maxDailyUnits: 100 }],
  ['unitsPerAdが負数', { baseDailyUnits: 5, unitsPerAd: -5, maxDailyUnits: 100 }],
  ['maxDailyUnitsが0', { baseDailyUnits: 5, unitsPerAd: 5, maxDailyUnits: 0 }],
  ['文字列', { baseDailyUnits: '5', unitsPerAd: 5, maxDailyUnits: 100 }],
  ['小数', { baseDailyUnits: 5.5, unitsPerAd: 5, maxDailyUnits: 100 }],
  ['null', { baseDailyUnits: null, unitsPerAd: 5, maxDailyUnits: 100 }],
  ['項目欠落', { unitsPerAd: 5, maxDailyUnits: 100 }],
  ['max < base', { baseDailyUnits: 50, unitsPerAd: 5, maxDailyUnits: 10 }],
  ['baseが上限超過', { baseDailyUnits: 1001, unitsPerAd: 5, maxDailyUnits: 5000 }],
  ['maxが上限超過', { baseDailyUnits: 5, unitsPerAd: 5, maxDailyUnits: 10001 }],
  ['オブジェクトでない(配列)', []],
  ['オブジェクトでない(数値)', 42],
];

for (const [label, payload] of INVALID_CASES) {
  test(`loadLimits: 不正値(${label})は全項目フォールバックする`, async () => {
    await withAdsKv(createMockKv({ 'quota-limits': JSON.stringify(payload) }), async () => {
      assert.deepEqual(await quotaLimits.loadLimits(), ENV_DEFAULT);
    });
  });
}

test('validateLimits: 1項目でも不正なら他の項目も採用しない(部分適用しない)', () => {
  // unitsPerAdだけ不正。baseとmaxは妥当だが、nullを返して全体を無効にする。
  assert.equal(quotaLimits.validateLimits({ baseDailyUnits: 3, unitsPerAd: 0, maxDailyUnits: 50 }), null);
});

// ---------------------------------------------------------------------------
// キャッシュ
// ---------------------------------------------------------------------------

test('loadLimits: 60秒キャッシュが効き、KV読み取りは1回だけ', async () => {
  const kv = createMockKv({ 'quota-limits': JSON.stringify(VALID) });
  await withAdsKv(kv, async () => {
    const a = await quotaLimits.loadLimits();
    const b = await quotaLimits.loadLimits();
    const c = await quotaLimits.loadLimits();
    assert.deepEqual(a, { base: 3, perAd: 10, max: 50 });
    assert.deepEqual(b, a);
    assert.deepEqual(c, a);
    assert.equal(kv.getCalls.length, 1, 'KVは1回しか読まないはず');
  });
});

test('loadLimits: KV未設定でもキャッシュされ、毎回envを読み直さない', async () => {
  const kv = createMockKv({});
  await withAdsKv(kv, async () => {
    await quotaLimits.loadLimits();
    await quotaLimits.loadLimits();
    assert.equal(kv.getCalls.length, 1);
  });
});

// ---------------------------------------------------------------------------
// deviceQuota(インメモリ経路)への反映
// ---------------------------------------------------------------------------

test('deviceQuota: KVの設定が消費・広告付与に反映される', async () => {
  const json = JSON.stringify({ baseDailyUnits: 2, unitsPerAd: 3, maxDailyUnits: 8 });
  await withAdsKv(createMockKv({ 'quota-limits': json }), async () => {
    deviceQuota._reset();
    const id = 'dev-kv';

    assert.equal((await deviceQuota.tryConsume(id, 1)).allowed, true);
    const second = await deviceQuota.tryConsume(id, 1);
    assert.equal(second.allowed, true);
    assert.equal(second.quota.limit, 2, 'baseDailyUnits=2がlimitになる');
    assert.equal((await deviceQuota.tryConsume(id, 1)).allowed, false, '基本枠2を超えたら拒否');

    const grant = await deviceQuota.grantAd(id);
    assert.equal(grant.granted, true);
    assert.equal(grant.quota.limit, 5, '2 + 3(unitsPerAd)= 5');
  });
  deviceQuota._reset();
});

// ---------------------------------------------------------------------------
// /api/quota 応答
// ---------------------------------------------------------------------------

test('/api/quota: 応答に現在の設定値(limits)が含まれる', async () => {
  const json = JSON.stringify(VALID);
  await withAdsKv(createMockKv({ 'quota-limits': json }), async () => {
    deviceQuota._reset();
    const res = createMockRes();
    const route = routes.match('GET', '/api/quota');
    await route.handler({ query: {}, headers: { 'x-device-id': 'dev-quota-limits' } }, res);

    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.body.limits, { baseDailyUnits: 3, unitsPerAd: 10, maxDailyUnits: 50 });
    // 既存フィールドを壊していないこと
    assert.equal(res.body.limit, 3);
    assert.equal(res.body.unitsRemaining, 3);
    assert.equal(res.body.unitsUsed, 0);
  });
  deviceQuota._reset();
});

test('/api/quota: KV未設定でもlimitsは既定値で含まれる', async () => {
  await withAdsKv(null, async () => {
    deviceQuota._reset();
    const res = createMockRes();
    const route = routes.match('GET', '/api/quota');
    await route.handler({ query: {}, headers: { 'x-device-id': 'dev-quota-default' } }, res);

    assert.deepEqual(res.body.limits, { baseDailyUnits: 5, unitsPerAd: 5, maxDailyUnits: 100 });
  });
  deviceQuota._reset();
});
