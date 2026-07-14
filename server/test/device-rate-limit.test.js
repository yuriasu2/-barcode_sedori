'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const drl = require('../src/deviceRateLimit');

// --- registerAndCheck 単体 ---

test('registerAndCheck: 上限まで加算し、超えるとallowed=false(加算しない)', () => {
  drl._reset();
  const id = 'dev-A';
  assert.deepEqual(drl.registerAndCheck(id, 3), { allowed: true, count: 1 });
  assert.deepEqual(drl.registerAndCheck(id, 3), { allowed: true, count: 2 });
  assert.deepEqual(drl.registerAndCheck(id, 3), { allowed: true, count: 3 });
  assert.deepEqual(drl.registerAndCheck(id, 3), { allowed: false, count: 3 });
  assert.deepEqual(drl.registerAndCheck(id, 3), { allowed: false, count: 3 });
});

test('registerAndCheck: deviceId無し/空は制限しない(後方互換)', () => {
  drl._reset();
  assert.deepEqual(drl.registerAndCheck(null, 1), { allowed: true, count: 0 });
  assert.deepEqual(drl.registerAndCheck(undefined, 1), { allowed: true, count: 0 });
  assert.deepEqual(drl.registerAndCheck('', 1), { allowed: true, count: 0 });
});

test('registerAndCheck: デバイスごとに独立してカウントする', () => {
  drl._reset();
  assert.deepEqual(drl.registerAndCheck('A', 1), { allowed: true, count: 1 });
  assert.deepEqual(drl.registerAndCheck('A', 1), { allowed: false, count: 1 });
  assert.deepEqual(drl.registerAndCheck('B', 1), { allowed: true, count: 1 });
});

test('registerAndCheck: 日付が変わればカウントがリセットされる', () => {
  drl._reset();
  drl.registerAndCheck('A', 1);
  assert.deepEqual(drl.registerAndCheck('A', 1), { allowed: false, count: 1 });
  // 内部の日付を過去日に書き換え、翌日をシミュレート
  drl._counts.set('A', { date: '2000-1-1', count: 1 });
  assert.deepEqual(drl.registerAndCheck('A', 1), { allowed: true, count: 1 });
});

// --- ルート結合(/api/search の429ゲート) ---

test('ルート: 無料デバイスが上限超で /api/search が429 daily_limit_exceeded', async () => {
  const saved = process.env.FREE_DEVICE_DAILY_LIMIT;
  process.env.FREE_DEVICE_DAILY_LIMIT = '1';
  delete require.cache[require.resolve('../src/routes')];
  delete require.cache[require.resolve('../src/deviceRateLimit')];
  const routes = require('../src/routes');
  const freshDrl = require('../src/deviceRateLimit');
  freshDrl._reset();

  const mk = () => ({
    statusCode: 200,
    body: null,
    status(c) { this.statusCode = c; return this; },
    json(b) { this.body = b; return this; },
  });

  try {
    const route = routes.match('GET', '/api/search');

    // 1回目: 上限1内 → ゲートは通過(SP-API/Keepa未設定で別応答になるが daily_limit ではない)
    const res1 = mk();
    await route.handler({ query: { code: '9784000000000' }, headers: { 'x-device-id': 'DEV1' } }, res1);
    assert.notEqual(res1.body && res1.body.error, 'daily_limit_exceeded');

    // 2回目: 上限超 → 429
    const res2 = mk();
    await route.handler({ query: { code: '9784000000000' }, headers: { 'x-device-id': 'DEV1' } }, res2);
    assert.equal(res2.statusCode, 429);
    assert.equal(res2.body.error, 'daily_limit_exceeded');
  } finally {
    if (saved === undefined) delete process.env.FREE_DEVICE_DAILY_LIMIT;
    else process.env.FREE_DEVICE_DAILY_LIMIT = saved;
    delete require.cache[require.resolve('../src/routes')];
    delete require.cache[require.resolve('../src/deviceRateLimit')];
  }
});

test('ルート: Proは上限を無視して429にならない', async () => {
  const saved = process.env.FREE_DEVICE_DAILY_LIMIT;
  process.env.FREE_DEVICE_DAILY_LIMIT = '1';
  delete require.cache[require.resolve('../src/routes')];
  delete require.cache[require.resolve('../src/deviceRateLimit')];
  const routes = require('../src/routes');
  const freshDrl = require('../src/deviceRateLimit');
  freshDrl._reset();

  const mk = () => ({
    statusCode: 200,
    body: null,
    status(c) { this.statusCode = c; return this; },
    json(b) { this.body = b; return this; },
  });

  try {
    const route = routes.match('GET', '/api/search');
    const headers = { 'x-device-id': 'DEVPRO', 'x-app-plan': 'pro' };
    // 何度呼んでも daily_limit_exceeded にはならない
    for (let i = 0; i < 5; i += 1) {
      const res = mk();
      await route.handler({ query: { code: '9784000000000' }, headers }, res);
      assert.notEqual(res.body && res.body.error, 'daily_limit_exceeded');
    }
  } finally {
    if (saved === undefined) delete process.env.FREE_DEVICE_DAILY_LIMIT;
    else process.env.FREE_DEVICE_DAILY_LIMIT = saved;
    delete require.cache[require.resolve('../src/routes')];
    delete require.cache[require.resolve('../src/deviceRateLimit')];
  }
});
