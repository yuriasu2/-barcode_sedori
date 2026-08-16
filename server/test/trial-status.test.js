'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

function freshRoutes() {
  delete require.cache[require.resolve('../src/routes')];
  delete require.cache[require.resolve('../src/sellerTrial')];
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

test('GET /api/trial-status: X-Spapi-Seller-Idが無ければ403 seller_id_required', async () => {
  const routes = freshRoutes();
  const res = createMockRes();
  const route = routes.match('GET', '/api/trial-status');
  await route.handler({ headers: { 'x-spapi-refresh-token': 'rt' } }, res);
  assert.equal(res.statusCode, 403);
  assert.equal(res.body.error, 'seller_id_required');
});

test('GET /api/trial-status: X-Spapi-Refresh-Tokenが無ければ403 spapi_link_required', async () => {
  const routes = freshRoutes();
  const res = createMockRes();
  const route = routes.match('GET', '/api/trial-status');
  await route.handler({ headers: { 'x-spapi-seller-id': 'SELLER123' } }, res);
  assert.equal(res.statusCode, 403);
  assert.equal(res.body.error, 'spapi_link_required');
});

test('GET /api/trial-status: 両方が無ければ403(seller_id_requiredが優先)', async () => {
  const routes = freshRoutes();
  const res = createMockRes();
  const route = routes.match('GET', '/api/trial-status');
  await route.handler({ headers: {} }, res);
  assert.equal(res.statusCode, 403);
  assert.equal(res.body.error, 'seller_id_required');
});

test('GET /api/trial-status: 両方あれば新規お試しを発行しactive:trueとremainingDays=7を返す', async () => {
  const routes = freshRoutes();
  const res = createMockRes();
  const route = routes.match('GET', '/api/trial-status');
  await route.handler(
    { headers: { 'x-spapi-seller-id': 'SELLER-NEW', 'x-spapi-refresh-token': 'rt' } },
    res
  );
  assert.equal(res.statusCode, 200);
  assert.equal(res.body.active, true);
  assert.equal(res.body.remainingDays, 7);
  assert.equal(typeof res.body.startedAt, 'number');
  assert.equal(typeof res.body.expiresAt, 'number');
});

test('GET /api/trial-status: 期限切れのお試しはactive:false・remainingDays:0を返す', async () => {
  const routes = freshRoutes();
  const sellerTrial = routes.sellerTrial;
  const sellerId = 'SELLER-EXPIRED';
  const eightDaysAgo = Date.now() - 8 * 24 * 60 * 60 * 1000;
  await sellerTrial.getOrStart(sellerId, eightDaysAgo);

  const res = createMockRes();
  const route = routes.match('GET', '/api/trial-status');
  await route.handler(
    { headers: { 'x-spapi-seller-id': sellerId, 'x-spapi-refresh-token': 'rt' } },
    res
  );
  assert.equal(res.statusCode, 200);
  assert.equal(res.body.active, false);
  assert.equal(res.body.remainingDays, 0);
});

test('GET /api/trial-status: write-once — 同一seller-idへの2回目の呼び出しでも開始日時は変わらない', async () => {
  const routes = freshRoutes();
  const route = routes.match('GET', '/api/trial-status');
  const headers = { 'x-spapi-seller-id': 'SELLER-REPEAT', 'x-spapi-refresh-token': 'rt' };

  const res1 = createMockRes();
  await route.handler({ headers }, res1);
  const res2 = createMockRes();
  await route.handler({ headers }, res2);

  assert.equal(res1.body.startedAt, res2.body.startedAt);
});

test('GET /api/trial-status: 残り日数は切り上げ(最終端数日は1日として見せる)', async () => {
  const routes = freshRoutes();
  const sellerTrial = routes.sellerTrial;
  const sellerId = 'SELLER-ALMOST-EXPIRED';
  // 開始から7日 - 1時間経過している状態を作る(残り1時間 → 切り上げでremainingDays=1)。
  const startedAt = Date.now() - (7 * 24 - 1) * 60 * 60 * 1000;
  await sellerTrial.getOrStart(sellerId, startedAt);

  const res = createMockRes();
  const route = routes.match('GET', '/api/trial-status');
  await route.handler(
    { headers: { 'x-spapi-seller-id': sellerId, 'x-spapi-refresh-token': 'rt' } },
    res
  );
  assert.equal(res.statusCode, 200);
  assert.equal(res.body.active, true);
  assert.equal(res.body.remainingDays, 1);
});

// ---------------------------------------------------------------------------
// 脆弱性修正: X-Spapi-Refresh-Tokenは中身を検証しない(存在確認のみ)ため、
// 出品者IDさえ分かれば誰でも他人のお試し期間を開始・消化できてしまう
// (出品者IDはAmazonの商品ページから誰でも取得できる)。トークンの真正性検証は
// コストが掛かるため見送り、代わりに/api/quota・/api/searchと同じパターンで
// IP単位のレート制限を掛け、大量の出品者IDを投入する乱掘り攻撃のコストを上げる。
// ---------------------------------------------------------------------------

test('GET /api/trial-status: IP制限超過時は429 rate_limitedを返し、sellerTrial.getOrStartは呼ばれない', async () => {
  const routes = freshRoutes();
  const ipRateLimit = require('../src/ipRateLimit');
  ipRateLimit._reset();
  ipRateLimit._setDurableBinding(null); // インメモリ経路を強制

  const ip = '198.51.100.55';
  for (let i = 0; i < ipRateLimit.DEFAULT_LIMIT_PER_MIN; i += 1) {
    await ipRateLimit.checkAndCount(ip);
  }

  const sellerTrial = routes.sellerTrial;
  const originalGetOrStart = sellerTrial.getOrStart;
  let getOrStartCalled = false;
  sellerTrial.getOrStart = async (...args) => {
    getOrStartCalled = true;
    return originalGetOrStart(...args);
  };

  const res = createMockRes();
  const route = routes.match('GET', '/api/trial-status');
  await route.handler(
    {
      headers: {
        'cf-connecting-ip': ip,
        'x-spapi-seller-id': 'SELLER-RATE-LIMITED',
        'x-spapi-refresh-token': 'rt',
      },
    },
    res
  );

  assert.equal(res.statusCode, 429);
  assert.equal(res.body.error, 'rate_limited');
  assert.equal(getOrStartCalled, false);

  sellerTrial.getOrStart = originalGetOrStart;
  ipRateLimit._setDurableBinding(undefined);
});
