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

test('KeepaThrottleDO: /reportで残量0にすると、/acquireは即拒否(exhausted)', async () => {
  const doInstance = await makeDo({
    KEEPA_BUCKET_CAPACITY: '10',
    KEEPA_REFILL_PER_MIN: '1',
  });
  await doInstance.fetch(new Request('https://do/report?tokensLeft=0', { method: 'POST' }));
  const res = await doInstance.fetch(new Request('https://do/acquire?priority=pro', { method: 'POST' }));
  assert.deepEqual(await res.json(), { allowed: false, reason: 'exhausted' });
});

test('KeepaThrottleDO: /exhaustedで残量0になる', async () => {
  const doInstance = await makeDo({
    KEEPA_BUCKET_CAPACITY: '10',
    KEEPA_REFILL_PER_MIN: '1',
  });
  await doInstance.fetch(new Request('https://do/exhausted', { method: 'POST' }));
  const res = await doInstance.fetch(new Request('https://do/acquire?priority=free', { method: 'POST' }));
  assert.deepEqual(await res.json(), { allowed: false, reason: 'exhausted' });
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

test('KeepaThrottleDO: /seed-demoで残量0にすると、/acquireは即拒否(exhausted)', async () => {
  const doInstance = await makeDo({
    KEEPA_BUCKET_CAPACITY: '10',
    KEEPA_REFILL_PER_MIN: '1',
  });
  await doInstance.fetch(new Request('https://do/seed-demo?tokens=0', { method: 'POST' }));
  const res = await doInstance.fetch(new Request('https://do/acquire?priority=free', { method: 'POST' }));
  assert.deepEqual(await res.json(), { allowed: false, reason: 'exhausted' });
});

test('KeepaThrottleDO: 一度もdemoとしてseedされていないインスタンス(=本番の"global"相当)は、/acquire・/report・/exhaustedを呼んでもstorageへ一切書き込まない(M-5a)', async () => {
  const backingMap = new Map();
  const doInstance = await makeDo({ KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' }, backingMap);

  await doInstance.fetch(new Request('https://do/acquire?priority=free', { method: 'POST' }));
  await doInstance.fetch(new Request('https://do/acquire?priority=pro', { method: 'POST' }));
  await doInstance.fetch(new Request('https://do/report?tokensLeft=5', { method: 'POST' }));
  await doInstance.fetch(new Request('https://do/exhausted', { method: 'POST' }));

  // isDemoInstanceは/seed-demoを経由して初めてtrueになる(keepaThrottleDurableObject.jsの
  // isDemoInstanceフラグ参照)。'global'は/seed-demoを絶対に呼ばれないため、この一連の呼び出しで
  // backingMapが空のままであることが、無料枠の書き込み上限を保護する安全設計の核心。
  assert.equal(
    backingMap.size,
    0,
    'demoとして一度もseedされていないDOインスタンスはstorageへ絶対に書き込んではいけない(無料枠書き込み上限の保護)'
  );
});

test('KeepaThrottleDO: 不明なパスは404', async () => {
  const doInstance = await makeDo({});
  const res = await doInstance.fetch(new Request('https://do/unknown', { method: 'POST' }));
  assert.equal(res.status, 404);
});

test('KeepaThrottleDO: DOが退避されてconstructorから作り直されても、seedした値(demoCheckpoint)がstorageから復元される', async () => {
  const env = { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '1' };
  // 同じbackingMapを共有する2つの別インスタンスで、DOの退避→再構築(constructorのやり直し)を再現する。
  const backingMap = new Map();

  const before = await makeDo(env, backingMap);
  await before.fetch(new Request('https://do/seed-demo?tokens=0&ratePerMin=50', { method: 'POST' }));
  // seed後の実状態がdemoCheckpointキーへチェックポイントされていること。
  assert.ok(backingMap.has('demoCheckpoint'));
  assert.equal(backingMap.get('demoCheckpoint').tokens, 0);
  // ここでbeforeを使い捨て、evictされた後の新しいDOオブジェクトを模す。
  const after = await makeDo(env, backingMap);
  const res = await after.fetch(new Request('https://do/acquire?priority=free', { method: 'POST' }));
  // seedしたtokens=0がstorageから復元されていれば、残量0のため即座にNG(exhausted)になるはず。
  // 復元されず満タン(capacity=10)で作り直されていたら誤ってallowed:trueになってしまう。
  assert.deepEqual(await res.json(), { allowed: false, reason: 'exhausted' });
});

test('KeepaThrottleDO: 退避→再構築をまたいでも、経過時間ぶんの補充が正しく引き継がれる', async () => {
  const env = { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '1' };
  const backingMap = new Map();

  const before = await makeDo(env, backingMap);
  await before.fetch(new Request('https://do/seed-demo?tokens=0&refillPerMin=60', { method: 'POST' })); // 1秒に1個

  // 「退避していた間に3秒経過した」ことを模すため、backingMap内のチェックポイントの
  // lastRefillAtを直接3000ms過去へずらす(実際の退避待ちを本当に3秒行うとテストが遅くなるため)。
  const checkpoint = backingMap.get('demoCheckpoint');
  backingMap.set('demoCheckpoint', { ...checkpoint, lastRefillAt: checkpoint.lastRefillAt - 3000 });

  const after = await makeDo(env, backingMap); // 退避→再構築を模した別インスタンス
  const res = await after.fetch(new Request('https://do/acquire?priority=free', { method: 'POST' }));
  // refillPerMin=60(1秒に1個)で3秒経過している想定なので、3個分補充されて許可されるはず。
  // 退避のたびにtokens=0へ巻き戻るバグが直っていなければ、残量0のため即座にNG(exhausted)になる。
  assert.deepEqual(await res.json(), { allowed: true });
});
