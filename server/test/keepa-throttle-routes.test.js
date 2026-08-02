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
