'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const routes = require('../src/routes');
const ipRateLimit = require('../src/ipRateLimit');
const keepaThrottle = require('../src/keepaThrottle');

test('clientIpOf: CF-Connecting-IPを読む。無ければnull', () => {
  assert.equal(routes.clientIpOf({ 'cf-connecting-ip': '203.0.113.9' }), '203.0.113.9');
  assert.equal(routes.clientIpOf({}), null);
  assert.equal(routes.clientIpOf(null), null);
});

test('/api/search: 同一IPが上限を超えると429 rate_limited(Keepa経路)', async () => {
  routes.searchCache.clear();
  routes.deviceQuota._reset();
  ipRateLimit._reset();
  ipRateLimit._setDurableBinding(null); // インメモリ経路を強制

  const headers = {
    'cf-connecting-ip': '198.51.100.7',
    'x-device-id': 'device-rate-limit',
    'x-keepa-key': 'dummy-byo-key', // BYOでも除外されないことの確認を兼ねる
  };

  // 上限(既定回数)まで先に消費しておく。
  for (let i = 0; i < ipRateLimit.DEFAULT_LIMIT_PER_MIN; i += 1) {
    await ipRateLimit.checkAndCount('198.51.100.7');
  }

  const res = {
    statusCode: 200,
    body: undefined,
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
  };
  const route = routes.match('GET', '/api/search');
  await route.handler({ query: { code: '9784560017838' }, headers }, res);

  assert.equal(res.statusCode, 429);
  assert.equal(res.body.error, 'rate_limited');

  ipRateLimit._setDurableBinding(undefined);
});

test('/api/search: キャッシュヒットでもcomputeQuota呼び出し前にIPレート制限を消費する(DoS対策)', async () => {
  routes.searchCache.clear();
  routes.deviceQuota._reset();
  ipRateLimit._reset();
  ipRateLimit._setDurableBinding(null);

  // キャッシュへ直接仕込む(Keepaを呼ばずにヒットさせる)。
  routes.searchCache.set('keepa:9784560017838', { asin: 'B00CACHED', source: 'keepa' });

  const headers = {
    'cf-connecting-ip': '198.51.100.8',
    'x-device-id': 'device-cache-hit',
    // process.env.KEEPA_API_KEY未設定でも/api/searchのKeepa経路(cachedチェックを含む
    // if (keepaApiKey)ブロック)へ入るようにBYOキーを付ける。無いとkeepaApiKeyが偽になり、
    // spapi_credentials_missing(503)で早期リターンしてキャッシュヒット判定まで届かない。
    'x-keepa-key': 'dummy-byo-key',
  };
  const res = {
    statusCode: 200,
    body: undefined,
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
  };
  const route = routes.match('GET', '/api/search');
  await route.handler({ query: { code: '9784560017838' }, headers }, res);

  assert.equal(res.statusCode, 200);
  // キャッシュヒットでもカウンタが1消費されているはず(computeQuota経由のDO起動を
  // deviceIdの自己申告だけで無制限に許すと、レート制限が無い状態と同じになるため)。
  const after = await ipRateLimit.checkAndCount('198.51.100.8');
  assert.equal(after.remaining, ipRateLimit.DEFAULT_LIMIT_PER_MIN - 2);

  ipRateLimit._setDurableBinding(undefined);
});

test('/api/search: キャッシュヒット経路でIP制限に引っかかるとcomputeQuotaを呼ばずに429を返す', async () => {
  routes.searchCache.clear();
  routes.deviceQuota._reset();
  ipRateLimit._reset();
  ipRateLimit._setDurableBinding(null);

  routes.searchCache.set('keepa:9784560017838', { asin: 'B00CACHED', source: 'keepa' });

  const ip = '198.51.100.9';
  for (let i = 0; i < ipRateLimit.DEFAULT_LIMIT_PER_MIN; i += 1) {
    await ipRateLimit.checkAndCount(ip);
  }

  const originalComputeQuota = routes.deviceQuota.computeQuota;
  let computeQuotaCalled = false;
  routes.deviceQuota.computeQuota = async (...args) => {
    computeQuotaCalled = true;
    return originalComputeQuota(...args);
  };

  try {
    const headers = {
      'cf-connecting-ip': ip,
      'x-device-id': 'device-cache-hit-limited',
      'x-keepa-key': 'dummy-byo-key',
    };
    const res = {
      statusCode: 200,
      body: undefined,
      status(code) { this.statusCode = code; return this; },
      json(body) { this.body = body; return this; },
    };
    const route = routes.match('GET', '/api/search');
    await route.handler({ query: { code: '9784560017838' }, headers }, res);

    assert.equal(res.statusCode, 429);
    assert.equal(res.body.error, 'rate_limited');
    assert.equal(computeQuotaCalled, false, 'IP制限で弾かれた場合computeQuotaは呼ばれないはず');
  } finally {
    routes.deviceQuota.computeQuota = originalComputeQuota;
    ipRateLimit._setDurableBinding(undefined);
  }
});

test('/api/search: キャッシュヒット経路でIP制限が正常なときは従来通り200で結果を返す(回帰)', async () => {
  routes.searchCache.clear();
  routes.deviceQuota._reset();
  ipRateLimit._reset();
  ipRateLimit._setDurableBinding(null);

  routes.searchCache.set('keepa:9784560017838', { asin: 'B00CACHED', source: 'keepa' });

  const headers = {
    'cf-connecting-ip': '198.51.100.10',
    'x-device-id': 'device-cache-hit-ok',
    'x-keepa-key': 'dummy-byo-key',
  };
  const res = {
    statusCode: 200,
    body: undefined,
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
  };
  const route = routes.match('GET', '/api/search');
  await route.handler({ query: { code: '9784560017838' }, headers }, res);

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.asin, 'B00CACHED');
  assert.ok(res.body.quota, 'quotaフィールドが付与されているはず');

  ipRateLimit._setDurableBinding(undefined);
});

test('/api/quota: IP制限に引っかかるとcomputeQuotaを呼ばずに429を返す', async () => {
  routes.deviceQuota._reset();
  ipRateLimit._reset();
  ipRateLimit._setDurableBinding(null);

  const ip = '198.51.100.20';
  for (let i = 0; i < ipRateLimit.DEFAULT_LIMIT_PER_MIN; i += 1) {
    await ipRateLimit.checkAndCount(ip);
  }

  const originalComputeQuota = routes.deviceQuota.computeQuota;
  let computeQuotaCalled = false;
  routes.deviceQuota.computeQuota = async (...args) => {
    computeQuotaCalled = true;
    return originalComputeQuota(...args);
  };

  try {
    const headers = {
      'cf-connecting-ip': ip,
      'x-device-id': 'device-quota-limited',
    };
    const res = {
      statusCode: 200,
      body: undefined,
      status(code) { this.statusCode = code; return this; },
      json(body) { this.body = body; return this; },
    };
    const route = routes.match('GET', '/api/quota');
    await route.handler({ query: {}, headers }, res);

    assert.equal(res.statusCode, 429);
    assert.equal(res.body.error, 'rate_limited');
    assert.equal(computeQuotaCalled, false, 'IP制限で弾かれた場合computeQuotaは呼ばれないはず');
  } finally {
    routes.deviceQuota.computeQuota = originalComputeQuota;
    ipRateLimit._setDurableBinding(undefined);
  }
});

test('/api/quota: IP制限が正常なときは従来通り200でquotaを返す(回帰)', async () => {
  routes.deviceQuota._reset();
  ipRateLimit._reset();
  ipRateLimit._setDurableBinding(null);

  const headers = {
    'cf-connecting-ip': '198.51.100.21',
    'x-device-id': 'device-quota-ok',
  };
  const res = {
    statusCode: 200,
    body: undefined,
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
  };
  const route = routes.match('GET', '/api/quota');
  await route.handler({ query: {}, headers }, res);

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.unitsRemaining, 5);

  ipRateLimit._setDurableBinding(undefined);
});

test('/api/graph-data: キャッシュヒット経路でIP制限に引っかかるとcomputeQuotaを呼ばずに429を返す', async () => {
  routes.graphDataCache.clear();
  routes.deviceQuota._reset();
  ipRateLimit._reset();
  ipRateLimit._setDurableBinding(null);

  routes.graphDataCache.set(routes.graphDataCacheKey('B00CACHEDGRAPH'), { asin: 'B00CACHEDGRAPH', series: {} });

  const ip = '198.51.100.30';
  for (let i = 0; i < ipRateLimit.DEFAULT_LIMIT_PER_MIN; i += 1) {
    await ipRateLimit.checkAndCount(ip);
  }

  const originalComputeQuota = routes.deviceQuota.computeQuota;
  let computeQuotaCalled = false;
  routes.deviceQuota.computeQuota = async (...args) => {
    computeQuotaCalled = true;
    return originalComputeQuota(...args);
  };

  try {
    const headers = {
      'cf-connecting-ip': ip,
      'x-device-id': 'device-graph-cache-hit-limited',
      'x-keepa-key': 'dummy-byo-key',
    };
    const res = {
      statusCode: 200,
      body: undefined,
      status(code) { this.statusCode = code; return this; },
      json(body) { this.body = body; return this; },
    };
    const route = routes.match('GET', '/api/graph-data');
    await route.handler({ query: { asin: 'B00CACHEDGRAPH' }, headers }, res);

    assert.equal(res.statusCode, 429);
    assert.equal(res.body.error, 'rate_limited');
    assert.equal(computeQuotaCalled, false, 'IP制限で弾かれた場合computeQuotaは呼ばれないはず');
  } finally {
    routes.deviceQuota.computeQuota = originalComputeQuota;
    ipRateLimit._setDurableBinding(undefined);
  }
});

test('/api/graph-data: キャッシュヒット経路でIP制限が正常なときは従来通り200で結果を返す(回帰)', async () => {
  routes.graphDataCache.clear();
  routes.deviceQuota._reset();
  ipRateLimit._reset();
  ipRateLimit._setDurableBinding(null);

  routes.graphDataCache.set(routes.graphDataCacheKey('B00CACHEDGRAPH2'), { asin: 'B00CACHEDGRAPH2', series: {} });

  const headers = {
    'cf-connecting-ip': '198.51.100.31',
    'x-device-id': 'device-graph-cache-hit-ok',
    'x-keepa-key': 'dummy-byo-key',
  };
  const res = {
    statusCode: 200,
    body: undefined,
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
  };
  const route = routes.match('GET', '/api/graph-data');
  await route.handler({ query: { asin: 'B00CACHEDGRAPH2' }, headers }, res);

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.asin, 'B00CACHEDGRAPH2');
  assert.ok(res.body.quota, 'quotaフィールドが付与されているはず');

  ipRateLimit._setDurableBinding(undefined);
});

test('/api/graph-data: 事前チェック経路(未キャッシュ)でIP制限に引っかかるとcomputeQuotaを呼ばずに429を返す', async () => {
  routes.graphDataCache.clear();
  routes.deviceQuota._reset();
  ipRateLimit._reset();
  ipRateLimit._setDurableBinding(null);

  const ip = '198.51.100.32';
  for (let i = 0; i < ipRateLimit.DEFAULT_LIMIT_PER_MIN; i += 1) {
    await ipRateLimit.checkAndCount(ip);
  }

  const originalComputeQuota = routes.deviceQuota.computeQuota;
  let computeQuotaCalled = false;
  routes.deviceQuota.computeQuota = async (...args) => {
    computeQuotaCalled = true;
    return originalComputeQuota(...args);
  };

  try {
    const headers = {
      'cf-connecting-ip': ip,
      'x-device-id': 'device-graph-precheck-limited',
      'x-keepa-key': 'dummy-byo-key',
    };
    const res = {
      statusCode: 200,
      body: undefined,
      status(code) { this.statusCode = code; return this; },
      json(body) { this.body = body; return this; },
    };
    const route = routes.match('GET', '/api/graph-data');
    await route.handler({ query: { asin: 'B00UNCACHEDGRAPH' }, headers }, res);

    assert.equal(res.statusCode, 429);
    assert.equal(res.body.error, 'rate_limited');
    assert.equal(computeQuotaCalled, false, 'IP制限で弾かれた場合computeQuotaは呼ばれないはず');
  } finally {
    routes.deviceQuota.computeQuota = originalComputeQuota;
    ipRateLimit._setDurableBinding(undefined);
  }
});

// ---------------------------------------------------------------------------
// /api/keepa-throttle-demo/seed, /probe — 認証無しで公開されているデモ専用エンドポイント。
// 'demo'インスタンス限定でDOの大量生成は起きないが、連打を防ぐ手段が無かったためIP単位の
// レート制限を追加した(3dd8ad7の/api/quota・/api/searchと同じ理由)。
// ---------------------------------------------------------------------------

test('POST /api/keepa-throttle-demo/seed: IP制限に引っかかるとseedDemoStateを呼ばずに429 rate_limitedを返す', async () => {
  ipRateLimit._reset();
  ipRateLimit._setDurableBinding(null);

  const ip = '198.51.100.40';
  for (let i = 0; i < ipRateLimit.DEFAULT_LIMIT_PER_MIN; i += 1) {
    await ipRateLimit.checkAndCount(ip);
  }

  const originalSeedDemoState = keepaThrottle.seedDemoState;
  let seedDemoStateCalled = false;
  keepaThrottle.seedDemoState = async (...args) => {
    seedDemoStateCalled = true;
    return originalSeedDemoState(...args);
  };

  try {
    const headers = { 'cf-connecting-ip': ip };
    const res = {
      statusCode: 200,
      body: undefined,
      status(code) { this.statusCode = code; return this; },
      json(body) { this.body = body; return this; },
    };
    const route = routes.match('POST', '/api/keepa-throttle-demo/seed');
    await route.handler({ query: { tokens: '3' }, headers }, res);

    assert.equal(res.statusCode, 429);
    assert.equal(res.body.error, 'rate_limited');
    assert.equal(seedDemoStateCalled, false, 'IP制限で弾かれた場合seedDemoStateは呼ばれないはず');
  } finally {
    keepaThrottle.seedDemoState = originalSeedDemoState;
    ipRateLimit._setDurableBinding(undefined);
  }
});

test('POST /api/keepa-throttle-demo/seed: IP制限が正常なときは従来通り200でsnapshotを返す(回帰)', async () => {
  ipRateLimit._reset();
  ipRateLimit._setDurableBinding(null);

  const headers = { 'cf-connecting-ip': '198.51.100.41' };
  const res = {
    statusCode: 200,
    body: undefined,
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
  };
  const route = routes.match('POST', '/api/keepa-throttle-demo/seed');
  await route.handler({ query: { tokens: '3' }, headers }, res);

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.ok, true);
  assert.equal(res.body.snapshot.tokensEstimate, 3);

  ipRateLimit._setDurableBinding(undefined);
});

test('POST /api/keepa-throttle-demo/probe: IP制限に引っかかるとacquireを呼ばずに429 rate_limitedを返す', async () => {
  ipRateLimit._reset();
  ipRateLimit._setDurableBinding(null);

  const ip = '198.51.100.42';
  for (let i = 0; i < ipRateLimit.DEFAULT_LIMIT_PER_MIN; i += 1) {
    await ipRateLimit.checkAndCount(ip);
  }

  const originalAcquire = keepaThrottle.acquire;
  let acquireCalled = false;
  keepaThrottle.acquire = async (...args) => {
    acquireCalled = true;
    return originalAcquire(...args);
  };

  try {
    const headers = { 'cf-connecting-ip': ip };
    const res = {
      statusCode: 200,
      body: undefined,
      status(code) { this.statusCode = code; return this; },
      json(body) { this.body = body; return this; },
    };
    const route = routes.match('POST', '/api/keepa-throttle-demo/probe');
    await route.handler({ query: { priority: 'free' }, headers }, res);

    assert.equal(res.statusCode, 429);
    assert.equal(res.body.error, 'rate_limited');
    assert.equal(acquireCalled, false, 'IP制限で弾かれた場合acquireは呼ばれないはず');
  } finally {
    keepaThrottle.acquire = originalAcquire;
    ipRateLimit._setDurableBinding(undefined);
  }
});

test('POST /api/keepa-throttle-demo/probe: IP制限が正常なときは従来通り200でallowed等を返す(回帰)', async () => {
  ipRateLimit._reset();
  ipRateLimit._setDurableBinding(null);
  await keepaThrottle.seedDemoState({ tokens: 5 });

  const headers = { 'cf-connecting-ip': '198.51.100.43' };
  const res = {
    statusCode: 200,
    body: undefined,
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
  };
  const route = routes.match('POST', '/api/keepa-throttle-demo/probe');
  await route.handler({ query: { priority: 'free' }, headers }, res);

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.priority, 'free');
  assert.equal(res.body.allowed, true);

  ipRateLimit._setDurableBinding(undefined);
});
