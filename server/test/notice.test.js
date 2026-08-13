'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

function freshRoutes() {
  delete require.cache[require.resolve('../src/routes')];
  delete require.cache[require.resolve('../src/deviceQuota')];
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

/**
 * globalThis.__adsKv に差し込むモックKV(noticeも同じADS_CONFIG namespaceを使う)。
 * get/putの呼び出し回数・引数を記録する。
 * store: 初期状態(キー→文字列値)。
 */
function createMockKv(store = {}) {
  const data = new Map(Object.entries(store));
  return {
    getCalls: [],
    putCalls: [],
    async get(key) {
      this.getCalls.push(key);
      return data.has(key) ? data.get(key) : null;
    },
    async put(key, value) {
      this.putCalls.push([key, value]);
      data.set(key, value);
    },
    _data: data,
  };
}

// 各テスト後にglobalThis.__adsKvを必ず元に戻す(他テストファイルへの汚染防止)。
function withAdsKv(kv, fn) {
  const saved = globalThis.__adsKv;
  globalThis.__adsKv = kv;
  return Promise.resolve()
    .then(fn)
    .finally(() => {
      globalThis.__adsKv = saved;
    });
}

const VALID_NOTICE = {
  id: '2026-08-13-keepa-outage',
  active: true,
  title: 'グラフの表示に不具合が発生しています',
  body: '現在、価格グラフが表示されない場合があります。復旧までお待ちください。',
  url: 'https://sellira.jp/amalens/news/',
};

// --- GET /api/notice ---

test('GET /api/notice: KV未設定(globalThis.__adsKvがnull)は {notice:null}', async () => {
  await withAdsKv(null, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('GET', '/api/notice');
    await route.handler({ query: {}, headers: {} }, res);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.body, { notice: null });
  });
});

test('GET /api/notice: KVにキーが無い場合は {notice:null}', async () => {
  const kv = createMockKv({});
  await withAdsKv(kv, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('GET', '/api/notice');
    await route.handler({ query: {}, headers: {} }, res);
    assert.deepEqual(res.body, { notice: null });
  });
});

test('GET /api/notice: 正常な告知(active:true, 全フィールドあり)が返り、activeは含まれない', async () => {
  const kv = createMockKv({ notice: JSON.stringify(VALID_NOTICE) });
  await withAdsKv(kv, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('GET', '/api/notice');
    await route.handler({ query: {}, headers: {} }, res);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.body, {
      notice: {
        id: VALID_NOTICE.id,
        title: VALID_NOTICE.title,
        body: VALID_NOTICE.body,
        url: VALID_NOTICE.url,
      },
    });
    assert.equal('active' in res.body.notice, false);
  });
});

test('GET /api/notice: active:false は {notice:null}', async () => {
  const kv = createMockKv({ notice: JSON.stringify({ ...VALID_NOTICE, active: false }) });
  await withAdsKv(kv, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('GET', '/api/notice');
    await route.handler({ query: {}, headers: {} }, res);
    assert.deepEqual(res.body, { notice: null });
  });
});

test('GET /api/notice: 不正なJSON(parse失敗)は例外を投げず {notice:null}', async () => {
  const kv = createMockKv({ notice: '{invalid json' });
  await withAdsKv(kv, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('GET', '/api/notice');
    await assert.doesNotReject(async () => {
      await route.handler({ query: {}, headers: {} }, res);
    });
    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.body, { notice: null });
  });
});

test('GET /api/notice: idが空文字は {notice:null}', async () => {
  const kv = createMockKv({ notice: JSON.stringify({ ...VALID_NOTICE, id: '' }) });
  await withAdsKv(kv, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('GET', '/api/notice');
    await route.handler({ query: {}, headers: {} }, res);
    assert.deepEqual(res.body, { notice: null });
  });
});

test('GET /api/notice: idが欠落は {notice:null}', async () => {
  const { id, ...rest } = VALID_NOTICE;
  const kv = createMockKv({ notice: JSON.stringify(rest) });
  await withAdsKv(kv, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('GET', '/api/notice');
    await route.handler({ query: {}, headers: {} }, res);
    assert.deepEqual(res.body, { notice: null });
  });
});

test('GET /api/notice: titleが欠落は {notice:null}', async () => {
  const { title, ...rest } = VALID_NOTICE;
  const kv = createMockKv({ notice: JSON.stringify(rest) });
  await withAdsKv(kv, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('GET', '/api/notice');
    await route.handler({ query: {}, headers: {} }, res);
    assert.deepEqual(res.body, { notice: null });
  });
});

test('GET /api/notice: bodyが欠落は {notice:null}', async () => {
  const { body, ...rest } = VALID_NOTICE;
  const kv = createMockKv({ notice: JSON.stringify(rest) });
  await withAdsKv(kv, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('GET', '/api/notice');
    await route.handler({ query: {}, headers: {} }, res);
    assert.deepEqual(res.body, { notice: null });
  });
});

test('GET /api/notice: urlがhttp://(https以外)の場合、告知は返るがurlは含まれない', async () => {
  const kv = createMockKv({ notice: JSON.stringify({ ...VALID_NOTICE, url: 'http://sellira.jp/news/' }) });
  await withAdsKv(kv, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('GET', '/api/notice');
    await route.handler({ query: {}, headers: {} }, res);
    assert.notEqual(res.body.notice, null);
    assert.equal('url' in res.body.notice, false);
  });
});

test('GET /api/notice: 長さ上限超過(title 101文字)は {notice:null}', async () => {
  const kv = createMockKv({ notice: JSON.stringify({ ...VALID_NOTICE, title: 'あ'.repeat(101) }) });
  await withAdsKv(kv, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('GET', '/api/notice');
    await route.handler({ query: {}, headers: {} }, res);
    assert.deepEqual(res.body, { notice: null });
  });
});

test('GET /api/notice: 長さ上限超過(id 129文字)は {notice:null}', async () => {
  const kv = createMockKv({ notice: JSON.stringify({ ...VALID_NOTICE, id: 'a'.repeat(129) }) });
  await withAdsKv(kv, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('GET', '/api/notice');
    await route.handler({ query: {}, headers: {} }, res);
    assert.deepEqual(res.body, { notice: null });
  });
});

test('GET /api/notice: 長さ上限超過(body 1001文字)は {notice:null}', async () => {
  const kv = createMockKv({ notice: JSON.stringify({ ...VALID_NOTICE, body: 'あ'.repeat(1001) }) });
  await withAdsKv(kv, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('GET', '/api/notice');
    await route.handler({ query: {}, headers: {} }, res);
    assert.deepEqual(res.body, { notice: null });
  });
});

test('GET /api/notice: 60秒キャッシュにより2回目はKV.getが呼ばれない', async () => {
  const kv = createMockKv({ notice: JSON.stringify(VALID_NOTICE) });
  await withAdsKv(kv, async () => {
    const routes = freshRoutes();
    const route = routes.match('GET', '/api/notice');

    const res1 = createMockRes();
    await route.handler({ query: {}, headers: {} }, res1);
    const res2 = createMockRes();
    await route.handler({ query: {}, headers: {} }, res2);

    assert.equal(kv.getCalls.length, 1);
    assert.notEqual(res1.body.notice, null);
    assert.deepEqual(res1.body, res2.body);
  });
});
