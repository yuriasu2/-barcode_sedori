'use strict';

const test = require('node:test');
const assert = require('node:assert');

// ESMのDOクラスをCJSテストから読む(quotaDurableObject.jsと同じくdynamic importを使う)
async function loadDoClass() {
  const mod = await import('../src/keepaThrottleDurableObject.js');
  return mod.KeepaThrottleDO;
}

function makeDo(env) {
  // KeepaThrottleDOはstorageを使わない(残量はインメモリ推定、キューはPromise)ため、stateはダミーでよい。
  return loadDoClass().then((KeepaThrottleDO) => new KeepaThrottleDO({}, env));
}

test('KeepaThrottleDO: /acquireは残量があればallowed:true', async () => {
  const doInstance = await makeDo({ KEEPA_BUCKET_CAPACITY: '2', KEEPA_REFILL_PER_MIN: '60' });
  const res = await doInstance.fetch(new Request('https://do/acquire?priority=free', { method: 'POST' }));
  assert.deepEqual(await res.json(), { allowed: true });
});

test('KeepaThrottleDO: /reportで残量0にすると、depth=0の/acquireは即拒否', async () => {
  const doInstance = await makeDo({
    KEEPA_BUCKET_CAPACITY: '10',
    KEEPA_REFILL_PER_MIN: '1',
    KEEPA_QUEUE_DEPTH: '0',
  });
  await doInstance.fetch(new Request('https://do/report?tokensLeft=0', { method: 'POST' }));
  const res = await doInstance.fetch(new Request('https://do/acquire?priority=pro', { method: 'POST' }));
  assert.deepEqual(await res.json(), { allowed: false, reason: 'depth' });
});

test('KeepaThrottleDO: /exhaustedで残量0になる', async () => {
  const doInstance = await makeDo({
    KEEPA_BUCKET_CAPACITY: '10',
    KEEPA_REFILL_PER_MIN: '1',
    KEEPA_QUEUE_DEPTH: '0',
  });
  await doInstance.fetch(new Request('https://do/exhausted', { method: 'POST' }));
  const res = await doInstance.fetch(new Request('https://do/acquire?priority=free', { method: 'POST' }));
  assert.deepEqual(await res.json(), { allowed: false, reason: 'depth' });
});

test('KeepaThrottleDO: 不明なパスは404', async () => {
  const doInstance = await makeDo({});
  const res = await doInstance.fetch(new Request('https://do/unknown', { method: 'POST' }));
  assert.equal(res.status, 404);
});
