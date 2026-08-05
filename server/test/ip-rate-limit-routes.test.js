'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const routes = require('../src/routes');
const ipRateLimit = require('../src/ipRateLimit');

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

test('/api/search: キャッシュヒットはレート制限を消費しない', async () => {
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
  // キャッシュヒットではカウンタが動いていないため、次の1回目が必ず許可される。
  const after = await ipRateLimit.checkAndCount('198.51.100.8');
  assert.equal(after.remaining, ipRateLimit.DEFAULT_LIMIT_PER_MIN - 1);

  ipRateLimit._setDurableBinding(undefined);
});
