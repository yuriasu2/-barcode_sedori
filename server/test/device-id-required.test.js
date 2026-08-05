'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const routes = require('../src/routes');

function createMockRes() {
  return {
    statusCode: 200,
    body: undefined,
    headers: {},
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

// --- /api/quota ---

test('/api/quota: X-Device-Idが無い無料リクエストは400 device_id_required', async () => {
  const res = createMockRes();
  const route = routes.match('GET', '/api/quota');
  await route.handler({ query: {}, headers: {} }, res);

  assert.equal(res.statusCode, 400);
  assert.equal(res.body.error, 'device_id_required');
});

test('/api/quota: Proは端末IDが無くてもunlimitedを返す(クォータ対象外のため)', async () => {
  const res = createMockRes();
  const route = routes.match('GET', '/api/quota');
  await route.handler({ query: {}, headers: { 'x-app-plan': 'pro' } }, res);

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.unlimited, true);
});

test('/api/quota: X-Device-Idがあれば従来どおり残量を返す', async () => {
  routes.deviceQuota._reset();
  const res = createMockRes();
  const route = routes.match('GET', '/api/quota');
  await route.handler({ query: {}, headers: { 'x-device-id': 'device-a' } }, res);

  assert.equal(res.statusCode, 200);
  assert.equal(typeof res.body.unitsRemaining, 'number');
});

// --- deviceQuota モジュール(多層防御) ---

test('deviceQuota.tryConsume: deviceIdが無ければ拒否する(以前は許可していた)', async () => {
  const result = await routes.deviceQuota.tryConsume(null, 1);
  assert.equal(result.allowed, false);
});

test('deviceQuota.computeQuota: deviceIdが無ければunlimitedを返さない', async () => {
  const quota = await routes.deviceQuota.computeQuota(null);
  assert.notEqual(quota.unlimited, true);
});
