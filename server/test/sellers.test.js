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
