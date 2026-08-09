'use strict';

/**
 * sellerTrialDurableObject.js(Workers専用のESMファイル)を、state.storageをモックした
 * 簡易テストで検証する。quota-do.test.jsと同じregisterHooks手法を使う(詳細はそちらのJSDoc参照)。
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
        if (url.endsWith('/src/sellerTrialDurableObject.js') || url.endsWith('/src/sellerTrial.js')) {
          // sellerTrial.jsはCommonJSのままでよい(worker.js等と同じCJS→ESM相互運用フォールバックに任せる)。
          // ここでformat指定するのはsellerTrialDurableObject.js(import/export構文を含む)のみ必須だが、
          // 一括で通しても問題ない。
          if (url.endsWith('/src/sellerTrialDurableObject.js')) {
            return nextLoad(url, { ...context, format: 'module' });
          }
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
function createMockState(initialStartedAt) {
  const store = new Map();
  if (initialStartedAt !== undefined) store.set('startedAt', initialStartedAt);
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

const ENV = { SPAPI_TRIAL_DAYS: '7' };
const DAY_MS = 24 * 60 * 60 * 1000;

test('SellerTrialDO(ESM)の挙動をstate.storageモックで検証する', async (t) => {
  if (hookError) {
    t.skip(`ESM動的importができないためスキップ: ${hookError.message}`);
    return;
  }

  let SellerTrialDO;
  try {
    const modUrl = pathToFileURL(path.join(__dirname, '../src/sellerTrialDurableObject.js')).href;
    const mod = await import(modUrl);
    SellerTrialDO = mod.SellerTrialDO;
  } catch (err) {
    t.skip(`sellerTrialDurableObject.jsの動的importに失敗したためスキップ: ${err.message}`);
    return;
  }

  await t.test('get-or-start: レコードが無ければnowを開始日時として新規発行しstorageへ書き込む', async () => {
    const state = createMockState();
    const doInstance = new SellerTrialDO(state, ENV);
    const now = 1_700_000_000_000;

    const res = await doInstance.fetch(
      new Request(`https://do/get-or-start?now=${now}`, { method: 'POST' })
    );
    const body = await res.json();
    assert.equal(body.startedAt, now);
    assert.equal(body.expiresAt, now + 7 * DAY_MS);
    assert.equal(body.active, true);
    assert.equal(await state.storage.get('startedAt'), now);
  });

  await t.test('get-or-start: write-once — 既存レコードがあれば絶対に上書きしない', async () => {
    const originalStartedAt = 1_600_000_000_000;
    const state = createMockState(originalStartedAt);
    const doInstance = new SellerTrialDO(state, ENV);

    const laterNow = originalStartedAt + 3 * DAY_MS;
    const res = await doInstance.fetch(
      new Request(`https://do/get-or-start?now=${laterNow}`, { method: 'POST' })
    );
    const body = await res.json();
    assert.equal(body.startedAt, originalStartedAt);
    assert.equal(await state.storage.get('startedAt'), originalStartedAt);
  });

  await t.test('get-or-start: 7日を過ぎるとactive:falseになる', async () => {
    const originalStartedAt = 1_600_000_000_000;
    const state = createMockState(originalStartedAt);
    const doInstance = new SellerTrialDO(state, ENV);

    const afterExpiry = originalStartedAt + 7 * DAY_MS + 1;
    const res = await doInstance.fetch(
      new Request(`https://do/get-or-start?now=${afterExpiry}`, { method: 'POST' })
    );
    const body = await res.json();
    assert.equal(body.active, false);
  });

  await t.test('不明なパス/メソッドは404', async () => {
    const doInstance = new SellerTrialDO(createMockState(), ENV);
    const res = await doInstance.fetch(new Request('https://do/unknown', { method: 'POST' }));
    assert.equal(res.status, 404);
  });
});
