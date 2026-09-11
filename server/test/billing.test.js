'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { evaluate, mergeState } = require('../src/billing/state');
const { issue, verify } = require('../src/billing/tokens');
const { BillingStore } = require('../src/billing/durable');
const { proHeaders } = require('./billing-fixture');
const service = require('../src/billing/service');
const now = 1800000000000;
const tx = { productId: 'jp.sellira.sellerlens.pro.monthly', type: 'Auto-Renewable Subscription', environment: 'Production', originalTransactionId: '1', transactionId: '2', signedDate: now, expiresDate: now + 60000 };
test('paid, trial and cancelled renewal retain paid time; expiry/revocation fail closed', () => {
  assert.equal(evaluate(tx, {}, 1, now).validUntil, now + 60000);
  assert.equal(evaluate(tx, { autoRenewStatus: 0 }, 1, now).validUntil, now + 60000);
  assert.equal(evaluate(tx, {}, 2, now).validUntil, 0);
  assert.equal(evaluate({ ...tx, revocationDate: now }, {}, 1, now).validUntil, 0);
  assert.equal(evaluate({ ...tx, expiresDate: now }, {}, 1, now).validUntil, 0);
});
test('grace deadline is authoritative; billing retry does not grant expired access', () => {
  assert.equal(evaluate({ ...tx, expiresDate: now - 1 }, { gracePeriodExpiresDate: now + 5000 }, 4, now).validUntil, now + 5000);
  assert.equal(evaluate({ ...tx, expiresDate: now - 1 }, {}, 3, now).validUntil, 0);
  assert.throws(() => evaluate({ ...tx, productId: 'other' }, {}, 1, now));
  assert.throws(() => evaluate({ ...tx, environment: 'Xcode' }, {}, 1, now));
});
test('older signed snapshots cannot restore a refunded subscription', () => {
  const refunded = { ...evaluate({ ...tx, revocationDate: now }, {}, 5, now), observedAt: now };
  assert.equal(mergeState(refunded, { ...evaluate(tx, {}, 1, now), signedDate: now - 1 }).validUntil, 0);
  assert.equal(mergeState(refunded, evaluate(tx, {}, 1, now)).validUntil, 0);
});
test('credentials are purpose/session scoped, signed and bounded by expiration', () => {
  const env = { BILLING_TOKEN_KEY_ID: 'v1', BILLING_TOKEN_KEYS: JSON.stringify({ v1: 'a'.repeat(64) }) };
  const token = issue('access', { sid: 's', environment: 'Production' }, now + 1000, env, now);
  assert.equal(verify(token, 'access', env, now).sid, 's');
  assert.throws(() => verify(token, 'session', env, now));
  assert.throws(() => verify(token, 'access', env, now + 1000));
  assert.throws(() => verify(token.slice(0, -8) + 'AAAAAAAA', 'access', env, now));
  assert.throws(() => issue('access', {}, now + 1, {}, now));
  const rotated = { ...env, BILLING_TOKEN_KEY_ID: 'v2', BILLING_TOKEN_KEYS: JSON.stringify({ v1: 'a'.repeat(64), v2: 'b'.repeat(64) }) };
  assert.equal(verify(token, 'access', rotated, now).sid, 's');
});

function storage() {
  const data = new Map();
  return { get: async k => structuredClone(data.get(k)), put: async (k, v) => { data.set(k, structuredClone(v)); }, setAlarm: async () => {} };
}
test('concurrent verification coalesces; duplicate notifications persist before acknowledgement', async () => {
  let calls = 0;
  const store = new BillingStore(storage(), {}, async () => { calls++; return evaluate(tx, {}, 1, now); }, () => now);
  const input = { environment: 'Production', originalTransactionId: '1', force: true };
  const results = await Promise.all(Array.from({ length: 10 }, () => store.run(input)));
  assert.equal(calls, 1);
  assert.equal(results[0].state.validUntil, now + 60000);
  await store.run({ ...input, notification: { id: 'n1', state: null } });
  await store.run({ ...input, notification: { id: 'n1', state: null } });
  assert.equal(calls, 2);
});
test('outage fallback never passes known expiry and never grants an unverified purchase', async () => {
  let clock = now, down = false;
  const store = new BillingStore(storage(), {}, async () => {
    if (down) throw new Error('apple_unavailable');
    return evaluate(tx, {}, 1, now);
  }, () => clock);
  await store.run({}); down = true; clock += 10000;
  assert.equal((await store.run({ force: true })).provisional, true);
  clock = now + 60000;
  await assert.rejects(store.run({ force: true }), /apple_unavailable/);
  const fresh = new BillingStore(storage(), {}, async () => { throw new Error('apple_unavailable'); }, () => now);
  await assert.rejects(fresh.run({}), /apple_unavailable/);
});
test('refund during outage is durable and prevents old proof revival on retry', async () => {
  const db = storage(); let down = false;
  const old = evaluate(tx, {}, 1, now);
  const store = new BillingStore(db, {}, async () => { if (down) throw new Error('apple_unavailable'); return old; }, () => now);
  await store.run({}); down = true;
  const refund = evaluate({ ...tx, signedDate: now + 1, revocationDate: now }, {}, 5, now);
  await assert.rejects(store.run({ notification: { id: 'refund', state: refund } }), /apple_unavailable/);
  await assert.rejects(store.run({}), /apple_unavailable/);
  down = false;
  assert.equal((await store.run({})).state.validUntil, 0);
  assert.equal((await db.get('subscription')).dirty, false);
});
test('storage failure must not acknowledge notification', async () => {
  const db = storage(); db.put = async () => { throw new Error('disk_failed'); };
  const store = new BillingStore(db, {}, async () => evaluate(tx, {}, 1, now), () => now);
  await assert.rejects(store.run({ notification: { id: 'x', state: null } }), /disk_failed/);
});
test('session mismatch and a copied plan header cannot authorize Pro', async () => {
  const res = { status(code) { this.code = code; return this; }, json() {} };
  const forged = { 'x-app-plan': 'pro' };
  assert.equal(await service.authorize({ url: '/api/search', headers: forged }, res), true);
  assert.equal(service.isPro(forged), false);
  const valid = proHeaders();
  assert.equal(await service.authorize({ url: '/api/search', headers: valid }, res), true);
  assert.equal(service.isPro(valid), true);
  valid['x-billing-session'] = issue('session', { sid: 'other' }, Date.now() + 60000);
  assert.equal(await service.authorize({ url: '/api/search', headers: valid }, res), false);
  assert.equal(res.code, 401);
  assert.equal(service.isPro(valid), false);
});
test('Sandbox Pro requests do not consume a shared search/graph limiter', async () => {
  const now = Date.now();
  const headers = {
    authorization: `Bearer ${issue('access', { sid: 'sandbox-session', environment: 'Sandbox', originalTransactionId: 'sandbox-purchase' }, now + 600000)}`,
    'x-billing-session': issue('session', { sid: 'sandbox-session' }, now + 600000),
  };
  let calls = 0;
  const previousBinding = globalThis.__billingDO;
  globalThis.__billingDO = {
    idFromName: name => { calls++; throw new Error(`unexpected billing limiter call: ${name}`); },
    get: () => { throw new Error('unexpected billing limiter call'); },
  };
  const res = { status(code) { this.code = code; return this; }, json(body) { this.body = body; } };
  try {
    assert.equal(await service.authorize({ url: 'https://test/api/search', headers }, res), true);
    assert.equal(service.isPro(headers), true);
    assert.equal(calls, 0);
  } finally {
    globalThis.__billingDO = previousBinding;
  }
});
test('billing request size is bounded before handler/Apple work even without Content-Length', async () => {
  const { MiniRouter } = require('../src/miniRouter');
  const router = new MiniRouter(); let called = false;
  router.post('/api/billing/verify', () => { called = true; });
  const response = await router.fetchHandler()(new Request('https://test/api/billing/verify', { method: 'POST', body: 'a'.repeat(65537) }));
  assert.equal(response.status, 413); assert.equal(called, false);
});

test('verify/restore and refresh require a server session; notification retries are durable', async () => {
  proHeaders();
  const configKeys = ['APPLE_IAP_PRIVATE_KEY', 'APPLE_IAP_KEY_ID', 'APPLE_IAP_ISSUER_ID'];
  const previous = configKeys.map(k => process.env[k]);
  for (const k of configKeys) process.env[k] = 'unit-test-placeholder';
  const apple = require('../src/billing/apple');
  const originalDecode = apple.decode;
  const originalBinding = globalThis.__billingDO;
  const stores = new Map(); let latestCalls = 0;
  const clock = Date.now();
  let state = evaluate({ ...tx, signedDate: clock, expiresDate: clock + 60000 }, {}, 1, clock);
  globalThis.__billingDO = {
    idFromName: name => name,
    get: name => ({ fetch: async (_, options) => {
      if (!stores.has(name)) stores.set(name, new BillingStore(storage(), {}, async () => { latestCalls++; return state; }));
      return Response.json(await stores.get(name).run(JSON.parse(options.body)));
    } }),
  };
  apple.decode = async () => ({ ...tx, signedDate: clock, expiresDate: clock + 60000 });
  try {
    const { MiniRouter } = require('../src/miniRouter');
    const router = new MiniRouter(service.authorize); service.register(router);
    const post = (path, body, session) => router.fetchHandler()(new Request('https://test' + path, {
      method: 'POST', headers: session ? { 'x-billing-session': session } : {}, body: JSON.stringify(body),
    }));
    assert.equal((await post('/api/billing/verify', { signedTransaction: 'proof' })).status, 401);
    const first = await (await post('/api/billing/session', {})).json();
    const purchase = await (await post('/api/billing/verify', { signedTransaction: 'proof' }, first.session)).json();
    assert.equal(purchase.pro, true); assert.equal(latestCalls, 1);
    assert.equal(verify(purchase.accessToken, 'access').sid, first.appAccountToken);
    assert.ok(purchase.expiresAt <= state.expiresDate);
    const second = await (await post('/api/billing/session', {})).json();
    assert.equal((await post('/api/billing/refresh', { refreshToken: purchase.refreshToken }, second.session)).status, 401);
    const restore = await (await post('/api/billing/verify', { signedTransaction: 'proof' }, second.session)).json();
    assert.equal(restore.pro, true); // No appAccountToken on legacy purchase; legitimate second device allowed.
    const refreshed = await (await post('/api/billing/refresh', { refreshToken: purchase.refreshToken }, first.session)).json();
    assert.equal(refreshed.pro, true); assert.equal(latestCalls, 1);
    state = evaluate({ ...tx, signedDate: clock + 1, expiresDate: clock + 60000, revocationDate: clock }, {}, 5, clock);
    apple.decode = async (_, method) => method === 'verifyAndDecodeNotification'
      ? { notificationUUID: 'refund', data: { environment: 'Production', signedTransactionInfo: 'refund' } }
      : { ...tx, signedDate: clock + 1, expiresDate: clock + 60000, revocationDate: clock };
    assert.equal((await post('/api/apple/notifications', { signedPayload: 'notification' })).status, 200);
    assert.equal((await post('/api/apple/notifications', { signedPayload: 'notification' })).status, 200);
    assert.equal(latestCalls, 2);
    const revoked = await (await post('/api/billing/refresh', { refreshToken: purchase.refreshToken }, first.session)).json();
    assert.equal(revoked.pro, false); assert.equal(revoked.accessToken, null);
  } finally {
    apple.decode = originalDecode; globalThis.__billingDO = originalBinding;
    configKeys.forEach((k, i) => { if (previous[i] === undefined) delete process.env[k]; else process.env[k] = previous[i]; });
  }
});
test('rate counter denies excess, survives store recreation and resets at next period', async () => {
  let clock = now;
  const db = storage();
  let store = new BillingStore(db, {}, undefined, () => clock);
  const request = { op: 'limit', limit: 1, daily: true };
  assert.equal((await store.run(request)).allowed, true);
  store = new BillingStore(db, {}, undefined, () => clock);
  assert.equal((await store.run(request)).allowed, false);
  clock += 86400000;
  assert.equal((await store.run(request)).allowed, true);
});
