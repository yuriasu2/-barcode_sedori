'use strict';

const test = require('node:test');
const assert = require('node:assert');

const keepaThrottle = require('../src/keepaThrottle');
const keepaCoalesce = require('../src/keepaCoalesce');

/**
 * server/test/keepa.test.js の既存ルートテスト作法に合わせる:
 * withEnv(環境変数の一時上書き) → freshRoutes(require.cacheを捨てて再require) →
 * routes.match(method, path).handler(req, res) をcreateMockRes()相手に直接呼ぶ
 * (http.createServer/global.fetchは使わない。global.fetchを差し替えるとテスト自身が
 * ローカルサーバーへ投げるfetch呼び出しまで巻き込まれてしまうため)。
 */
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
  // keepaCoalesceはrequire.cacheから消していない(routes.jsとテストの両方が同一の
  // シングルトンを参照し続ける必要があるため、モジュール自体は使い回す)。ただし
  // in-flightのMapは前のテストの残骸を持ち越しうるので、テストごとに明示的にクリアする
  // (放置すると、将来pendingなPromiseを残すテストが出た場合に後続テストへ結果が
  // 静かに漏れる)。
  keepaCoalesce._resetForTest();
  return require('../src/routes');
}

function createMockRes() {
  const res = {
    statusCode: 200,
    headers: {},
    body: undefined,
    binaryBody: undefined,
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(body) {
      this.body = body;
      this.ended = true;
      return this;
    },
    binary(buf, contentType) {
      this.binaryBody = buf;
      this.headers['Content-Type'] = contentType;
      this.ended = true;
      return this;
    },
  };
  return res;
}

/** スロットル設定を一時的に上書きしてコアを作り直す(テスト後に元設定へ戻す)。 */
function throttleEnv(t, overrides) {
  const saved = { ...process.env };
  Object.assign(process.env, overrides);
  keepaThrottle._resetForTest();
  t.after(() => {
    process.env = saved;
    keepaThrottle._resetForTest();
  });
}

const NO_SPAPI = {
  LWA_CLIENT_ID: undefined,
  LWA_CLIENT_SECRET: undefined,
  LWA_REFRESH_TOKEN: undefined,
};

test('/api/graph-data: スロットル拒否(残量0で即拒否)は429 keepa_busyで、指定文言を返す', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: 'shared-key' }, async () => {
    const routes = freshRoutes();
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '1' });
    await keepaThrottle.reportTokensLeft(0); // 枯渇状態を作る

    const req = {
      query: { asin: 'B000THROTTLE1' },
      headers: { 'x-app-plan': 'pro', 'x-device-id': 'dev-throttle-1' },
    };
    const res = createMockRes();
    const route = routes.match('GET', '/api/graph-data');
    await route.handler(req, res);

    assert.equal(res.statusCode, 429);
    assert.equal(res.body.error, 'keepa_busy');
    assert.equal(res.body.message, '混み合っているので時間を空けてお試しください。');

    t.after(() => routes.graphDataCache.clear());
  });
});

test('/api/search: スロットル拒否時は無料枠ユニットを消費しない', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: 'shared-key' }, async () => {
    const routes = freshRoutes();
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '1' });
    await keepaThrottle.reportTokensLeft(0);
    routes.deviceQuota._reset();

    const deviceId = 'dev-no-consume-1';
    const req = {
      query: { code: '9784873119045' },
      headers: { 'x-app-plan': 'free', 'x-device-id': deviceId },
    };
    const res = createMockRes();
    const route = routes.match('GET', '/api/search');
    await route.handler(req, res);

    assert.equal(res.statusCode, 429);
    assert.equal(res.body.error, 'keepa_busy');

    // 拒否されたのにユニットが減っていないこと(設計書§2.2の受け入れ条件)
    const state = await routes.deviceQuota.getState(deviceId);
    assert.equal(state.unitsUsed, 0);

    t.after(() => {
      routes.searchCache.clear();
      routes.deviceQuota._reset();
    });
  });
});

test('/api/search: BYOキー(X-Keepa-Key)はスロットル枯渇中でも素通しされる', async (t) => {
  // 共有キー無し=BYOのみで動くことも同時に確認
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: undefined }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '1' });
    await keepaThrottle.reportTokensLeft(0); // 共有側は枯渇状態

    keepa.getProduct = async ({ apiKey }) => {
      assert.equal(apiKey, 'my-own-key');
      return {
        product: { asin: 'B000BYOTEST', title: 'BYOテスト', csv: [] },
        tokensLeft: 50,
      };
    };

    const req = {
      query: { code: '9784873119045' },
      headers: { 'x-app-plan': 'pro', 'x-device-id': 'dev-byo-1', 'x-keepa-key': 'my-own-key' },
    };
    const res = createMockRes();
    const route = routes.match('GET', '/api/search');
    await route.handler(req, res);

    assert.equal(res.statusCode, 200); // 枯渇の影響を受けない

    t.after(() => routes.searchCache.clear());
  });
});

test('/api/graph-data: 成功時はtokensLeftがスロットルへ報告される', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: 'shared-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    // 容量10・報告でtokensLeft=0になる → 次のacquireが拒否されることで「報告された」ことを検証
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '1' });
    keepa.getProduct = async ({ asin }) => ({ product: { asin, csv: [] }, tokensLeft: 0 });

    const headers = { 'x-app-plan': 'pro', 'x-device-id': 'dev-report-1' };

    const req1 = { query: { asin: 'B000REPORT01' }, headers };
    const res1 = createMockRes();
    await routes.match('GET', '/api/graph-data').handler(req1, res1);
    assert.equal(res1.statusCode, 200);

    const req2 = { query: { asin: 'B000REPORT02' }, headers };
    const res2 = createMockRes();
    await routes.match('GET', '/api/graph-data').handler(req2, res2);
    assert.equal(res2.statusCode, 429);
    assert.equal(res2.body.error, 'keepa_busy');

    t.after(() => routes.graphDataCache.clear());
  });
});

test('/api/graph-data: レスポンス構築(extractGraphSeries)で例外が起きても素の500ではなく502 graph_data_failedを返す', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: 'shared-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });
    keepa.getProduct = async ({ asin }) => ({ product: { asin, csv: [] }, tokensLeft: 9 });
    keepa.extractGraphSeries = () => {
      throw new Error('boom');
    };

    const req = {
      query: { asin: 'B000CONSTRUCT1' },
      headers: { 'x-app-plan': 'pro', 'x-device-id': 'dev-construct-1' },
    };
    const res = createMockRes();
    await routes.match('GET', '/api/graph-data').handler(req, res);

    assert.equal(res.statusCode, 502);
    assert.equal(res.body.error, 'graph_data_failed');

    t.after(() => routes.graphDataCache.clear());
  });
});

// ---------------------------------------------------------------------------
// Keepaスロットルのデバッグ表示(X-Keepa-Debug)
// docs/superpowers/specs/2026-08-02-keepa-token-depletion-design.md §2.1・§2.6
// ---------------------------------------------------------------------------

test('/api/search: X-Keepa-Debugヘッダー付き(通常経路)は_keepaDebugを含み、bypass=nullでsnapshotが入る', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: 'shared-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });
    keepa.getProduct = async () => ({
      product: { asin: 'B000DEBUG01', title: 'デバッグテスト', csv: [] },
      tokensLeft: 9,
    });

    const req = {
      query: { code: '9784873119045' },
      headers: { 'x-app-plan': 'pro', 'x-device-id': 'dev-debug-1', 'x-keepa-debug': '1' },
    };
    const res = createMockRes();
    await routes.match('GET', '/api/search').handler(req, res);

    assert.equal(res.statusCode, 200);
    assert.ok(res.body._keepaDebug, '_keepaDebugが含まれること');
    assert.equal(res.body._keepaDebug.bypass, null);
    assert.equal(res.body._keepaDebug.allowed, true);
    assert.equal(res.body._keepaDebug.reason, null);
    assert.equal(typeof res.body._keepaDebug.waitedMs, 'number');
    assert.ok(res.body._keepaDebug.snapshot, 'snapshotが入ること');
    assert.equal(res.body._keepaDebug.snapshot.capacity, 10);
    assert.equal(res.body._keepaDebug.snapshot.refillPerMin, 5);

    t.after(() => routes.searchCache.clear());
  });
});

test('/api/search: X-Keepa-Debug+BYOキーはbypass=byoでスロットルに触れない', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: undefined }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '1' });
    await keepaThrottle.reportTokensLeft(0); // 共有側は枯渇状態(BYOはこの影響を受けないことも確認)

    keepa.getProduct = async ({ apiKey }) => {
      assert.equal(apiKey, 'my-own-key');
      return { product: { asin: 'B000DEBUG02', title: 'BYOデバッグ', csv: [] }, tokensLeft: 50 };
    };

    const req = {
      query: { code: '9784873119045' },
      headers: {
        'x-app-plan': 'pro',
        'x-device-id': 'dev-debug-2',
        'x-keepa-key': 'my-own-key',
        'x-keepa-debug': '1',
      },
    };
    const res = createMockRes();
    await routes.match('GET', '/api/search').handler(req, res);

    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.body._keepaDebug, {
      bypass: 'byo',
      waitedMs: 0,
      allowed: true,
      reason: null,
      snapshot: null,
    });

    t.after(() => routes.searchCache.clear());
  });
});

test('/api/search: X-Keepa-Debug+キャッシュヒットはbypass=cacheで、次のヘッダー無しリクエストへ漏れない', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: 'shared-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });
    keepa.getProduct = async () => ({
      product: { asin: 'B000DEBUG03', title: 'キャッシュデバッグ', csv: [] },
      tokensLeft: 9,
    });

    const baseHeaders = { 'x-app-plan': 'pro', 'x-device-id': 'dev-debug-3' };

    // 1回目: キャッシュへ入れる(デバッグ無し)
    const req1 = { query: { code: '9784873119045' }, headers: baseHeaders };
    const res1 = createMockRes();
    await routes.match('GET', '/api/search').handler(req1, res1);
    assert.equal(res1.statusCode, 200);
    assert.equal(res1.body._keepaDebug, undefined);

    // 2回目: キャッシュヒット・デバッグ有効 → bypass:'cache'
    const req2 = {
      query: { code: '9784873119045' },
      headers: { ...baseHeaders, 'x-keepa-debug': '1' },
    };
    const res2 = createMockRes();
    await routes.match('GET', '/api/search').handler(req2, res2);
    assert.equal(res2.statusCode, 200);
    assert.deepEqual(res2.body._keepaDebug, {
      bypass: 'cache',
      waitedMs: 0,
      allowed: true,
      reason: null,
      snapshot: null,
    });

    // 3回目: 再びデバッグ無し → キャッシュへ_keepaDebugが漏れて残っていないこと
    const req3 = { query: { code: '9784873119045' }, headers: baseHeaders };
    const res3 = createMockRes();
    await routes.match('GET', '/api/search').handler(req3, res3);
    assert.equal(res3.statusCode, 200);
    assert.equal(res3.body._keepaDebug, undefined);

    t.after(() => routes.searchCache.clear());
  });
});

test('/api/search: X-Keepa-Debugヘッダーが無ければ_keepaDebugは一切含まれない', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: 'shared-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });
    keepa.getProduct = async () => ({
      product: { asin: 'B000DEBUG04', title: '通常', csv: [] },
      tokensLeft: 9,
    });

    const req = {
      query: { code: '9784873119045' },
      headers: { 'x-app-plan': 'pro', 'x-device-id': 'dev-debug-4' },
    };
    const res = createMockRes();
    await routes.match('GET', '/api/search').handler(req, res);

    assert.equal(res.statusCode, 200);
    assert.equal('_keepaDebug' in res.body, false);

    t.after(() => routes.searchCache.clear());
  });
});

test('/api/graph-data: X-Keepa-Debugヘッダー付き(通常経路)は_keepaDebugを含み、bypass=nullでsnapshotが入る', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: 'shared-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });
    keepa.getProduct = async () => ({
      product: { asin: 'B000GDDEBUG1', csv: [] },
      tokensLeft: 9,
    });

    const req = {
      query: { asin: 'B000GDDEBUG1' },
      headers: { 'x-app-plan': 'pro', 'x-device-id': 'dev-gd-debug-1', 'x-keepa-debug': '1' },
    };
    const res = createMockRes();
    await routes.match('GET', '/api/graph-data').handler(req, res);

    assert.equal(res.statusCode, 200);
    assert.ok(res.body._keepaDebug, '_keepaDebugが含まれること');
    assert.equal(res.body._keepaDebug.bypass, null);
    assert.equal(res.body._keepaDebug.allowed, true);
    assert.equal(res.body._keepaDebug.reason, null);
    assert.equal(typeof res.body._keepaDebug.waitedMs, 'number');
    assert.ok(res.body._keepaDebug.snapshot, 'snapshotが入ること');
    assert.equal(res.body._keepaDebug.snapshot.capacity, 10);
    assert.equal(res.body._keepaDebug.snapshot.refillPerMin, 5);

    t.after(() => routes.graphDataCache.clear());
  });
});

test('/api/graph-data: X-Keepa-Debug+BYOキーはbypass=byoでスロットルに触れない', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: undefined }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '1' });
    await keepaThrottle.reportTokensLeft(0); // 共有側は枯渇状態(BYOはこの影響を受けないことも確認)

    keepa.getProduct = async ({ apiKey }) => {
      assert.equal(apiKey, 'my-own-key');
      return { product: { asin: 'B000GDDEBUG2', csv: [] }, tokensLeft: 50 };
    };

    const req = {
      query: { asin: 'B000GDDEBUG2' },
      headers: {
        'x-app-plan': 'pro',
        'x-device-id': 'dev-gd-debug-2',
        'x-keepa-key': 'my-own-key',
        'x-keepa-debug': '1',
      },
    };
    const res = createMockRes();
    await routes.match('GET', '/api/graph-data').handler(req, res);

    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.body._keepaDebug, {
      bypass: 'byo',
      waitedMs: 0,
      allowed: true,
      reason: null,
      snapshot: null,
    });

    t.after(() => routes.graphDataCache.clear());
  });
});

test('/api/graph-data: X-Keepa-Debug+キャッシュヒットはbypass=cacheで、次のヘッダー無しリクエストへ漏れない', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: 'shared-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });
    keepa.getProduct = async () => ({
      product: { asin: 'B000GDDEBUG3', csv: [] },
      tokensLeft: 9,
    });

    const baseHeaders = { 'x-app-plan': 'pro', 'x-device-id': 'dev-gd-debug-3' };

    // 1回目: キャッシュへ入れる(デバッグ無し)
    const req1 = { query: { asin: 'B000GDDEBUG3' }, headers: baseHeaders };
    const res1 = createMockRes();
    await routes.match('GET', '/api/graph-data').handler(req1, res1);
    assert.equal(res1.statusCode, 200);
    assert.equal(res1.body._keepaDebug, undefined);

    // 2回目: キャッシュヒット・デバッグ有効 → bypass:'cache'
    const req2 = {
      query: { asin: 'B000GDDEBUG3' },
      headers: { ...baseHeaders, 'x-keepa-debug': '1' },
    };
    const res2 = createMockRes();
    await routes.match('GET', '/api/graph-data').handler(req2, res2);
    assert.equal(res2.statusCode, 200);
    assert.deepEqual(res2.body._keepaDebug, {
      bypass: 'cache',
      waitedMs: 0,
      allowed: true,
      reason: null,
      snapshot: null,
    });

    // 3回目: 再びデバッグ無し → キャッシュへ_keepaDebugが漏れて残っていないこと
    const req3 = { query: { asin: 'B000GDDEBUG3' }, headers: baseHeaders };
    const res3 = createMockRes();
    await routes.match('GET', '/api/graph-data').handler(req3, res3);
    assert.equal(res3.statusCode, 200);
    assert.equal(res3.body._keepaDebug, undefined);

    t.after(() => routes.graphDataCache.clear());
  });
});

test('/api/graph-data: X-Keepa-Debugヘッダーが無ければ_keepaDebugは一切含まれない', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: 'shared-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });
    keepa.getProduct = async () => ({
      product: { asin: 'B000GDDEBUG4', csv: [] },
      tokensLeft: 9,
    });

    const req = {
      query: { asin: 'B000GDDEBUG4' },
      headers: { 'x-app-plan': 'pro', 'x-device-id': 'dev-gd-debug-4' },
    };
    const res = createMockRes();
    await routes.match('GET', '/api/graph-data').handler(req, res);

    assert.equal(res.statusCode, 200);
    assert.equal('_keepaDebug' in res.body, false);

    t.after(() => routes.graphDataCache.clear());
  });
});

// ---------------------------------------------------------------------------
// Keepaスロットルのデモモード(X-Keepa-Demo / POST /api/keepa-throttle-demo/seed)
// ---------------------------------------------------------------------------

test('POST /api/keepa-throttle-demo/seed: tokens/ratePerMinどちらもseedしスナップショットを返す', async (t) => {
  const routes = freshRoutes();
  throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });

  const req = { query: { tokens: '3', ratePerMin: '8' }, headers: {} };
  const res = createMockRes();
  await routes.match('POST', '/api/keepa-throttle-demo/seed').handler(req, res);

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.ok, true);
  assert.equal(res.body.snapshot.tokensEstimate, 3);
  assert.equal(res.body.snapshot.consumeRatePerMin, 8);
});

test('POST /api/keepa-throttle-demo/seed: パラメータ無しは400', async (t) => {
  const routes = freshRoutes();
  throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });

  const req = { query: {}, headers: {} };
  const res = createMockRes();
  await routes.match('POST', '/api/keepa-throttle-demo/seed').handler(req, res);

  assert.equal(res.statusCode, 400);
  assert.equal(res.body.error, 'invalid_request');
});

test('POST /api/keepa-throttle-demo/seed: tokensが数値でなければ400', async (t) => {
  const routes = freshRoutes();
  throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });

  const req = { query: { tokens: 'abc' }, headers: {} };
  const res = createMockRes();
  await routes.match('POST', '/api/keepa-throttle-demo/seed').handler(req, res);

  assert.equal(res.statusCode, 400);
  assert.equal(res.body.error, 'invalid_request');
});

test('POST /api/keepa-throttle-demo/seed: ratePerMinが負なら400', async (t) => {
  const routes = freshRoutes();
  throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });

  const req = { query: { ratePerMin: '-1' }, headers: {} };
  const res = createMockRes();
  await routes.match('POST', '/api/keepa-throttle-demo/seed').handler(req, res);

  assert.equal(res.statusCode, 400);
  assert.equal(res.body.error, 'invalid_request');
});

test('POST /api/keepa-throttle-demo/seed: refillPerMinを明示指定すると時間経過でトークンが実際に補充される', async (t) => {
  const routes = freshRoutes();
  throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });

  // tokens=0・refillPerMin=600(1秒に10個)でseed → 100ms待てば1個以上戻っているはず。
  const req = { query: { tokens: '0', refillPerMin: '600' }, headers: {} };
  const res = createMockRes();
  await routes.match('POST', '/api/keepa-throttle-demo/seed').handler(req, res);
  assert.equal(res.statusCode, 200);
  assert.equal(res.body.snapshot.tokensEstimate, 0);
  assert.equal(res.body.snapshot.refillPerMin, 600);

  await new Promise((resolve) => setTimeout(resolve, 150));
  const snapshot = await keepaThrottle.debugSnapshot('demo');
  assert.ok(snapshot.tokensEstimate > 0, `refillPerMin指定なのにトークンが補充されていない(${snapshot.tokensEstimate})`);
});

test('POST /api/keepa-throttle-demo/seed: refillPerMin未指定なら従来通り0固定される(後方互換)', async (t) => {
  const routes = freshRoutes();
  throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });

  const req = { query: { tokens: '0' }, headers: {} };
  const res = createMockRes();
  await routes.match('POST', '/api/keepa-throttle-demo/seed').handler(req, res);
  assert.equal(res.statusCode, 200);
  assert.equal(res.body.snapshot.refillPerMin, 0);

  await new Promise((resolve) => setTimeout(resolve, 150));
  const snapshot = await keepaThrottle.debugSnapshot('demo');
  assert.equal(snapshot.tokensEstimate, 0, 'refillPerMin未指定なのに自然回復してしまっている');
});

test('POST /api/keepa-throttle-demo/seed: refillPerMinが負なら400', async (t) => {
  const routes = freshRoutes();
  throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });

  const req = { query: { tokens: '1', refillPerMin: '-3' }, headers: {} };
  const res = createMockRes();
  await routes.match('POST', '/api/keepa-throttle-demo/seed').handler(req, res);

  assert.equal(res.statusCode, 400);
  assert.equal(res.body.error, 'invalid_request');
});

test('POST /api/keepa-throttle-demo/seed: refillPerMinが数値でなければ400', async (t) => {
  const routes = freshRoutes();
  throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });

  const req = { query: { tokens: '1', refillPerMin: 'abc' }, headers: {} };
  const res = createMockRes();
  await routes.match('POST', '/api/keepa-throttle-demo/seed').handler(req, res);

  assert.equal(res.statusCode, 400);
  assert.equal(res.body.error, 'invalid_request');
});

// ---------------------------------------------------------------------------
// POST /api/keepa-throttle-demo/probe — 実Keepaを呼ばない純粋なスロットル判定プローブ
// ---------------------------------------------------------------------------

test('POST /api/keepa-throttle-demo/probe: 実Keepa(global.fetch)を一切呼ばない', async (t) => {
  const routes = freshRoutes();
  throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });
  await keepaThrottle.seedDemoState({ tokens: 5 });

  const originalFetch = global.fetch;
  let callCount = 0;
  global.fetch = async (...args) => {
    callCount += 1;
    return originalFetch(...args);
  };
  t.after(() => {
    global.fetch = originalFetch;
  });

  const req = { query: { priority: 'pro' }, headers: {} };
  const res = createMockRes();
  await routes.match('POST', '/api/keepa-throttle-demo/probe').handler(req, res);

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.priority, 'pro');
  assert.equal(res.body.allowed, true);
  assert.equal(callCount, 0, 'probeがKeepa API(global.fetch)を呼び出してしまっている');
});

test('POST /api/keepa-throttle-demo/probe: priority省略時はfree扱い、レスポンスにwaitedMs/snapshotが入る', async (t) => {
  const routes = freshRoutes();
  throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });
  await keepaThrottle.seedDemoState({ tokens: 5 });

  const req = { query: {}, headers: {} };
  const res = createMockRes();
  await routes.match('POST', '/api/keepa-throttle-demo/probe').handler(req, res);

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.priority, 'free');
  assert.equal(res.body.allowed, true);
  assert.equal(res.body.reason, null);
  assert.equal(typeof res.body.waitedMs, 'number');
  assert.ok(res.body.snapshot, 'snapshotが入ること');
});

test('POST /api/keepa-throttle-demo/probe: seedした残量ぶんはallowed:true、それ以降はallowed:false(exhausted)になる', async (t) => {
  const routes = freshRoutes();
  throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });
  await keepaThrottle.seedDemoState({ tokens: 2 }); // refillPerMinは0固定なので自然回復しない

  const route = routes.match('POST', '/api/keepa-throttle-demo/probe');
  const results = [];
  for (let i = 0; i < 4; i += 1) {
    const req = { query: { priority: 'free' }, headers: {} };
    const res = createMockRes();
    await route.handler(req, res);
    results.push(res.body);
  }

  assert.equal(results[0].allowed, true);
  assert.equal(results[1].allowed, true);
  assert.equal(results[2].allowed, false);
  assert.equal(results[2].reason, 'exhausted');
  assert.equal(results[3].allowed, false);
  assert.equal(results[3].reason, 'exhausted');
});

test('/api/search: X-Keepa-Demoでdemoをseedし残量0にすると、demo付き検索はkeepa_busyになるが、同時にdemo無しの通常検索(global)は影響を受けず成功する(安全設計の核心)', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: 'shared-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });
    keepa.getProduct = async () => ({
      product: { asin: 'B000DEMOSAFE', title: 'デモ隔離テスト', csv: [] },
      tokensLeft: 9,
    });

    // demoインスタンスだけを残量0にする(globalには一切触れない)。
    await keepaThrottle.seedDemoState({ tokens: 0 });

    // demo付きリクエスト: demoインスタンスは枯渇済み(キューは無いので即座に拒否)なはず。
    const demoReq = {
      query: { code: '9784873119045' },
      headers: { 'x-app-plan': 'pro', 'x-device-id': 'dev-demo-1', 'x-keepa-demo': '1' },
    };
    const demoRes = createMockRes();
    await routes.match('GET', '/api/search').handler(demoReq, demoRes);
    assert.equal(demoRes.statusCode, 429);
    assert.equal(demoRes.body.error, 'keepa_busy');

    // demo無しの通常リクエスト(global)は満タンのままなので通常通り成功するはず。
    const normalReq = {
      query: { code: '9784873119046' },
      headers: { 'x-app-plan': 'pro', 'x-device-id': 'dev-normal-1' },
    };
    const normalRes = createMockRes();
    await routes.match('GET', '/api/search').handler(normalReq, normalRes);
    assert.equal(normalRes.statusCode, 200);

    t.after(() => routes.searchCache.clear());
  });
});

test('/api/search: X-Keepa-Demo付きでもBYOキーが優先されスロットル自体をバイパスする', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: undefined }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });
    await keepaThrottle.seedDemoState({ tokens: 0 }); // demoは枯渇状態

    keepa.getProduct = async ({ apiKey }) => {
      assert.equal(apiKey, 'my-own-key');
      return {
        product: { asin: 'B000DEMOBYO', title: 'デモ+BYOテスト', csv: [] },
        tokensLeft: 50,
      };
    };

    const req = {
      query: { code: '9784873119045' },
      headers: {
        'x-app-plan': 'pro',
        'x-device-id': 'dev-demo-byo-1',
        'x-keepa-key': 'my-own-key',
        'x-keepa-demo': '1',
      },
    };
    const res = createMockRes();
    await routes.match('GET', '/api/search').handler(req, res);

    assert.equal(res.statusCode, 200); // demo枯渇の影響を受けない(BYOが優先)

    t.after(() => routes.searchCache.clear());
  });
});

test('/api/graph-data: X-Keepa-Demo経路の成功時は実Keepaのtokens Leftでdemoインスタンスを上書きしない', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: 'shared-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });
    // demoを明示的に残量5にseedする。
    await keepaThrottle.seedDemoState({ tokens: 5 });
    // 実Keepaは残量0を返す(通常経路ならreportTokensLeftでdemoが0に上書きされてしまうはず)。
    keepa.getProduct = async ({ asin }) => ({ product: { asin, csv: [] }, tokensLeft: 0 });

    const req = {
      query: { asin: 'B000DEMOKEEP1' },
      headers: { 'x-app-plan': 'pro', 'x-device-id': 'dev-demo-keep-1', 'x-keepa-demo': '1' },
    };
    const res = createMockRes();
    await routes.match('GET', '/api/graph-data').handler(req, res);
    assert.equal(res.statusCode, 200);

    // demoインスタンスのスナップショットが実Keepaのtokens Left(0)で上書きされていないこと
    // (seedした5前後のまま=消費で1個減って4程度のはず。少なくとも0にはなっていない)。
    const snapshot = await keepaThrottle.debugSnapshot('demo');
    assert.ok(snapshot.tokensEstimate > 0, `demoが実Keepaの残量で上書きされている(tokensEstimate=${snapshot.tokensEstimate})`);

    t.after(() => routes.graphDataCache.clear());
  });
});

test('/api/search: 同一コードへの同時リクエストはKeepaを1回しか呼ばない(コアレッシング)', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: 'shared-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });

    let callCount = 0;
    keepa.getProduct = async () => {
      callCount += 1;
      await new Promise((r) => setTimeout(r, 30));
      return {
        product: { asin: 'B000COALESCE1', title: 'コアレッシングテスト', csv: [] },
        tokensLeft: 9,
      };
    };

    const makeReq = (deviceId) => ({
      query: { code: '9784873119045' },
      headers: { 'x-app-plan': 'pro', 'x-device-id': deviceId },
    });

    const responses = await Promise.all(
      ['dev-a', 'dev-b', 'dev-c'].map(async (deviceId) => {
        const req = makeReq(deviceId);
        const res = createMockRes();
        await routes.match('GET', '/api/search').handler(req, res);
        return res;
      })
    );

    assert.equal(callCount, 1, 'Keepaへの実呼び出しは1回だけのはず');
    for (const res of responses) {
      assert.equal(res.statusCode, 200);
      assert.equal(res.body.asin, 'B000COALESCE1');
    }
  });
});

test('/api/search: コアレッシングされたリクエストがスロットル拒否されたら、束ねられた全員がkeepa_busyになる', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: 'shared-key' }, async () => {
    const routes = freshRoutes();
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });
    await keepaThrottle.reportTokensLeft(0); // 枯渇状態を作る

    // スロットル(acquire)への問い合わせ回数を数える。keepaCoalesce.coalesceをpass-through
    // (束ねない実装)に差し替えても、スロットルが既に枯渇している場合は各リクエストが
    // 個別にacquireしても結局全員429になってしまい、テスト名が主張する「コアレッシングされて
    // いること」自体は検証できていなかった。acquireが1回しか呼ばれないことまで見て、
    // 実際に束ねられた1本のin-flight呼び出しの結果を全員が共有していることを保証する。
    const originalAcquire = keepaThrottle.acquire;
    let acquireCallCount = 0;
    keepaThrottle.acquire = async (...args) => {
      acquireCallCount += 1;
      return originalAcquire(...args);
    };
    t.after(() => {
      keepaThrottle.acquire = originalAcquire;
    });

    const makeReq = (deviceId) => ({
      query: { code: '9784873119045' },
      headers: { 'x-app-plan': 'pro', 'x-device-id': deviceId },
    });

    const responses = await Promise.all(
      ['dev-a', 'dev-b'].map(async (deviceId) => {
        const req = makeReq(deviceId);
        const res = createMockRes();
        await routes.match('GET', '/api/search').handler(req, res);
        return res;
      })
    );

    for (const res of responses) {
      assert.equal(res.statusCode, 429);
      assert.equal(res.body.error, 'keepa_busy');
    }
    assert.equal(
      acquireCallCount,
      1,
      'コアレッシングされていればスロットルへの問い合わせ(acquire)は束ねられた1回だけのはず'
    );
  });
});

// ---------------------------------------------------------------------------
// コアレッシングkeyの隔離(レビュー指摘: BYOキー別・priority別に束ねてはいけない)
// ---------------------------------------------------------------------------

test('/api/search: BYOキーが異なる2ユーザーの同時リクエストはコアレッシングされず、各自のKeepaキーで別々に呼ばれる', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: undefined }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');

    const seenApiKeys = [];
    keepa.getProduct = async ({ apiKey }) => {
      seenApiKeys.push(apiKey);
      await new Promise((r) => setTimeout(r, 30)); // 同時実行の窓を作る
      return {
        product: { asin: `B000BYO-${apiKey}`, title: `BYO-${apiKey}`, csv: [] },
        tokensLeft: 50,
      };
    };

    const makeReq = (deviceId, byoKey) => ({
      query: { code: '9784873119045' },
      headers: { 'x-app-plan': 'pro', 'x-device-id': deviceId, 'x-keepa-key': byoKey },
    });

    const [resA, resB] = await Promise.all([
      (async () => {
        const res = createMockRes();
        await routes.match('GET', '/api/search').handler(makeReq('dev-byo-a', 'key-A'), res);
        return res;
      })(),
      (async () => {
        const res = createMockRes();
        await routes.match('GET', '/api/search').handler(makeReq('dev-byo-b', 'key-B'), res);
        return res;
      })(),
    ]);

    // 修正前はBYOのコアレッシングkeyが`byo:${coalesceKey}`のみ(キー自体を含まない)だったため、
    // 異なるKeepaキーを持つ2ユーザーが同一商品コードで同時に検索すると1本の呼び出しに束ねられ、
    // 先着側のキーだけが実際にKeepaへ送られていた(=後着側のスキャンが先着側の課金枠を
    // 肩代わりする事故。無効キーなら正当なキーを持つ後着側まで502になる)。
    assert.equal(
      seenApiKeys.length,
      2,
      `Keepaへの呼び出しはユーザーごとに2回のはず(実際: ${seenApiKeys.length}回、キー=${JSON.stringify(seenApiKeys)})`
    );
    assert.ok(seenApiKeys.includes('key-A'), 'key-Aで実際にKeepaが呼ばれていない');
    assert.ok(seenApiKeys.includes('key-B'), 'key-Bで実際にKeepaが呼ばれていない');

    assert.equal(resA.statusCode, 200);
    assert.equal(resB.statusCode, 200);
    assert.equal(resA.body.asin, 'B000BYO-key-A', 'ユーザーAが自分のキーで取得した結果を受け取っていない');
    assert.equal(resB.body.asin, 'B000BYO-key-B', 'ユーザーBが自分のキーで取得した結果を受け取っていない');

    t.after(() => routes.searchCache.clear());
  });
});

test('/api/search: 共有キーでのPro同時リクエストと無料同時リクエストはコアレッシングされず、各々のpriorityでスロットルされる', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: 'shared-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });

    const acquiredPriorities = [];
    const originalAcquire = keepaThrottle.acquire;
    keepaThrottle.acquire = async (priority, instance) => {
      acquiredPriorities.push(priority);
      return originalAcquire(priority, instance);
    };
    t.after(() => {
      keepaThrottle.acquire = originalAcquire;
    });

    let callCount = 0;
    keepa.getProduct = async () => {
      callCount += 1;
      await new Promise((r) => setTimeout(r, 30)); // 同時実行の窓を作る
      return {
        product: { asin: 'B000PRIOMIX', title: 'プライオリティ混在テスト', csv: [] },
        tokensLeft: 9,
      };
    };

    const proReq = {
      query: { code: '9784873119045' },
      headers: { 'x-app-plan': 'pro', 'x-device-id': 'dev-prio-pro' },
    };
    const freeReq = {
      query: { code: '9784873119045' },
      headers: { 'x-app-plan': 'free', 'x-device-id': 'dev-prio-free' },
    };

    const [proRes, freeRes] = await Promise.all([
      (async () => {
        const res = createMockRes();
        await routes.match('GET', '/api/search').handler(proReq, res);
        return res;
      })(),
      (async () => {
        const res = createMockRes();
        await routes.match('GET', '/api/search').handler(freeReq, res);
        return res;
      })(),
    ]);

    // 修正前はpriorityがコアレッシングkeyに含まれず(共有キーkeyは`${instance}:${coalesceKey}`のみ)、
    // 先着1件だけが実際にacquireを呼び、後着はその結果へただ相乗りしていた。すなわち先着がfreeなら
    // Proが無料側の適応ブレーキ(BRAKE_SAFE_TTE_MIN_FREE=10)を、先着がProならfreeがProの
    // ブレーキ免除(BRAKE_SAFE_TTE_MIN_PRO=2)を、それぞれ誤って引き継いでいた。
    assert.equal(callCount, 2, `Keepaへの実呼び出しはpro用/free用で2回のはず(実際: ${callCount}回)`);
    assert.equal(
      acquiredPriorities.length,
      2,
      `スロットルへの問い合わせはpro用/free用で2回のはず(実際: ${JSON.stringify(acquiredPriorities)})`
    );
    assert.ok(acquiredPriorities.includes('pro'), 'priority=proでacquireが呼ばれていない');
    assert.ok(acquiredPriorities.includes('free'), 'priority=freeでacquireが呼ばれていない');

    assert.equal(proRes.statusCode, 200);
    assert.equal(freeRes.statusCode, 200);

    t.after(() => {
      routes.searchCache.clear();
      routes.deviceQuota._reset();
    });
  });
});

// ---------------------------------------------------------------------------
// 無料枠ユニットの事前チェック(コアレッシング導入に伴い追加。tryConsumeより前に走る)
// ---------------------------------------------------------------------------

test('/api/search: 無料枠ユニット0の事前チェックでKeepaを呼ばずに429 quota_exceededを返す', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: 'shared-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });

    let getProductCallCount = 0;
    keepa.getProduct = async () => {
      getProductCallCount += 1;
      return { product: { asin: 'B000SHOULDNOTCALL1', csv: [] }, tokensLeft: 9 };
    };

    const deviceId = 'dev-quota-zero-search';
    const zeroQuota = {
      unitsRemaining: 0,
      baseRemaining: 0,
      unitsUsed: 5,
      adGrantsToday: 0,
      adAvailable: true,
      capReached: false,
      limit: 5,
    };
    const originalComputeQuota = routes.deviceQuota.computeQuota;
    routes.deviceQuota.computeQuota = async (id) => {
      assert.equal(id, deviceId);
      return zeroQuota;
    };
    t.after(() => {
      routes.deviceQuota.computeQuota = originalComputeQuota;
    });

    const req = {
      query: { code: '9784873119045' },
      headers: { 'x-app-plan': 'free', 'x-device-id': deviceId },
    };
    const res = createMockRes();
    await routes.match('GET', '/api/search').handler(req, res);

    assert.equal(res.statusCode, 429);
    assert.equal(res.body.error, 'quota_exceeded');
    assert.equal(res.body.message, '本日の無料スキャン上限に達しました。');
    assert.equal(
      getProductCallCount,
      0,
      '枠切れのはずなのにKeepaトークンを消費してしまっている(事前チェックが機能していない)'
    );

    t.after(() => routes.searchCache.clear());
  });
});

test('/api/graph-data: 無料枠ユニット0の事前チェックでKeepaを呼ばずに429 quota_exceededを返す', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: 'shared-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });

    let getProductCallCount = 0;
    keepa.getProduct = async () => {
      getProductCallCount += 1;
      return { product: { asin: 'B000SHOULDNOTCALL2', csv: [] }, tokensLeft: 9 };
    };

    const deviceId = 'dev-quota-zero-graphdata';
    const zeroQuota = {
      unitsRemaining: 0,
      baseRemaining: 0,
      unitsUsed: 5,
      adGrantsToday: 0,
      adAvailable: true,
      capReached: false,
      limit: 5,
    };
    const originalComputeQuota = routes.deviceQuota.computeQuota;
    routes.deviceQuota.computeQuota = async (id) => {
      assert.equal(id, deviceId);
      return zeroQuota;
    };
    t.after(() => {
      routes.deviceQuota.computeQuota = originalComputeQuota;
    });

    const req = {
      query: { asin: 'B000QUOTAZERO1' },
      headers: { 'x-app-plan': 'free', 'x-device-id': deviceId },
    };
    const res = createMockRes();
    await routes.match('GET', '/api/graph-data').handler(req, res);

    assert.equal(res.statusCode, 429);
    assert.equal(res.body.error, 'quota_exceeded');
    assert.equal(res.body.message, '本日の無料スキャン上限に達しました。');
    assert.equal(
      getProductCallCount,
      0,
      '枠切れのはずなのにKeepaトークンを消費してしまっている(事前チェックが機能していない)'
    );

    t.after(() => routes.graphDataCache.clear());
  });
});

for (const shape of [{ unlimited: true }, { unknown: true }]) {
  const shapeLabel = Object.keys(shape)[0];

  test(`/api/search: quotaが${shapeLabel}:trueの事前チェックはゼロ扱いにせず素通しする(可用性優先)`, async (t) => {
    await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: 'shared-key' }, async () => {
      const routes = freshRoutes();
      const keepa = require('../src/keepa/client');
      throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });

      let getProductCallCount = 0;
      keepa.getProduct = async () => {
        getProductCallCount += 1;
        return { product: { asin: `B000QUOTA-${shapeLabel}`, csv: [] }, tokensLeft: 9 };
      };

      const deviceId = `dev-quota-${shapeLabel}-search`;
      const originalComputeQuota = routes.deviceQuota.computeQuota;
      routes.deviceQuota.computeQuota = async () => shape;
      t.after(() => {
        routes.deviceQuota.computeQuota = originalComputeQuota;
      });

      const req = {
        query: { code: '9784873119045' },
        headers: { 'x-app-plan': 'free', 'x-device-id': deviceId },
      };
      const res = createMockRes();
      await routes.match('GET', '/api/search').handler(req, res);

      assert.equal(
        res.statusCode,
        200,
        `quota={${shapeLabel}:true}(unitsRemainingフィールド無し)がゼロ残量扱いされている`
      );
      assert.equal(getProductCallCount, 1, '事前チェックを通過したのにKeepaが呼ばれていない');

      t.after(() => {
        routes.searchCache.clear();
        routes.deviceQuota._reset();
      });
    });
  });

  test(`/api/graph-data: quotaが${shapeLabel}:trueの事前チェックはゼロ扱いにせず素通しする(可用性優先)`, async (t) => {
    await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: 'shared-key' }, async () => {
      const routes = freshRoutes();
      const keepa = require('../src/keepa/client');
      throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });

      let getProductCallCount = 0;
      keepa.getProduct = async ({ asin }) => {
        getProductCallCount += 1;
        return { product: { asin, csv: [] }, tokensLeft: 9 };
      };

      const deviceId = `dev-quota-${shapeLabel}-graphdata`;
      const originalComputeQuota = routes.deviceQuota.computeQuota;
      routes.deviceQuota.computeQuota = async () => shape;
      t.after(() => {
        routes.deviceQuota.computeQuota = originalComputeQuota;
      });

      const req = {
        query: { asin: `B000QUOTA${shapeLabel.toUpperCase()}` },
        headers: { 'x-app-plan': 'free', 'x-device-id': deviceId },
      };
      const res = createMockRes();
      await routes.match('GET', '/api/graph-data').handler(req, res);

      assert.equal(
        res.statusCode,
        200,
        `quota={${shapeLabel}:true}(unitsRemainingフィールド無し)がゼロ残量扱いされている`
      );
      assert.equal(getProductCallCount, 1, '事前チェックを通過したのにKeepaが呼ばれていない');

      t.after(() => {
        routes.graphDataCache.clear();
        routes.deviceQuota._reset();
      });
    });
  });
}
