'use strict';

const test = require('node:test');
const assert = require('node:assert');

const { SharedCache } = require('../src/sharedCache');

/**
 * Cloudflare の caches.default を模したスタブ。
 * URL文字列をキーに Response を保持するだけ。max-ageによる期限切れは再現しない
 * (SharedCache側がenvelopeのexpでも判定することを別テストで確かめるため)。
 */
function createCachesStub() {
  const store = new Map();
  return {
    store,
    default: {
      async match(request) {
        const hit = store.get(request.url);
        return hit ? hit.clone() : undefined;
      },
      async put(request, response) {
        store.set(request.url, response.clone());
      },
    },
  };
}

/** L2(Cache API)を有効にした状態で fn を実行する。 */
async function withCacheApi(fn) {
  const caches = createCachesStub();
  const prevCaches = globalThis.caches;
  const prevOrigin = globalThis.__cacheOrigin;
  globalThis.caches = caches;
  globalThis.__cacheOrigin = 'https://api.example.test';
  try {
    return await fn(caches);
  } finally {
    globalThis.caches = prevCaches;
    globalThis.__cacheOrigin = prevOrigin;
  }
}

test('L2が無い環境(Node/テスト)ではL1だけで従来どおり動く', async () => {
  const cache = new SharedCache({ name: 'search', ttlMs: 1000 });
  await cache.set('keepa:9784560017838', { asin: 'B000TEST' });
  assert.deepEqual(await cache.get('keepa:9784560017838'), { asin: 'B000TEST' });
  cache.clear();
  assert.equal(await cache.get('keepa:9784560017838'), undefined);
});

test('別インスタンス(別isolate相当)からでもL2経由でヒットする', async () => {
  await withCacheApi(async () => {
    const writer = new SharedCache({ name: 'graphdata', ttlMs: 60 * 1000 });
    await writer.set('graphdata:B000AAA', { series: { new: [1, 2] } });

    // 別のisolateで作られたインスタンスのつもり。L1は空だがL2から拾えるはず。
    const reader = new SharedCache({ name: 'graphdata', ttlMs: 60 * 1000 });
    assert.deepEqual(await reader.get('graphdata:B000AAA'), { series: { new: [1, 2] } });

    // L2ヒットはL1へ載せ直され、同じisolate内の2回目はCache API往復なしで引ける。
    assert.equal(reader.size, 1, 'L2ヒットはL1へ載せ直されるべき');
  });
});

test('L2の期限(envelope.exp)が切れていればミス扱いになる', async () => {
  await withCacheApi(async (caches) => {
    const writer = new SharedCache({ name: 'graphdata', ttlMs: 50 });
    await writer.set('graphdata:B000EXPIRED', { series: {} });
    assert.equal(caches.store.size, 1, 'L2へ書かれているべき');

    await new Promise((resolve) => setTimeout(resolve, 60));

    // スタブはmax-ageで消さないため、SharedCache側のexp判定が効かないと古い値を返してしまう。
    const reader = new SharedCache({ name: 'graphdata', ttlMs: 50 });
    assert.equal(await reader.get('graphdata:B000EXPIRED'), undefined);
  });
});

test('L2ヒットをL1へ載せ直すTTLはL2の残り時間を超えない', async () => {
  await withCacheApi(async () => {
    const writer = new SharedCache({ name: 'graphdata', ttlMs: 80 });
    await writer.set('graphdata:B000SHORT', { series: {} });

    await new Promise((resolve) => setTimeout(resolve, 50));

    // 既定TTL(80ms)のまま載せ直すと、L2が切れた後もL1が古い値を返し続けてしまう。
    const reader = new SharedCache({ name: 'graphdata', ttlMs: 80 });
    assert.ok(await reader.get('graphdata:B000SHORT'), 'この時点ではまだ有効');

    await new Promise((resolve) => setTimeout(resolve, 40));
    assert.equal(await reader.get('graphdata:B000SHORT'), undefined, 'L2の期限を過ぎたらL1も返してはいけない');
  });
});

test('shouldShareがfalseのキーはL2へ出さない(SP-API経路の結果を共有しないため)', async () => {
  await withCacheApi(async (caches) => {
    const cache = new SharedCache({
      name: 'search',
      ttlMs: 60 * 1000,
      shouldShare: (key) => key.startsWith('keepa:'),
    });

    await cache.set('spapi:abcdef:pro:9784560017838', { source: 'spapi' });
    assert.equal(caches.store.size, 0, 'SP-API経路の結果はL2へ書かれてはいけない');
    // L1には入るので同じisolate内では従来どおり効く。
    assert.deepEqual(await cache.get('spapi:abcdef:pro:9784560017838'), { source: 'spapi' });

    await cache.set('keepa:9784560017838', { source: 'keepa' });
    assert.equal(caches.store.size, 1, 'Keepa経路の結果はL2へ書かれるべき');

    const other = new SharedCache({
      name: 'search',
      ttlMs: 60 * 1000,
      shouldShare: (key) => key.startsWith('keepa:'),
    });
    assert.equal(await other.get('spapi:abcdef:pro:9784560017838'), undefined);
    assert.deepEqual(await other.get('keepa:9784560017838'), { source: 'keepa' });
  });
});

test('L2の読み書きが失敗してもリクエストは落とさない(undefined扱い)', async () => {
  const prevCaches = globalThis.caches;
  const prevOrigin = globalThis.__cacheOrigin;
  globalThis.caches = {
    default: {
      async match() { throw new Error('boom'); },
      async put() { throw new Error('boom'); },
    },
  };
  globalThis.__cacheOrigin = 'https://api.example.test';
  try {
    const cache = new SharedCache({ name: 'search', ttlMs: 60 * 1000 });
    await cache.set('keepa:X', { a: 1 }); // putが投げてもrejectしない
    cache.clear(); // L1を空にしてL2だけを見る状態にする
    assert.equal(await cache.get('keepa:X'), undefined);
  } finally {
    globalThis.caches = prevCaches;
    globalThis.__cacheOrigin = prevOrigin;
  }
});
