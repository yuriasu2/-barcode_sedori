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

function freshRoutes() {
  delete require.cache[require.resolve('../src/routes')];
  delete require.cache[require.resolve('../src/spapi/listings')];
  delete require.cache[require.resolve('../src/spapi/sellers')];
  delete require.cache[require.resolve('../src/deviceRateLimit')];
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

const ENV = { LWA_CLIENT_ID: 'cid', LWA_CLIENT_SECRET: 'sec' };

/**
 * LWAトークン + Sellers API + Listings系APIをまとめてモックするfetch。
 * handlers: { restrictions(url), putItem(url, init) } を上書き可能。
 */
function mockFetch(handlers = {}) {
  return async (url, init) => {
    const u = String(url);
    const ok = (jsonBody) => ({
      ok: true,
      status: 200,
      json: async () => jsonBody,
      text: async () => JSON.stringify(jsonBody),
      headers: { get: () => null },
    });
    if (u.includes('api.amazon.com/auth/o2/token')) {
      return ok({ access_token: 'at', expires_in: 3600 });
    }
    if (u.includes('/sellers/v1/marketplaceParticipations')) {
      return ok({
        payload: [
          { sellerId: 'SELLER123', marketplace: { id: 'A1VC38T7YXB528' }, participation: { isParticipating: true } },
        ],
      });
    }
    if (u.includes('/listings/2021-08-01/restrictions')) {
      return handlers.restrictions ? handlers.restrictions(u, ok) : ok({ restrictions: [] });
    }
    if (u.includes('/listings/2021-08-01/items/')) {
      return handlers.putItem ? handlers.putItem(u, init, ok) : ok({ status: 'ACCEPTED', submissionId: 'sub-1', issues: [] });
    }
    throw new Error(`unexpected fetch: ${u}`);
  };
}

// --- ゲート ---

test('restrictions: 無料は403 plan_required', async () => {
  const routes = freshRoutes();
  const res = createMockRes();
  const route = routes.match('GET', '/api/listings/restrictions');
  await route.handler(
    { query: { asin: 'B000TEST', condition: 'used_good' }, headers: { 'x-spapi-refresh-token': 'rt' } },
    res
  );
  assert.equal(res.statusCode, 403);
  assert.equal(res.body.error, 'plan_required');
});

test('restrictions: ProでもX-Spapi-Refresh-Tokenが無ければ403 spapi_link_required(.envトークンにフォールバックしない)', async () => {
  await withEnv({ ...ENV, LWA_REFRESH_TOKEN: 'env-rt' }, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('GET', '/api/listings/restrictions');
    await route.handler(
      { query: { asin: 'B000TEST', condition: 'used_good' }, headers: { 'x-app-plan': 'pro' } },
      res
    );
    assert.equal(res.statusCode, 403);
    assert.equal(res.body.error, 'spapi_link_required');
  });
});

test('restrictions: asin欠落は400', async () => {
  const routes = freshRoutes();
  const res = createMockRes();
  const route = routes.match('GET', '/api/listings/restrictions');
  await route.handler(
    { query: {}, headers: { 'x-app-plan': 'pro', 'x-spapi-refresh-token': 'rt' } },
    res
  );
  assert.equal(res.statusCode, 400);
});

// --- 正常系 ---

test('restrictions: 制限なしは restricted:false', async () => {
  await withEnv(ENV, async () => {
    const routes = freshRoutes();
    const originalFetch = global.fetch;
    global.fetch = mockFetch();
    try {
      const res = createMockRes();
      const route = routes.match('GET', '/api/listings/restrictions');
      await route.handler(
        {
          query: { asin: 'B000TEST', condition: 'used_good' },
          headers: { 'x-app-plan': 'pro', 'x-spapi-refresh-token': 'rt-norestrict' },
        },
        res
      );
      assert.equal(res.statusCode, 200);
      assert.deepEqual(res.body, { restricted: false, message: null, approvalUrl: null });
    } finally {
      global.fetch = originalFetch;
    }
  });
});

test('restrictions: 制限ありは理由メッセージと解除申請リンクを返し、リクエストURLにsellerId/conditionTypeが入る', async () => {
  await withEnv(ENV, async () => {
    const routes = freshRoutes();
    const originalFetch = global.fetch;
    let requestedUrl = null;
    global.fetch = mockFetch({
      restrictions: (u, ok) => {
        requestedUrl = u;
        return ok({
          restrictions: [
            {
              marketplaceId: 'A1VC38T7YXB528',
              conditionType: 'used_good',
              reasons: [
                {
                  reasonCode: 'APPROVAL_REQUIRED',
                  message: 'この商品の出品には承認が必要です。',
                  links: [
                    { resource: 'https://sellercentral.amazon.co.jp/approval', verb: 'GET', title: 'Request Approval', type: 'text/html' },
                  ],
                },
              ],
            },
          ],
        });
      },
    });
    try {
      const res = createMockRes();
      const route = routes.match('GET', '/api/listings/restrictions');
      await route.handler(
        {
          query: { asin: 'B000TEST', condition: 'used_good' },
          headers: { 'x-app-plan': 'pro', 'x-spapi-refresh-token': 'rt-restricted' },
        },
        res
      );
      assert.equal(res.statusCode, 200);
      assert.equal(res.body.restricted, true);
      assert.equal(res.body.message, 'この商品の出品には承認が必要です。');
      assert.equal(res.body.approvalUrl, 'https://sellercentral.amazon.co.jp/approval');
      assert.ok(requestedUrl.includes('sellerId=SELLER123'));
      assert.ok(requestedUrl.includes('conditionType=used_good'));
      assert.ok(requestedUrl.includes('asin=B000TEST'));
      assert.ok(requestedUrl.includes('marketplaceIds=A1VC38T7YXB528'));
    } finally {
      global.fetch = originalFetch;
    }
  });
});

test('restrictions: condition不正値は400', async () => {
  const routes = freshRoutes();
  const res = createMockRes();
  const route = routes.match('GET', '/api/listings/restrictions');
  await route.handler(
    { query: { asin: 'B000TEST', condition: 'brand_new' }, headers: { 'x-app-plan': 'pro', 'x-spapi-refresh-token': 'rt' } },
    res
  );
  assert.equal(res.statusCode, 400);
});
