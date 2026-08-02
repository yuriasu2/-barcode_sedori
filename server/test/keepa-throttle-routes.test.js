'use strict';

const test = require('node:test');
const assert = require('node:assert');

const keepaThrottle = require('../src/keepaThrottle');

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

test('/api/graph-data: スロットル拒否(depth=0,残量0)は429 keepa_busyで、指定文言を返す', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: 'shared-key' }, async () => {
    const routes = freshRoutes();
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_QUEUE_DEPTH: '0', KEEPA_REFILL_PER_MIN: '1' });
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
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_QUEUE_DEPTH: '0', KEEPA_REFILL_PER_MIN: '1' });
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
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_QUEUE_DEPTH: '0', KEEPA_REFILL_PER_MIN: '1' });
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
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_QUEUE_DEPTH: '0', KEEPA_REFILL_PER_MIN: '1' });
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

// ---------------------------------------------------------------------------
// Keepaスロットルのデバッグ表示(X-Keepa-Debug)
// docs/superpowers/specs/2026-08-02-keepa-token-depletion-design.md §2.1・§2.6
// ---------------------------------------------------------------------------

test('/api/search: X-Keepa-Debugヘッダー付き(通常経路)は_keepaDebugを含み、bypass=nullでsnapshotが入る', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: 'shared-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_QUEUE_DEPTH: '10', KEEPA_REFILL_PER_MIN: '5' });
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
    assert.equal(res.body._keepaDebug.snapshot.depth, 10);

    t.after(() => routes.searchCache.clear());
  });
});

test('/api/search: X-Keepa-Debug+BYOキーはbypass=byoでスロットルに触れない', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: undefined }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_QUEUE_DEPTH: '0', KEEPA_REFILL_PER_MIN: '1' });
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
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_QUEUE_DEPTH: '10', KEEPA_REFILL_PER_MIN: '5' });
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
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_QUEUE_DEPTH: '10', KEEPA_REFILL_PER_MIN: '5' });
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
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_QUEUE_DEPTH: '10', KEEPA_REFILL_PER_MIN: '5' });
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
    assert.equal(res.body._keepaDebug.snapshot.depth, 10);

    t.after(() => routes.graphDataCache.clear());
  });
});

test('/api/graph-data: X-Keepa-Debug+BYOキーはbypass=byoでスロットルに触れない', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: undefined }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_QUEUE_DEPTH: '0', KEEPA_REFILL_PER_MIN: '1' });
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
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_QUEUE_DEPTH: '10', KEEPA_REFILL_PER_MIN: '5' });
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
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_QUEUE_DEPTH: '10', KEEPA_REFILL_PER_MIN: '5' });
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
  throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_QUEUE_DEPTH: '10', KEEPA_REFILL_PER_MIN: '5' });

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
  throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_QUEUE_DEPTH: '10', KEEPA_REFILL_PER_MIN: '5' });

  const req = { query: {}, headers: {} };
  const res = createMockRes();
  await routes.match('POST', '/api/keepa-throttle-demo/seed').handler(req, res);

  assert.equal(res.statusCode, 400);
  assert.equal(res.body.error, 'invalid_request');
});

test('POST /api/keepa-throttle-demo/seed: tokensが数値でなければ400', async (t) => {
  const routes = freshRoutes();
  throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_QUEUE_DEPTH: '10', KEEPA_REFILL_PER_MIN: '5' });

  const req = { query: { tokens: 'abc' }, headers: {} };
  const res = createMockRes();
  await routes.match('POST', '/api/keepa-throttle-demo/seed').handler(req, res);

  assert.equal(res.statusCode, 400);
  assert.equal(res.body.error, 'invalid_request');
});

test('POST /api/keepa-throttle-demo/seed: ratePerMinが負なら400', async (t) => {
  const routes = freshRoutes();
  throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_QUEUE_DEPTH: '10', KEEPA_REFILL_PER_MIN: '5' });

  const req = { query: { ratePerMin: '-1' }, headers: {} };
  const res = createMockRes();
  await routes.match('POST', '/api/keepa-throttle-demo/seed').handler(req, res);

  assert.equal(res.statusCode, 400);
  assert.equal(res.body.error, 'invalid_request');
});

test('/api/search: X-Keepa-Demoでdemoをseedし残量0にすると、demo付き検索はkeepa_busyになるが、同時にdemo無しの通常検索(global)は影響を受けず成功する(安全設計の核心)', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: 'shared-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_QUEUE_DEPTH: '0', KEEPA_REFILL_PER_MIN: '5' });
    keepa.getProduct = async () => ({
      product: { asin: 'B000DEMOSAFE', title: 'デモ隔離テスト', csv: [] },
      tokensLeft: 9,
    });

    // demoインスタンスだけを残量0にする(globalには一切触れない)。
    await keepaThrottle.seedDemoState({ tokens: 0 });

    // demo付きリクエスト: demoインスタンスは枯渇済み・depth=0なので即拒否されるはず。
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
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_QUEUE_DEPTH: '0', KEEPA_REFILL_PER_MIN: '5' });
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
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_QUEUE_DEPTH: '10', KEEPA_REFILL_PER_MIN: '5' });
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
