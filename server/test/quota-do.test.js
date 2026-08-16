'use strict';

/**
 * quotaDurableObject.js(Workers専用のESMファイル)を、state.storageをモックした
 * 簡易テストで検証する。
 *
 * なぜ特別な仕掛けが要るか:
 * server/package.json は "type" を指定していない(既定=CommonJS)ため、拡張子.jsの
 * quotaDurableObject.js はNodeの標準ルールでは「ESM構文(import/export class)を含む
 * CommonJSファイル」として構文エラーになり、そのままでは動的importできない。
 * node:module の registerHooks (Node 22系以降で利用可能)を使い、このファイルだけ
 * 明示的に format:'module' としてロードさせることで、実物のDOクラスをそのままテストする。
 * registerHooksが無い/失敗する古いNode環境では、このテストファイル全体をスキップする
 * (npm test全体は緑のまま。deviceQuota.js/quotaMath.jsの単体テストで大半のロジックは
 * 別途カバーされている)。
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { pathToFileURL } = require('node:url');

let hookError = null;
try {
  const nodeModule = require('node:module');
  if (typeof nodeModule.registerHooks === 'function') {
    nodeModule.registerHooks({
      load(url, context, nextLoad) {
        if (url.endsWith('/src/quotaDurableObject.js')) {
          return nextLoad(url, { ...context, format: 'module' });
        }
        return nextLoad(url, context);
      },
    });
  } else {
    hookError = new Error('module.registerHooks はこのNodeバージョンでは利用できません');
  }
} catch (err) {
  hookError = err;
}

/** state.storageのモック(KVスタイルAPIのget/putのみ実装)。 */
function createMockState(initialEntry) {
  const store = new Map();
  if (initialEntry !== undefined) store.set('entry', initialEntry);
  return {
    storage: {
      async get(key) {
        return store.has(key) ? store.get(key) : undefined;
      },
      async put(key, value) {
        store.set(key, value);
      },
    },
  };
}

const ENV = { BASE_DAILY_UNITS: '5', UNITS_PER_AD: '5', MAX_DAILY_UNITS: '100' };
const DATE = '2026-7-31';

test('DeviceQuotaDO(ESM)の挙動をstate.storageモックで検証する', async (t) => {
  if (hookError) {
    t.skip(`ESM動的importができないためスキップ: ${hookError.message}`);
    return;
  }

  let DeviceQuotaDO;
  try {
    const modUrl = pathToFileURL(path.join(__dirname, '../src/quotaDurableObject.js')).href;
    const mod = await import(modUrl);
    DeviceQuotaDO = mod.DeviceQuotaDO;
  } catch (err) {
    t.skip(`quotaDurableObject.jsの動的importに失敗したためスキップ: ${err.message}`);
    return;
  }

  await t.test('consume: 基本枠5まで消費でき、6回目はallowed=false', async () => {
    const doInstance = new DeviceQuotaDO(createMockState(), ENV);

    for (let i = 1; i <= 5; i += 1) {
      const res = await doInstance.fetch(
        new Request(`https://do/consume?date=${DATE}&units=1`, { method: 'POST' })
      );
      const body = await res.json();
      assert.equal(body.allowed, true, `${i}回目は許可されるはず`);
      assert.equal(body.quota.unitsUsed, i);
      assert.equal(body.quota.limit, 5);
    }

    const res6 = await doInstance.fetch(
      new Request(`https://do/consume?date=${DATE}&units=1`, { method: 'POST' })
    );
    const body6 = await res6.json();
    assert.equal(body6.allowed, false);
    assert.equal(body6.quota.unitsUsed, 5);
  });

  await t.test('grant-ad: 19本目でcap(100)に到達し、20本目はgranted=false', async () => {
    const doInstance = new DeviceQuotaDO(createMockState(), ENV);

    let lastBody = null;
    for (let i = 1; i <= 19; i += 1) {
      const res = await doInstance.fetch(new Request(`https://do/grant-ad?date=${DATE}`, { method: 'POST' }));
      lastBody = await res.json();
      assert.equal(lastBody.granted, true, `${i}本目は許可されるはず`);
    }
    assert.equal(lastBody.quota.limit, 100);
    assert.equal(lastBody.quota.capReached, true);

    const res20 = await doInstance.fetch(new Request(`https://do/grant-ad?date=${DATE}`, { method: 'POST' }));
    const body20 = await res20.json();
    assert.equal(body20.granted, false);
    assert.equal(body20.quota.adGrantsToday, 19); // 増えない
  });

  await t.test('peek: 副作用なしで現在のquotaを返す', async () => {
    const doInstance = new DeviceQuotaDO(createMockState(), ENV);
    await doInstance.fetch(new Request(`https://do/consume?date=${DATE}&units=3`, { method: 'POST' }));

    const res1 = await doInstance.fetch(new Request(`https://do/peek?date=${DATE}`, { method: 'GET' }));
    const res2 = await doInstance.fetch(new Request(`https://do/peek?date=${DATE}`, { method: 'GET' }));
    const [body1, body2] = await Promise.all([res1.json(), res2.json()]);
    assert.deepEqual(body1, body2);
    assert.equal(body1.unitsUsed, 3);
  });

  await t.test('日付が変わると保存済みのunitsUsed/adGrantsは無視され0/0扱いになる', async () => {
    const doInstance = new DeviceQuotaDO(createMockState({ date: '2000-1-1', unitsUsed: 3, adGrants: 2 }), ENV);

    const res = await doInstance.fetch(new Request(`https://do/peek?date=${DATE}`, { method: 'GET' }));
    const body = await res.json();
    assert.equal(body.unitsUsed, 0);
    assert.equal(body.adGrantsToday, 0);
  });

  await t.test('壊れた保存値(不正な型・負値)は安全側(0/0)として扱われる', async () => {
    const doInstance = new DeviceQuotaDO(
      createMockState({ date: DATE, unitsUsed: 'oops', adGrants: -5 }),
      ENV
    );

    const res = await doInstance.fetch(new Request(`https://do/peek?date=${DATE}`, { method: 'GET' }));
    const body = await res.json();
    assert.equal(body.unitsUsed, 0);
    assert.equal(body.adGrantsToday, 0);
  });

  // -------------------------------------------------------------------------
  // Worker側で解決したlimits(KV由来)をクエリパラメータで受け取る経路
  // -------------------------------------------------------------------------

  await t.test('クエリパラメータのlimitsがenvより優先される', async () => {
    const doInstance = new DeviceQuotaDO(createMockState(), ENV);

    // base=2(envは5)。3回目で拒否されればクエリ側が効いている。
    for (let i = 1; i <= 2; i += 1) {
      const res = await doInstance.fetch(
        new Request(`https://do/consume?date=${DATE}&units=1&base=2&perAd=3&max=8`, { method: 'POST' })
      );
      const body = await res.json();
      assert.equal(body.allowed, true);
      assert.equal(body.quota.limit, 2);
    }
    const res3 = await doInstance.fetch(
      new Request(`https://do/consume?date=${DATE}&units=1&base=2&perAd=3&max=8`, { method: 'POST' })
    );
    assert.equal((await res3.json()).allowed, false);

    // 広告1本でlimitは 2 + 3 = 5 になる。
    const grant = await doInstance.fetch(
      new Request(`https://do/grant-ad?date=${DATE}&base=2&perAd=3&max=8`, { method: 'POST' })
    );
    const grantBody = await grant.json();
    assert.equal(grantBody.granted, true);
    assert.equal(grantBody.quota.limit, 5);
  });

  await t.test('limitsパラメータが無ければenv由来の値で動く(後方互換)', async () => {
    const doInstance = new DeviceQuotaDO(createMockState(), ENV);
    const res = await doInstance.fetch(new Request(`https://do/peek?date=${DATE}`, { method: 'GET' }));
    assert.equal((await res.json()).limit, 5);
  });

  await t.test('limitsパラメータが1つでも不正なら3値ともenvへフォールバックする', async () => {
    const doInstance = new DeviceQuotaDO(createMockState(), ENV);
    // base=2は妥当だがperAd=0が不正 → base=2も採用せず、env由来のlimit=5になる。
    const res = await doInstance.fetch(
      new Request(`https://do/peek?date=${DATE}&base=2&perAd=0&max=8`, { method: 'GET' })
    );
    assert.equal((await res.json()).limit, 5);

    // max < base も不正扱い。
    const res2 = await doInstance.fetch(
      new Request(`https://do/peek?date=${DATE}&base=50&perAd=5&max=10`, { method: 'GET' })
    );
    assert.equal((await res2.json()).limit, 5);
  });

  await t.test('base=0(広告を見ないと使えない設定)はクエリ・envの両方で有効', async () => {
    const doInstance = new DeviceQuotaDO(createMockState(), ENV);
    const res = await doInstance.fetch(
      new Request(`https://do/peek?date=${DATE}&base=0&perAd=5&max=100`, { method: 'GET' })
    );
    assert.equal((await res.json()).limit, 0);

    const zeroEnvInstance = new DeviceQuotaDO(createMockState(), { ...ENV, BASE_DAILY_UNITS: '0' });
    const res2 = await zeroEnvInstance.fetch(new Request(`https://do/peek?date=${DATE}`, { method: 'GET' }));
    assert.equal((await res2.json()).limit, 0);
  });

  await t.test('不明なパス/メソッドは404', async () => {
    const doInstance = new DeviceQuotaDO(createMockState(), ENV);
    const res = await doInstance.fetch(new Request('https://do/unknown', { method: 'POST' }));
    assert.equal(res.status, 404);
  });
});
