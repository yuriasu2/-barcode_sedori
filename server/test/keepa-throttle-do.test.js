'use strict';

const test = require('node:test');
const assert = require('node:assert');

// ESMのDOクラスをCJSテストから読む(quotaDurableObject.jsと同じくdynamic importを使う)
async function loadDoClass() {
  const mod = await import('../src/keepaThrottleDurableObject.js');
  return mod.KeepaThrottleDO;
}

/** state.storageの最小モック(Map1つで代用)。実DOのKV風storage.get/putと同じ形。 */
function makeStorage(backingMap = new Map()) {
  return {
    get: async (key) => backingMap.get(key),
    put: async (key, value) => {
      backingMap.set(key, value);
    },
  };
}

function makeDo(env, backingMap) {
  // 'demo'インスタンスのseed値はstorageへ永続化する(DOの退避対策。
  // keepaThrottleDurableObject.jsのrestoreDemoSeedIfNeeded参照)ため、
  // stateにはstorageモックを渡す。'global'相当のテストではstorageへの書き込みは発生しない。
  return loadDoClass().then(
    (KeepaThrottleDO) => new KeepaThrottleDO({ storage: makeStorage(backingMap) }, env)
  );
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

test('KeepaThrottleDO: /seed-demoはtokens/ratePerMinを注入しスナップショットを返す', async () => {
  const doInstance = await makeDo({ KEEPA_BUCKET_CAPACITY: '100', KEEPA_REFILL_PER_MIN: '60' });
  const res = await doInstance.fetch(
    new Request('https://do/seed-demo?tokens=3&ratePerMin=8', { method: 'POST' })
  );
  const body = await res.json();
  assert.equal(body.tokensEstimate, 3);
  assert.equal(body.consumeRatePerMin, 8);
});

test('KeepaThrottleDO: /seed-demoで残量0にすると、depth=0の/acquireは即拒否', async () => {
  const doInstance = await makeDo({
    KEEPA_BUCKET_CAPACITY: '10',
    KEEPA_REFILL_PER_MIN: '1',
    KEEPA_QUEUE_DEPTH: '0',
  });
  await doInstance.fetch(new Request('https://do/seed-demo?tokens=0', { method: 'POST' }));
  const res = await doInstance.fetch(new Request('https://do/acquire?priority=free', { method: 'POST' }));
  assert.deepEqual(await res.json(), { allowed: false, reason: 'depth' });
});

test('KeepaThrottleDO: 不明なパスは404', async () => {
  const doInstance = await makeDo({});
  const res = await doInstance.fetch(new Request('https://do/unknown', { method: 'POST' }));
  assert.equal(res.status, 404);
});

test('KeepaThrottleDO: DOが退避されてconstructorから作り直されても、seedした値がstorageから復元される', async () => {
  const env = { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '1', KEEPA_QUEUE_DEPTH: '0' };
  // 同じbackingMapを共有する2つの別インスタンスで、DOの退避→再構築(constructorのやり直し)を再現する。
  const backingMap = new Map();

  const before = await makeDo(env, backingMap);
  await before.fetch(new Request('https://do/seed-demo?tokens=0&ratePerMin=50', { method: 'POST' }));
  // ここでbeforeを使い捨て、evictされた後の新しいDOオブジェクトを模す。
  const after = await makeDo(env, backingMap);
  const res = await after.fetch(new Request('https://do/acquire?priority=free', { method: 'POST' }));
  // seedしたtokens=0がstorageから復元されていれば、depth=0のため即座にNG(depth)になるはず。
  // 復元されず満タン(capacity=10)で作り直されていたら誤ってallowed:trueになってしまう。
  assert.deepEqual(await res.json(), { allowed: false, reason: 'depth' });
});
