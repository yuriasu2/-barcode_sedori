'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const sellerTrial = require('../src/sellerTrial');

test('buildStatus: startedAtからtrialDays日後がexpiresAt、それ未満はactive:true', () => {
  const startedAt = 1_000_000_000;
  const trialDays = 7;
  const status = sellerTrial.buildStatus(startedAt, startedAt, trialDays);
  assert.equal(status.startedAt, startedAt);
  assert.equal(status.expiresAt, startedAt + 7 * sellerTrial.DAY_MS);
  assert.equal(status.active, true);
});

test('buildStatus: 有効期限のちょうど直前はactive:true、直後はactive:false', () => {
  const startedAt = 1_000_000_000;
  const trialDays = 7;
  const expiresAt = startedAt + trialDays * sellerTrial.DAY_MS;

  assert.equal(sellerTrial.buildStatus(startedAt, expiresAt - 1, trialDays).active, true);
  assert.equal(sellerTrial.buildStatus(startedAt, expiresAt, trialDays).active, false);
  assert.equal(sellerTrial.buildStatus(startedAt, expiresAt + 1, trialDays).active, false);
});

test('readTrialDays: envの値を読み、無効なら既定7', () => {
  assert.equal(sellerTrial.readTrialDays({ SPAPI_TRIAL_DAYS: '14' }), 14);
  assert.equal(sellerTrial.readTrialDays({}), 7);
  assert.equal(sellerTrial.readTrialDays({ SPAPI_TRIAL_DAYS: 'abc' }), 7);
  assert.equal(sellerTrial.readTrialDays({ SPAPI_TRIAL_DAYS: '0' }), 7);
});

test('getOrStart: sellerIdが空ならnull', async () => {
  sellerTrial._reset();
  assert.equal(await sellerTrial.getOrStart(null), null);
  assert.equal(await sellerTrial.getOrStart(''), null);
  assert.equal(await sellerTrial.getOrStart(undefined), null);
});

test('getOrStart: write-once — 2回目以降は最初のstartedAtを維持し、上書きしない(インメモリ経路)', async () => {
  sellerTrial._reset();
  sellerTrial._setDurableBinding(null); // インメモリ経路を強制

  const firstNow = 1_000_000_000;
  const first = await sellerTrial.getOrStart('SELLER-A', firstNow);
  assert.equal(first.startedAt, firstNow);
  assert.equal(first.active, true);

  // 異なるnowで再度呼んでも、startedAtは最初の値のまま(延長されない)。
  const laterNow = firstNow + 3 * sellerTrial.DAY_MS;
  const second = await sellerTrial.getOrStart('SELLER-A', laterNow);
  assert.equal(second.startedAt, firstNow);

  sellerTrial._setDurableBinding(undefined);
});

test('getOrStart: 有効期限の境界(インメモリ経路) — 7日未満はactive、7日を過ぎたら非active', async () => {
  sellerTrial._reset();
  sellerTrial._setDurableBinding(null);

  const startedAt = 1_000_000_000;
  await sellerTrial.getOrStart('SELLER-B', startedAt);

  const justBefore = startedAt + 7 * sellerTrial.DAY_MS - 1;
  const justAfter = startedAt + 7 * sellerTrial.DAY_MS + 1;

  assert.equal((await sellerTrial.getOrStart('SELLER-B', justBefore)).active, true);
  assert.equal((await sellerTrial.getOrStart('SELLER-B', justAfter)).active, false);

  sellerTrial._setDurableBinding(undefined);
});

test('getOrStart: 別のsellerIdは独立して管理される', async () => {
  sellerTrial._reset();
  sellerTrial._setDurableBinding(null);

  const now = 2_000_000_000;
  await sellerTrial.getOrStart('SELLER-C', now);
  const other = await sellerTrial.getOrStart('SELLER-D', now + 100);
  assert.equal(other.startedAt, now + 100);

  sellerTrial._setDurableBinding(undefined);
});

test('getOrStart: DO障害時はnullを返す(fail-closed。可用性より不正付与の防止を優先)', async () => {
  sellerTrial._reset();
  sellerTrial._setDurableBinding({
    idFromName() { return 'id'; },
    get() {
      return { fetch() { throw new Error('DO down'); } };
    },
  });

  const result = await sellerTrial.getOrStart('SELLER-E');
  assert.equal(result, null);

  sellerTrial._setDurableBinding(undefined);
});

test('getOrStart: DO経路はidFromName(sellerId)でインスタンスを割り当て、DOの応答をそのまま返す', async () => {
  sellerTrial._reset();
  let requestedId = null;
  let requestedUrl = null;
  sellerTrial._setDurableBinding({
    idFromName(name) {
      requestedId = name;
      return `do-id-${name}`;
    },
    get(id) {
      return {
        async fetch(url) {
          requestedUrl = String(url);
          return {
            ok: true,
            async json() {
              return { startedAt: 123, expiresAt: 456, active: true };
            },
          };
        },
      };
    },
  });

  const result = await sellerTrial.getOrStart('SELLER-F', 999);
  assert.equal(requestedId, 'SELLER-F');
  assert.ok(requestedUrl.includes('/get-or-start'));
  assert.ok(requestedUrl.includes('now=999'));
  assert.deepEqual(result, { startedAt: 123, expiresAt: 456, active: true });

  sellerTrial._setDurableBinding(undefined);
});
