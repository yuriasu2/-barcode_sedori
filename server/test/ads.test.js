'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

function freshRoutes() {
  delete require.cache[require.resolve('../src/routes')];
  delete require.cache[require.resolve('../src/deviceQuota')];
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

/**
 * globalThis.__adsKv に差し込むモックKV。get/putの呼び出し回数・引数を記録する。
 * store: 初期状態(キー→文字列値)。
 */
function createMockKv(store = {}) {
  const data = new Map(Object.entries(store));
  return {
    getCalls: [],
    putCalls: [],
    async get(key) {
      this.getCalls.push(key);
      return data.has(key) ? data.get(key) : null;
    },
    async put(key, value) {
      this.putCalls.push([key, value]);
      data.set(key, value);
    },
    _data: data,
  };
}

// 各テスト後にglobalThis.__adsKvを必ず元に戻す(他テストファイルへの汚染防止)。
function withAdsKv(kv, fn) {
  const saved = globalThis.__adsKv;
  globalThis.__adsKv = kv;
  return Promise.resolve()
    .then(fn)
    .finally(() => {
      globalThis.__adsKv = saved;
    });
}

// --- GET /api/ads ---

test('GET /api/ads: KV未設定は {version:0, slots:{}, affiliates:{}}', async () => {
  await withAdsKv(null, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('GET', '/api/ads');
    await route.handler({ query: {}, headers: {} }, res);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.body, { version: 0, slots: {}, affiliates: {} });
  });
});

test('GET /api/ads: KVありで設定(affiliates込み)がそのまま返る', async () => {
  const config = {
    version: 3,
    slots: { search_ad: { type: 'admob', unitId: 'x', audience: 'free' } },
    affiliates: { rakuten: '06de2a6d.f8aad016.06de2a6e.ee8d6798' },
  };
  const kv = createMockKv({ config: JSON.stringify(config) });
  await withAdsKv(kv, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('GET', '/api/ads');
    await route.handler({ query: {}, headers: {} }, res);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.body, config);
  });
});

test('GET /api/ads: affiliatesキーが無い旧形式KVでも空affiliatesで補完される', async () => {
  const config = { version: 2, slots: {} };
  const kv = createMockKv({ config: JSON.stringify(config) });
  await withAdsKv(kv, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('GET', '/api/ads');
    await route.handler({ query: {}, headers: {} }, res);
    assert.deepEqual(res.body, { version: 2, slots: {}, affiliates: {} });
  });
});

test('GET /api/ads: JSON破損時は空応答({version:0, slots:{}, affiliates:{}})を握りつぶして返す', async () => {
  const kv = createMockKv({ config: '{invalid json' });
  await withAdsKv(kv, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('GET', '/api/ads');
    await route.handler({ query: {}, headers: {} }, res);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.body, { version: 0, slots: {}, affiliates: {} });
  });
});

test('GET /api/ads: KVキー無し(get→null)も空応答', async () => {
  const kv = createMockKv({});
  await withAdsKv(kv, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('GET', '/api/ads');
    await route.handler({ query: {}, headers: {} }, res);
    assert.deepEqual(res.body, { version: 0, slots: {}, affiliates: {} });
  });
});

test('GET /api/ads: 60秒キャッシュにより2回目はKV.getが呼ばれない', async () => {
  const config = { version: 1, slots: {} };
  const kv = createMockKv({ config: JSON.stringify(config) });
  await withAdsKv(kv, async () => {
    const routes = freshRoutes();
    const route = routes.match('GET', '/api/ads');

    const res1 = createMockRes();
    await route.handler({ query: {}, headers: {} }, res1);
    const res2 = createMockRes();
    await route.handler({ query: {}, headers: {} }, res2);

    assert.equal(kv.getCalls.length, 1);
    assert.deepEqual(res1.body, { ...config, affiliates: {} });
    assert.deepEqual(res2.body, { ...config, affiliates: {} });
  });
});

// --- POST /api/ads/event ---

test('POST /api/ads/event: 正常時にKVカウンタが加算される(get→put)', async () => {
  const kv = createMockKv({});
  await withAdsKv(kv, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('POST', '/api/ads/event');
    await route.handler(
      { query: {}, headers: {}, body: { slot: 'products_bottom', adId: 'rakuten-books', kind: 'impression' } },
      res
    );
    assert.equal(res.statusCode, 200);
    assert.equal(kv.putCalls.length, 1);
    const [key, value] = kv.putCalls[0];
    assert.match(key, /^stats:\d{4}-\d{2}-\d{2}:rakuten-books:impression$/);
    assert.equal(value, '1');
  });
});

test('POST /api/ads/event: 2回呼ぶと2になる', async () => {
  const kv = createMockKv({});
  await withAdsKv(kv, async () => {
    const routes = freshRoutes();
    const route = routes.match('POST', '/api/ads/event');
    const body = { slot: 'products_bottom', adId: 'rakuten-books', kind: 'click' };

    await route.handler({ query: {}, headers: {}, body }, createMockRes());
    await route.handler({ query: {}, headers: {}, body }, createMockRes());

    assert.equal(kv.putCalls.length, 2);
    assert.equal(kv.putCalls[1][1], '2');
  });
});

test('POST /api/ads/event: 不正kindは400', async () => {
  const kv = createMockKv({});
  await withAdsKv(kv, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('POST', '/api/ads/event');
    await route.handler(
      { query: {}, headers: {}, body: { slot: 'products_bottom', adId: 'x', kind: 'view' } },
      res
    );
    assert.equal(res.statusCode, 400);
    assert.equal(res.body.error, 'invalid_request');
    assert.equal(kv.putCalls.length, 0);
  });
});

test('POST /api/ads/event: 空slotは400', async () => {
  const kv = createMockKv({});
  await withAdsKv(kv, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('POST', '/api/ads/event');
    await route.handler(
      { query: {}, headers: {}, body: { slot: '', adId: 'x', kind: 'impression' } },
      res
    );
    assert.equal(res.statusCode, 400);
    assert.equal(res.body.error, 'invalid_request');
  });
});

test('POST /api/ads/event: 空adIdは400', async () => {
  const kv = createMockKv({});
  await withAdsKv(kv, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('POST', '/api/ads/event');
    await route.handler(
      { query: {}, headers: {}, body: { slot: 'products_bottom', adId: '', kind: 'impression' } },
      res
    );
    assert.equal(res.statusCode, 400);
    assert.equal(res.body.error, 'invalid_request');
  });
});

test('POST /api/ads/event: 65文字超のslot/adIdは400', async () => {
  const kv = createMockKv({});
  await withAdsKv(kv, async () => {
    const routes = freshRoutes();
    const route = routes.match('POST', '/api/ads/event');
    const longStr = 'a'.repeat(65);

    const res1 = createMockRes();
    await route.handler(
      { query: {}, headers: {}, body: { slot: longStr, adId: 'x', kind: 'impression' } },
      res1
    );
    assert.equal(res1.statusCode, 400);

    const res2 = createMockRes();
    await route.handler(
      { query: {}, headers: {}, body: { slot: 'products_bottom', adId: longStr, kind: 'impression' } },
      res2
    );
    assert.equal(res2.statusCode, 400);
  });
});

test('POST /api/ads/event: KVなしでも200(アプリを失敗させない)', async () => {
  await withAdsKv(null, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('POST', '/api/ads/event');
    await route.handler(
      { query: {}, headers: {}, body: { slot: 'products_bottom', adId: 'x', kind: 'impression' } },
      res
    );
    assert.equal(res.statusCode, 200);
  });
});
