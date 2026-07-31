'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const deviceQuota = require('../src/deviceQuota');

// ---------------------------------------------------------------------------
// deviceQuota.js 単体テスト(既定値: BASE_DAILY_UNITS=5, UNITS_PER_AD=5, MAX_DAILY_UNITS=100)
// ---------------------------------------------------------------------------

test('tryConsume: 基本枠5まで消費でき、6回目はallowed=false。quotaの各フィールドが期待値', () => {
  deviceQuota._reset();
  const id = 'dev-A';

  for (let i = 1; i <= 5; i += 1) {
    const result = deviceQuota.tryConsume(id, 1);
    assert.equal(result.allowed, true, `${i}回目は許可されるはず`);
    assert.equal(result.quota.unitsUsed, i);
    assert.equal(result.quota.limit, 5);
    assert.equal(result.quota.unitsRemaining, 5 - i);
    assert.equal(result.quota.baseRemaining, 5 - i);
    assert.equal(result.quota.adGrantsToday, 0);
    assert.equal(result.quota.capReached, false);
    assert.equal(result.quota.adAvailable, true);
  }

  const sixth = deviceQuota.tryConsume(id, 1);
  assert.equal(sixth.allowed, false);
  assert.deepEqual(sixth.quota, {
    unitsRemaining: 0,
    baseRemaining: 0,
    unitsUsed: 5,
    adGrantsToday: 0,
    adAvailable: true,
    capReached: false,
    limit: 5,
  });
});

test('tryConsume: deviceId空/未指定は常にallowed=true・消費なし・quotaは{unlimited:true}', () => {
  deviceQuota._reset();
  assert.deepEqual(deviceQuota.tryConsume(null, 1), { allowed: true, quota: { unlimited: true } });
  assert.deepEqual(deviceQuota.tryConsume(undefined, 1), { allowed: true, quota: { unlimited: true } });
  assert.deepEqual(deviceQuota.tryConsume('', 1), { allowed: true, quota: { unlimited: true } });
  // 消費されていないことを確認(登録すらされない)
  assert.equal(deviceQuota._entries.size, 0);
});

test('grantAd: 1本でlimitが10になり、さらに消費できる', () => {
  deviceQuota._reset();
  const id = 'dev-B';

  const grant = deviceQuota.grantAd(id);
  assert.equal(grant.granted, true);
  assert.equal(grant.quota.adGrantsToday, 1);
  assert.equal(grant.quota.limit, 10);
  assert.equal(grant.quota.unitsRemaining, 10);

  // 基本枠5を使い切った後でも、広告分の5(合計10)まで消費できる。
  for (let i = 1; i <= 5; i += 1) {
    const r = deviceQuota.tryConsume(id, 1);
    assert.equal(r.allowed, true, `基本枠消費 ${i}回目`);
  }
  for (let i = 6; i <= 10; i += 1) {
    const r = deviceQuota.tryConsume(id, 1);
    assert.equal(r.allowed, true, `広告分消費 ${i}回目`);
  }
  const eleventh = deviceQuota.tryConsume(id, 1);
  assert.equal(eleventh.allowed, false);
});

test('grantAd: cap(100)到達後はgranted=falseでadGrantsが増えない(19本でcap、20本目はfalse)', () => {
  deviceQuota._reset();
  const id = 'dev-C';

  let lastQuota = null;
  for (let i = 1; i <= 19; i += 1) {
    const r = deviceQuota.grantAd(id);
    assert.equal(r.granted, true, `${i}本目は許可されるはず`);
    lastQuota = r.quota;
  }
  // 19本目でlimitが100(cap)に到達する: 5 + 5*19 = 100
  assert.equal(lastQuota.limit, 100);
  assert.equal(lastQuota.capReached, true);
  assert.equal(lastQuota.adAvailable, false);
  assert.equal(lastQuota.adGrantsToday, 19);

  const twentieth = deviceQuota.grantAd(id);
  assert.equal(twentieth.granted, false);
  assert.equal(twentieth.quota.adGrantsToday, 19); // 増えない
  assert.equal(deviceQuota.getState(id).adGrants, 19);
});

test('日付が変わるとunitsUsedもadGrantsもリセットされる', () => {
  deviceQuota._reset();
  const id = 'dev-D';

  deviceQuota.tryConsume(id, 3);
  deviceQuota.grantAd(id);
  assert.deepEqual(deviceQuota.getState(id), { unitsUsed: 3, adGrants: 1 });

  // 内部の日付を過去日に書き換え、翌日をシミュレート
  deviceQuota._entries.set(id, { date: '2000-1-1', unitsUsed: 3, adGrants: 1 });
  assert.deepEqual(deviceQuota.getState(id), { unitsUsed: 0, adGrants: 0 });

  const result = deviceQuota.tryConsume(id, 1);
  assert.equal(result.allowed, true);
  assert.equal(result.quota.unitsUsed, 1);
  assert.equal(result.quota.adGrantsToday, 0);
  assert.equal(result.quota.limit, 5);
});

test('computeQuota: 副作用なし(呼び出しても内部状態は変化しない)', () => {
  deviceQuota._reset();
  const id = 'dev-E';
  deviceQuota.tryConsume(id, 2);

  const before = deviceQuota.getState(id);
  const quota1 = deviceQuota.computeQuota(id);
  const quota2 = deviceQuota.computeQuota(id);
  const after = deviceQuota.getState(id);

  assert.deepEqual(quota1, quota2);
  assert.deepEqual(before, after);
  assert.equal(quota1.unitsUsed, 2);
});

test('computeQuota: deviceId空は{unlimited:true}のみを返す', () => {
  assert.deepEqual(deviceQuota.computeQuota(null), { unlimited: true });
  assert.deepEqual(deviceQuota.computeQuota(''), { unlimited: true });
});

// ---------------------------------------------------------------------------
// ルート結合テスト
// ---------------------------------------------------------------------------

async function withEnv(vars, fn) {
  const saved = {};
  for (const key of Object.keys(vars)) {
    saved[key] = process.env[key];
    if (vars[key] === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = vars[key];
    }
  }
  try {
    return await fn();
  } finally {
    for (const key of Object.keys(saved)) {
      if (saved[key] === undefined) delete process.env[key];
      else process.env[key] = saved[key];
    }
  }
}

function freshRoutes() {
  delete require.cache[require.resolve('../src/routes')];
  delete require.cache[require.resolve('../src/keepa/client')];
  return require('../src/routes');
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

// isbn13(978始まり13桁)形式のダミーコードを生成する。convertCode は978/979始まりを
// チェックデジットの正当性に関わらずisbnとして受理するため、消費のたびにキャッシュを
// ミスさせる目的で末尾を変えるだけでよい。
function isbnCode(i) {
  return `978400000${String(i).padStart(4, '0')}`;
}

function mockKeepaSuccess(keepa) {
  keepa.getProduct = async ({ code, asin }) => ({
    product: {
      asin: asin || `B00TEST${(code || '').slice(-4)}`,
      title: 'テスト商品',
      imagesCSV: 'sample.jpg',
      stats: { current: [2000, 1000, 800, 5000, 2200] },
    },
  });
}

const V1_ENV = {
  LWA_CLIENT_ID: undefined,
  LWA_CLIENT_SECRET: undefined,
  LWA_REFRESH_TOKEN: undefined,
  KEEPA_API_KEY: 'test-keepa-key',
};

test('ルート: v2ヘッダーあり非Proが基本枠(5)超で/api/searchが429 quota_exceeded、body.quotaが付く', async (t) => {
  await withEnv(V1_ENV, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    mockKeepaSuccess(keepa);
    routes.deviceQuota._reset();

    const headers = { 'x-quota-model': 'v2', 'x-device-id': 'DEV-V2-A' };
    const route = routes.match('GET', '/api/search');

    for (let i = 0; i < 5; i += 1) {
      const res = createMockRes();
      await route.handler({ query: { code: isbnCode(i) }, headers }, res);
      assert.notEqual(res.statusCode, 429, `${i}回目は成功するはず`);
      assert.ok(res.body.quota, `${i}回目のレスポンスにquotaが付くはず`);
    }

    const res6 = createMockRes();
    await route.handler({ query: { code: isbnCode(5) }, headers }, res6);
    assert.equal(res6.statusCode, 429);
    assert.equal(res6.body.error, 'quota_exceeded');
    assert.ok(res6.body.quota);
    assert.equal(res6.body.quota.unitsUsed, 5);
    assert.equal(res6.body.quota.unitsRemaining, 0);

    t.after(() => {
      routes.searchCache.clear();
      routes.deviceQuota._reset();
    });
  });
});

test('ルート: Keepaを呼ばないコード(unresolved)ではユニットを消費しない', async (t) => {
  await withEnv(V1_ENV, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    // 呼ばれたら失敗させる(この経路でKeepaへ問い合わせが飛ばないことの担保)。
    keepa.getProduct = async () => {
      throw new Error('Keepaを呼んではいけない');
    };
    routes.deviceQuota._reset();

    const headers = { 'x-quota-model': 'v2', 'x-device-id': 'DEV-UNRESOLVED' };
    const route = routes.match('GET', '/api/search');

    // 書籍JANの2段目(192始まり)と桁数不正。どちらもconvertCodeがunresolvedにする。
    for (const code of ['1920000000000', '123']) {
      const res = createMockRes();
      await route.handler({ query: { code }, headers }, res);
      assert.equal(res.statusCode, 200, `code=${code} は200で返るはず`);
      assert.equal(res.body.codeType, 'unresolved');
      assert.equal(res.body.quota.unitsUsed, 0, `code=${code} でユニットを消費してはいけない`);
    }

    t.after(() => {
      routes.searchCache.clear();
      routes.deviceQuota._reset();
    });
  });
});

test('ルート: v2ヘッダー無しの非Proは基本枠(5)で切られず、レガシー上限(FREE_DEVICE_DAILY_LIMIT)まで通る(後方互換)', async (t) => {
  await withEnv({ ...V1_ENV, FREE_DEVICE_DAILY_LIMIT: '7' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    mockKeepaSuccess(keepa);
    const deviceRateLimit = require('../src/deviceRateLimit');
    deviceRateLimit._reset();
    routes.deviceQuota._reset();

    // v2ヘッダーを送らない旧クライアント。x-device-idのみ送る。
    const headers = { 'x-device-id': 'DEV-V1-A' };
    const route = routes.match('GET', '/api/search');

    // 基本枠5を超える6回目でも429にならない(レガシー上限は7)。
    for (let i = 0; i < 6; i += 1) {
      const res = createMockRes();
      await route.handler({ query: { code: isbnCode(100 + i) }, headers }, res);
      assert.notEqual(res.body && res.body.error, 'quota_exceeded');
      assert.notEqual(res.body && res.body.error, 'daily_limit_exceeded');
    }

    // 7回目まではレガシー上限内(FREE_DEVICE_DAILY_LIMIT=7)。
    const res7 = createMockRes();
    await route.handler({ query: { code: isbnCode(106) }, headers }, res7);
    assert.notEqual(res7.body && res7.body.error, 'daily_limit_exceeded');

    // 8回目でレガシー上限超過。
    const res8 = createMockRes();
    await route.handler({ query: { code: isbnCode(107) }, headers }, res8);
    assert.equal(res8.statusCode, 429);
    assert.equal(res8.body.error, 'daily_limit_exceeded');

    t.after(() => {
      routes.searchCache.clear();
      deviceRateLimit._reset();
    });
  });
});

test('ルート: Proはv2ヘッダーありでも429にならない', async (t) => {
  await withEnv(V1_ENV, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    mockKeepaSuccess(keepa);
    routes.deviceQuota._reset();

    const headers = { 'x-quota-model': 'v2', 'x-device-id': 'DEV-PRO-A', 'x-app-plan': 'pro' };
    const route = routes.match('GET', '/api/search');

    for (let i = 0; i < 8; i += 1) {
      const res = createMockRes();
      await route.handler({ query: { code: isbnCode(200 + i) }, headers }, res);
      assert.notEqual(res.statusCode, 429, `${i}回目`);
      // Proはquota無制限のためquotaフィールドを付けない。
      assert.equal(res.body.quota, undefined);
    }

    t.after(() => {
      routes.searchCache.clear();
    });
  });
});

test('ルート: /api/graph-data はv2ヘッダー無し非Proが403 plan_required(レガシー維持)', async () => {
  await withEnv({ KEEPA_API_KEY: 'test-keepa-key' }, async () => {
    const routes = freshRoutes();
    const req = { query: { asin: 'B000TESTV1' }, headers: {} };
    const res = createMockRes();
    const route = routes.match('GET', '/api/graph-data');
    await route.handler(req, res);

    assert.equal(res.statusCode, 403);
    assert.equal(res.body.error, 'plan_required');
  });
});

test('ルート: /api/graph-data はv2ヘッダーあり非Proだと403にならず、ユニット消費してquota付きで返す', async (t) => {
  await withEnv({ KEEPA_API_KEY: 'test-keepa-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    keepa.getProduct = async ({ asin }) => ({ product: { asin, csv: [] } });
    routes.deviceQuota._reset();

    const headers = { 'x-quota-model': 'v2', 'x-device-id': 'DEV-GRAPH-V2' };
    const req = { query: { asin: 'B000TESTV2' }, headers };
    const res = createMockRes();
    const route = routes.match('GET', '/api/graph-data');
    await route.handler(req, res);

    assert.notEqual(res.statusCode, 403);
    assert.equal(res.statusCode, 200);
    assert.ok(res.body.quota);
    assert.equal(res.body.quota.unitsUsed, 1);

    t.after(() => {
      routes.graphDataCache.clear();
      routes.deviceQuota._reset();
    });
  });
});

test('GET /api/quota: Proは{unlimited:true, reason:"pro"}、非Proはquotaオブジェクトを返す', async (t) => {
  const routes = freshRoutes();
  routes.deviceQuota._reset();

  const route = routes.match('GET', '/api/quota');

  const resPro = createMockRes();
  await route.handler({ query: {}, headers: { 'x-app-plan': 'pro' } }, resPro);
  assert.equal(resPro.statusCode, 200);
  assert.deepEqual(resPro.body, { unlimited: true, reason: 'pro' });

  const resFree = createMockRes();
  await route.handler({ query: {}, headers: { 'x-device-id': 'DEV-QUOTA-A' } }, resFree);
  assert.equal(resFree.statusCode, 200);
  assert.equal(resFree.body.unitsUsed, 0);
  assert.equal(resFree.body.limit, 5);
  assert.equal(resFree.body.unitsRemaining, 5);

  t.after(() => {
    routes.deviceQuota._reset();
  });
});
