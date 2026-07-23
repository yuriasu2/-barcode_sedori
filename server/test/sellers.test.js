'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

async function withEnv(vars, fn) {
  const saved = {};
  for (const key of Object.keys(vars)) {
    saved[key] = process.env[key];
    if (vars[key] === undefined) delete process.env[key];
    else process.env[key] = vars[key];
  }
  try {
    return await fn();
  } finally {
    for (const key of Object.keys(saved)) {
      if (saved[key] === undefined) delete process.env[key];
      else process.env[key] = saved[key];
    }
  }
}

function freshSellers() {
  delete require.cache[require.resolve('../src/spapi/sellers')];
  return require('../src/spapi/sellers');
}

// --- extractSellerId 単体 ---

test('extractSellerId: 対象マーケットプレイスのsellerIdを返す(トップレベルsellerId形式)', () => {
  const sellers = freshSellers();
  const response = {
    payload: [
      { sellerId: 'SELLER_US', marketplace: { id: 'ATVPDKIKX0DER' }, participation: { isParticipating: true } },
      { sellerId: 'SELLER_JP', marketplace: { id: 'A1VC38T7YXB528' }, participation: { isParticipating: true } },
    ],
  };
  assert.equal(sellers.extractSellerId(response, 'A1VC38T7YXB528'), 'SELLER_JP');
});

test('extractSellerId: participation配下にsellerIdがある形式にも対応する', () => {
  const sellers = freshSellers();
  const response = {
    payload: [
      { marketplace: { id: 'A1VC38T7YXB528' }, participation: { isParticipating: true, sellerId: 'SELLER_JP2' } },
    ],
  };
  assert.equal(sellers.extractSellerId(response, 'A1VC38T7YXB528'), 'SELLER_JP2');
});

test('extractSellerId: 対象マーケットプレイスが無ければ先頭エントリで代替、payloadが空/欠落はnull', () => {
  const sellers = freshSellers();
  const response = {
    payload: [{ sellerId: 'SELLER_ONLY', marketplace: { id: 'OTHER' }, participation: {} }],
  };
  assert.equal(sellers.extractSellerId(response, 'A1VC38T7YXB528'), 'SELLER_ONLY');
  assert.equal(sellers.extractSellerId({ payload: [] }, 'A1VC38T7YXB528'), null);
  assert.equal(sellers.extractSellerId({}, 'A1VC38T7YXB528'), null);
  assert.equal(sellers.extractSellerId(null, 'A1VC38T7YXB528'), null);
});

// --- resolveSellerId(fetchモック + キャッシュ) ---

test('resolveSellerId: Sellers APIからsellerIdを解決し、同一トークンの2回目はキャッシュで返す(fetch回数増えない)', async () => {
  await withEnv({ LWA_CLIENT_ID: 'cid', LWA_CLIENT_SECRET: 'sec' }, async () => {
    const sellers = freshSellers();
    const originalFetch = global.fetch;
    let tokenCalls = 0;
    let apiCalls = 0;
    global.fetch = async (url) => {
      const u = String(url);
      if (u.includes('api.amazon.com/auth/o2/token')) {
        tokenCalls += 1;
        return {
          ok: true,
          status: 200,
          json: async () => ({ access_token: 'at-1', expires_in: 3600 }),
          text: async () => '',
          headers: { get: () => null },
        };
      }
      if (u.includes('/sellers/v1/marketplaceParticipations')) {
        apiCalls += 1;
        return {
          ok: true,
          status: 200,
          json: async () => ({
            payload: [
              { sellerId: 'A3EXAMPLE', marketplace: { id: 'A1VC38T7YXB528' }, participation: { isParticipating: true } },
            ],
          }),
          text: async () => '',
          headers: { get: () => null },
        };
      }
      throw new Error(`unexpected fetch: ${u}`);
    };
    try {
      const credentials = { clientId: 'cid', clientSecret: 'sec', refreshToken: 'rt-cache-test' };
      const first = await sellers.resolveSellerId(credentials);
      const second = await sellers.resolveSellerId(credentials);
      assert.equal(first, 'A3EXAMPLE');
      assert.equal(second, 'A3EXAMPLE');
      assert.equal(apiCalls, 1); // 2回目はキャッシュ
    } finally {
      global.fetch = originalFetch;
    }
  });
});

test('resolveSellerId: sellerIdが応答から取れない場合はエラーをthrowする', async () => {
  await withEnv({ LWA_CLIENT_ID: 'cid', LWA_CLIENT_SECRET: 'sec' }, async () => {
    const sellers = freshSellers();
    const originalFetch = global.fetch;
    global.fetch = async (url) => {
      const u = String(url);
      if (u.includes('api.amazon.com/auth/o2/token')) {
        return {
          ok: true, status: 200,
          json: async () => ({ access_token: 'at-2', expires_in: 3600 }),
          text: async () => '', headers: { get: () => null },
        };
      }
      return {
        ok: true, status: 200,
        json: async () => ({ payload: [] }),
        text: async () => '', headers: { get: () => null },
      };
    };
    try {
      await assert.rejects(
        () => sellers.resolveSellerId({ clientId: 'cid', clientSecret: 'sec', refreshToken: 'rt-empty' }),
        /seller_id_not_found/
      );
    } finally {
      global.fetch = originalFetch;
    }
  });
});

test('resolveSellerId: 異なるrefreshTokenはキャッシュが分離され、各自でAPIを呼び出す。同一トークンの再呼び出しはキャッシュヒット', async () => {
  await withEnv({ LWA_CLIENT_ID: 'cid', LWA_CLIENT_SECRET: 'sec' }, async () => {
    const sellers = freshSellers();
    const originalFetch = global.fetch;
    let apiCalls = 0;
    global.fetch = async (url) => {
      const u = String(url);
      if (u.includes('api.amazon.com/auth/o2/token')) {
        return {
          ok: true,
          status: 200,
          json: async () => ({ access_token: 'at-token-sep', expires_in: 3600 }),
          text: async () => '',
          headers: { get: () => null },
        };
      }
      if (u.includes('/sellers/v1/marketplaceParticipations')) {
        apiCalls += 1;
        // リフレッシュトークンを検査してレスポンスを分岐
        // 実装では Authorization ヘッダ経由で渡されるため、
        // ここでは API 呼び出し回数でトークン別の処理を判定
        if (apiCalls === 1) {
          // 第1回目は token-A
          return {
            ok: true,
            status: 200,
            json: async () => ({
              payload: [
                { sellerId: 'SELLER_A', marketplace: { id: 'A1VC38T7YXB528' }, participation: { isParticipating: true } },
              ],
            }),
            text: async () => '',
            headers: { get: () => null },
          };
        } else if (apiCalls === 2) {
          // 第2回目は token-B
          return {
            ok: true,
            status: 200,
            json: async () => ({
              payload: [
                { sellerId: 'SELLER_B', marketplace: { id: 'A1VC38T7YXB528' }, participation: { isParticipating: true } },
              ],
            }),
            text: async () => '',
            headers: { get: () => null },
          };
        }
        throw new Error('unexpected third API call');
      }
      throw new Error(`unexpected fetch: ${u}`);
    };
    try {
      // 第1回: token-A で呼び出し
      const first = await sellers.resolveSellerId({ clientId: 'cid', clientSecret: 'sec', refreshToken: 'token-A' });
      assert.equal(first, 'SELLER_A');
      assert.equal(apiCalls, 1);

      // 第2回: token-B で呼び出し（異なるトークン→新たにAPI呼び出し）
      const second = await sellers.resolveSellerId({ clientId: 'cid', clientSecret: 'sec', refreshToken: 'token-B' });
      assert.equal(second, 'SELLER_B');
      assert.equal(apiCalls, 2);

      // 第3回: token-A で再度呼び出し（キャッシュヒット→API呼び出しなし）
      const third = await sellers.resolveSellerId({ clientId: 'cid', clientSecret: 'sec', refreshToken: 'token-A' });
      assert.equal(third, 'SELLER_A');
      assert.equal(apiCalls, 2); // API呼び出しは増えない
    } finally {
      global.fetch = originalFetch;
    }
  });
});
