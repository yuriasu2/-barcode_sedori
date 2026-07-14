'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const routes = require('../src/routes');

// --- isProRequest 単体 ---

test('isProRequest: X-App-Plan=pro は true(大文字小文字・ヘッダー名の揺れ許容)', () => {
  assert.equal(routes.isProRequest({ 'x-app-plan': 'pro' }), true);
  assert.equal(routes.isProRequest({ 'X-App-Plan': 'PRO' }), true);
  assert.equal(routes.isProRequest({ 'x-app-plan': 'Pro' }), true);
});

test('isProRequest: free / 未指定 / 非文字列 / その他値は false(安全側=無料)', () => {
  assert.equal(routes.isProRequest({ 'x-app-plan': 'free' }), false);
  assert.equal(routes.isProRequest({}), false);
  assert.equal(routes.isProRequest(null), false);
  assert.equal(routes.isProRequest(undefined), false);
  assert.equal(routes.isProRequest({ 'x-app-plan': 'gold' }), false);
  assert.equal(routes.isProRequest({ 'x-app-plan': '' }), false);
});

// --- ルートゲート(無料は403) ---

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

test('ゲート: 無料(ヘッダーなし)は /api/offers?source=keepa を403 plan_required', async () => {
  const res = createMockRes();
  const route = routes.match('GET', '/api/offers');
  await route.handler({ query: { asin: 'B000TEST', source: 'keepa' }, headers: {} }, res);
  assert.equal(res.statusCode, 403);
  assert.equal(res.body.error, 'plan_required');
});

test('ゲート: 無料でも /api/offers?source=spapi は403にしない(SP-APIはBYOで開放)', async () => {
  // SP-API認証情報が無ければ別の理由(503等)になるが、少なくとも plan_required 403 にはならないことを確認。
  const res = createMockRes();
  const route = routes.match('GET', '/api/offers');
  await route.handler({ query: { asin: 'B000TEST', source: 'spapi' }, headers: {} }, res);
  assert.notEqual(res.body && res.body.error, 'plan_required');
});

test('ゲート: 無料は /api/graph を403 plan_required(グラフはPro限定)', async () => {
  const res = createMockRes();
  const route = routes.match('GET', '/api/graph');
  await route.handler({ query: { asin: 'B000TEST' }, headers: {} }, res);
  assert.equal(res.statusCode, 403);
  assert.equal(res.body.error, 'plan_required');
});
