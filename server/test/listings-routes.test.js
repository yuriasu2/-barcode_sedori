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

// sellerIdはSellers APIから解決せず、X-Spapi-Seller-Idヘッダーで渡す方式(OAuth時のselling_partner_idを
// アプリが保持してヘッダー送信する)。テストのゲート通過用に共通のヘッダーセットを用意する。
const PRO_HEADERS = { 'x-app-plan': 'pro', 'x-spapi-refresh-token': 'rt', 'x-spapi-seller-id': 'SELLER123' };

/**
 * LWAトークン + Listings系APIをまとめてモックするfetch。
 * handlers: { restrictions(url), putItem(url, init), feesEstimate(url, init) } を上書き可能。
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
    if (u.includes('/listings/2021-08-01/restrictions')) {
      return handlers.restrictions ? handlers.restrictions(u, ok) : ok({ restrictions: [] });
    }
    if (u.includes('/listings/2021-08-01/items/')) {
      return handlers.putItem ? handlers.putItem(u, init, ok) : ok({ status: 'ACCEPTED', submissionId: 'sub-1', issues: [] });
    }
    if (u.includes('/products/fees/v0/feesEstimate')) {
      return handlers.feesEstimate ? handlers.feesEstimate(u, init, ok) : ok({ payload: [] });
    }
    throw new Error(`unexpected fetch: ${u}`);
  };
}

/**
 * getMyFeesEstimatesBatchが実際に確認済みの応答形(payloadが配列、各要素に
 * FeesEstimateResult.FeesEstimate.FeeDetailList)でfeesEstimateのモック応答を作る。
 */
function feesEstimateOk(ok, feeDetailList) {
  return ok({
    payload: [
      {
        FeesEstimateResult: {
          Status: 'Success',
          FeesEstimate: {
            TotalFeesEstimate: { CurrencyCode: 'JPY', Amount: 0 },
            FeeDetailList: feeDetailList,
          },
        },
      },
    ],
  });
}

// --- ゲート ---

test('restrictions: 無料は403 plan_required', async () => {
  const routes = freshRoutes();
  const res = createMockRes();
  const route = routes.match('GET', '/api/listings/restrictions');
  await route.handler(
    { query: { asin: 'B000TEST', condition: 'used_good' }, headers: { 'x-spapi-refresh-token': 'rt', 'x-spapi-seller-id': 'SELLER123' } },
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
      { query: { asin: 'B000TEST', condition: 'used_good' }, headers: { 'x-app-plan': 'pro', 'x-spapi-seller-id': 'SELLER123' } },
      res
    );
    assert.equal(res.statusCode, 403);
    assert.equal(res.body.error, 'spapi_link_required');
  });
});

test('restrictions: ProかつトークンありでもX-Spapi-Seller-Idが無ければ403 seller_id_required', async () => {
  await withEnv(ENV, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('GET', '/api/listings/restrictions');
    await route.handler(
      { query: { asin: 'B000TEST', condition: 'used_good' }, headers: { 'x-app-plan': 'pro', 'x-spapi-refresh-token': 'rt' } },
      res
    );
    assert.equal(res.statusCode, 403);
    assert.equal(res.body.error, 'seller_id_required');
  });
});

test('restrictions: asin欠落は400', async () => {
  const routes = freshRoutes();
  const res = createMockRes();
  const route = routes.match('GET', '/api/listings/restrictions');
  await route.handler(
    { query: {}, headers: PRO_HEADERS },
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
          headers: PRO_HEADERS,
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

test('restrictions: 制限ありは理由メッセージと解除申請リンクを返し、リクエストURLにヘッダー由来のsellerId/conditionTypeが入る', async () => {
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
          headers: { 'x-app-plan': 'pro', 'x-spapi-refresh-token': 'rt-restricted', 'x-spapi-seller-id': 'SELLER123' },
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

test('restrictions: 異なるX-Spapi-Seller-IdヘッダーはそのままリクエストURLのsellerIdに反映される', async () => {
  await withEnv(ENV, async () => {
    const routes = freshRoutes();
    const originalFetch = global.fetch;
    let requestedUrl = null;
    global.fetch = mockFetch({
      restrictions: (u, ok) => {
        requestedUrl = u;
        return ok({ restrictions: [] });
      },
    });
    try {
      const res = createMockRes();
      const route = routes.match('GET', '/api/listings/restrictions');
      await route.handler(
        {
          query: { asin: 'B000TEST', condition: 'used_good' },
          headers: { 'x-app-plan': 'pro', 'x-spapi-refresh-token': 'rt', 'x-spapi-seller-id': 'A2OTHERSELLER' },
        },
        res
      );
      assert.equal(res.statusCode, 200);
      assert.ok(requestedUrl.includes('sellerId=A2OTHERSELLER'));
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
    { query: { asin: 'B000TEST', condition: 'brand_new' }, headers: PRO_HEADERS },
    res
  );
  assert.equal(res.statusCode, 400);
});

// --- POST /api/listings ---

test('listings POST: 無料は403 plan_required、Proでもトークン無しは403 spapi_link_required、Proかつトークンありでもseller_id無しは403 seller_id_required', async () => {
  await withEnv(ENV, async () => {
    const routes = freshRoutes();
    const route = routes.match('POST', '/api/listings');

    const res1 = createMockRes();
    await route.handler({ body: {}, headers: { 'x-spapi-refresh-token': 'rt', 'x-spapi-seller-id': 'SELLER123' } }, res1);
    assert.equal(res1.statusCode, 403);
    assert.equal(res1.body.error, 'plan_required');

    const res2 = createMockRes();
    await route.handler({ body: {}, headers: { 'x-app-plan': 'pro' } }, res2);
    assert.equal(res2.statusCode, 403);
    assert.equal(res2.body.error, 'spapi_link_required');

    const res3 = createMockRes();
    await route.handler({ body: {}, headers: { 'x-app-plan': 'pro', 'x-spapi-refresh-token': 'rt' } }, res3);
    assert.equal(res3.statusCode, 403);
    assert.equal(res3.body.error, 'seller_id_required');
  });
});

test('listings POST: 入力バリデーション(asin欠落/価格0以下/数量0以下/SKU不正/conditionType不正は400)', async () => {
  // ゲート(requireProByoCredentials)は入力検証より先に走る(plan/token不足時の403を
  // 壊れたbodyの内容に関わらず優先させるため)。そのためこのテストではプラン/トークンの
  // ゲート自体は通過させる必要があり、LWA_CLIENT_ID/LWA_CLIENT_SECRET未設定による
  // 503(spapi_credentials_missing)化を避けるためwithEnv(ENV)で環境変数を設定する。
  await withEnv(ENV, async () => {
    const routes = freshRoutes();
    const route = routes.match('POST', '/api/listings');
    const headers = PRO_HEADERS;
    const valid = {
      asin: 'B000TEST',
      sku: 'AMLZ-20260722-001',
      conditionType: 'used_good',
      price: 1500,
      quantity: 1,
      conditionNote: '状態良好です。',
    };

    for (const broken of [
      { ...valid, asin: '' },
      { ...valid, price: 0 },
      { ...valid, price: 1500.5 },
      { ...valid, quantity: 0 },
      { ...valid, sku: 'bad sku with spaces' },
      { ...valid, conditionType: 'poor' },
    ]) {
      const res = createMockRes();
      await route.handler({ body: broken, headers }, res);
      assert.equal(res.statusCode, 400, JSON.stringify(broken));
    }
  });
});

test('listings POST: putListingsItemへ正しいURL(ヘッダー由来のsellerId)/ボディで送り、ACCEPTED応答を透過する', async () => {
  await withEnv(ENV, async () => {
    const routes = freshRoutes();
    const originalFetch = global.fetch;
    let putUrl = null;
    let putBody = null;
    global.fetch = mockFetch({
      putItem: (u, init, ok) => {
        putUrl = u;
        putBody = JSON.parse(init.body);
        return ok({ sku: 'AMLZ-20260722-001', status: 'ACCEPTED', submissionId: 'sub-99', issues: [] });
      },
    });
    try {
      const res = createMockRes();
      const route = routes.match('POST', '/api/listings');
      await route.handler(
        {
          body: {
            asin: 'B000TEST',
            sku: 'AMLZ-20260722-001',
            conditionType: 'used_good',
            price: 1500,
            quantity: 1,
            conditionNote: '書き込みはありません。',
          },
          headers: { 'x-app-plan': 'pro', 'x-spapi-refresh-token': 'rt-put', 'x-spapi-seller-id': 'SELLER123' },
        },
        res
      );
      assert.equal(res.statusCode, 200);
      assert.equal(res.body.status, 'ACCEPTED');
      assert.equal(res.body.submissionId, 'sub-99');
      assert.deepEqual(res.body.issues, []);

      // PUT URL: sellerId(ヘッダー由来) + SKU + marketplaceIds
      assert.ok(putUrl.includes('/listings/2021-08-01/items/SELLER123/AMLZ-20260722-001'));
      assert.ok(putUrl.includes('marketplaceIds=A1VC38T7YXB528'));

      // ボディ: productType/requirements/attributes(spec準拠)
      assert.equal(putBody.productType, 'PRODUCT');
      assert.equal(putBody.requirements, 'LISTING_OFFER_ONLY');
      const attrs = putBody.attributes;
      assert.deepEqual(attrs.merchant_suggested_asin, [{ value: 'B000TEST', marketplace_id: 'A1VC38T7YXB528' }]);
      assert.deepEqual(attrs.condition_type, [{ value: 'used_good', marketplace_id: 'A1VC38T7YXB528' }]);
      assert.deepEqual(attrs.condition_note, [
        { language_tag: 'ja_JP', value: '書き込みはありません。', marketplace_id: 'A1VC38T7YXB528' },
      ]);
      assert.deepEqual(attrs.purchasable_offer, [
        {
          currency: 'JPY',
          marketplace_id: 'A1VC38T7YXB528',
          our_price: [{ schedule: [{ value_with_tax: 1500 }] }],
        },
      ]);
      assert.deepEqual(attrs.fulfillment_availability, [
        { fulfillment_channel_code: 'DEFAULT', quantity: 1 },
      ]);
    } finally {
      global.fetch = originalFetch;
    }
  });
});

test('listings POST: 異なるX-Spapi-Seller-IdヘッダーはそのままputListingsItemのURLパスに反映される', async () => {
  await withEnv(ENV, async () => {
    const routes = freshRoutes();
    const originalFetch = global.fetch;
    let putUrl = null;
    global.fetch = mockFetch({
      putItem: (u, init, ok) => {
        putUrl = u;
        return ok({ status: 'ACCEPTED', submissionId: 'sub-other', issues: [] });
      },
    });
    try {
      const res = createMockRes();
      const route = routes.match('POST', '/api/listings');
      await route.handler(
        {
          body: {
            asin: 'B000TEST',
            sku: 'AMLZ-20260722-003',
            conditionType: 'used_good',
            price: 1500,
            quantity: 1,
            conditionNote: '',
          },
          headers: { 'x-app-plan': 'pro', 'x-spapi-refresh-token': 'rt', 'x-spapi-seller-id': 'A2OTHERSELLER' },
        },
        res
      );
      assert.equal(res.statusCode, 200);
      assert.ok(putUrl.includes('/listings/2021-08-01/items/A2OTHERSELLER/AMLZ-20260722-003'));
    } finally {
      global.fetch = originalFetch;
    }
  });
});

test('listings POST: INVALID応答(issues付き)もそのまま透過する(日本語化しない)', async () => {
  await withEnv(ENV, async () => {
    const routes = freshRoutes();
    const originalFetch = global.fetch;
    global.fetch = mockFetch({
      putItem: (u, init, ok) =>
        ok({
          sku: 'AMLZ-20260722-002',
          status: 'INVALID',
          submissionId: 'sub-bad',
          issues: [{ code: '90220', message: 'Value is invalid for purchasable_offer.', severity: 'ERROR', attributeNames: ['purchasable_offer'] }],
        }),
    });
    try {
      const res = createMockRes();
      const route = routes.match('POST', '/api/listings');
      await route.handler(
        {
          body: {
            asin: 'B000TEST',
            sku: 'AMLZ-20260722-002',
            conditionType: 'used_acceptable',
            price: 800,
            quantity: 1,
            conditionNote: '',
          },
          headers: { 'x-app-plan': 'pro', 'x-spapi-refresh-token': 'rt-invalid', 'x-spapi-seller-id': 'SELLER123' },
        },
        res
      );
      assert.equal(res.statusCode, 200);
      assert.equal(res.body.status, 'INVALID');
      assert.equal(res.body.issues[0].message, 'Value is invalid for purchasable_offer.');
      // conditionNoteが空文字のときはcondition_note属性自体を送らない
    } finally {
      global.fetch = originalFetch;
    }
  });

// --- POST /api/listings: fulfillmentChannel(FBA) ---

test('listings POST: fulfillmentChannel省略時はDEFAULT(従来通りquantity付き)', async () => {
  await withEnv(ENV, async () => {
    const routes = freshRoutes();
    const originalFetch = global.fetch;
    let putBody = null;
    global.fetch = mockFetch({
      putItem: (u, init, ok) => {
        putBody = JSON.parse(init.body);
        return ok({ status: 'ACCEPTED', submissionId: 'sub-default', issues: [] });
      },
    });
    try {
      const res = createMockRes();
      const route = routes.match('POST', '/api/listings');
      await route.handler(
        {
          body: {
            asin: 'B000TEST',
            sku: 'AMLZ-20260728-001',
            conditionType: 'used_good',
            price: 1500,
            quantity: 2,
            conditionNote: '',
          },
          headers: PRO_HEADERS,
        },
        res
      );
      assert.equal(res.statusCode, 200);
      assert.deepEqual(putBody.attributes.fulfillment_availability, [
        { fulfillment_channel_code: 'DEFAULT', quantity: 2 },
      ]);
    } finally {
      global.fetch = originalFetch;
    }
  });
});

test('listings POST: fulfillmentChannel=AMAZON_JPはquantityなしのAMAZON_JPになる', async () => {
  await withEnv(ENV, async () => {
    const routes = freshRoutes();
    const originalFetch = global.fetch;
    let putBody = null;
    global.fetch = mockFetch({
      putItem: (u, init, ok) => {
        putBody = JSON.parse(init.body);
        return ok({ status: 'ACCEPTED', submissionId: 'sub-fba', issues: [] });
      },
    });
    try {
      const res = createMockRes();
      const route = routes.match('POST', '/api/listings');
      await route.handler(
        {
          body: {
            asin: 'B000TEST',
            sku: 'AMLZ-20260728-002',
            conditionType: 'used_good',
            price: 1500,
            quantity: 2,
            conditionNote: '',
            fulfillmentChannel: 'AMAZON_JP',
          },
          headers: PRO_HEADERS,
        },
        res
      );
      assert.equal(res.statusCode, 200);
      assert.deepEqual(putBody.attributes.fulfillment_availability, [
        { fulfillment_channel_code: 'AMAZON_JP' },
      ]);
    } finally {
      global.fetch = originalFetch;
    }
  });
});

test('listings POST: fulfillmentChannel不正値は400', async () => {
  await withEnv(ENV, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('POST', '/api/listings');
    await route.handler(
      {
        body: {
          asin: 'B000TEST',
          sku: 'AMLZ-20260728-003',
          conditionType: 'used_good',
          price: 1500,
          quantity: 1,
          conditionNote: '',
          fulfillmentChannel: 'FBA_JP',
        },
        headers: PRO_HEADERS,
      },
      res
    );
    assert.equal(res.statusCode, 400);
  });
});

// --- GET /api/fees-estimate ---

test('fees-estimate: 無料は403 plan_required、Proでもトークン無しは403 spapi_link_required、seller-id無しは403 seller_id_required', async () => {
  await withEnv(ENV, async () => {
    const routes = freshRoutes();
    const route = routes.match('GET', '/api/fees-estimate');

    const res1 = createMockRes();
    await route.handler({ query: { asin: 'B000TEST', price: '1500' }, headers: {} }, res1);
    assert.equal(res1.statusCode, 403);
    assert.equal(res1.body.error, 'plan_required');

    const res2 = createMockRes();
    await route.handler({ query: { asin: 'B000TEST', price: '1500' }, headers: { 'x-app-plan': 'pro' } }, res2);
    assert.equal(res2.statusCode, 403);
    assert.equal(res2.body.error, 'spapi_link_required');

    const res3 = createMockRes();
    await route.handler(
      { query: { asin: 'B000TEST', price: '1500' }, headers: { 'x-app-plan': 'pro', 'x-spapi-refresh-token': 'rt' } },
      res3
    );
    assert.equal(res3.statusCode, 403);
    assert.equal(res3.body.error, 'seller_id_required');
  });
});

test('fees-estimate: asin/price不正は400(ゲートより先に検証する)', async () => {
  const routes = freshRoutes();
  const route = routes.match('GET', '/api/fees-estimate');

  for (const query of [
    {},
    { asin: 'B000TEST' },
    { asin: 'B000TEST', price: '0' },
    { asin: 'B000TEST', price: '-100' },
    { asin: 'B000TEST', price: '1500.5' },
    { asin: 'B000TEST', price: 'abc' },
    { asin: 'B000TEST', price: '1500', fba: '2' },
  ]) {
    const res = createMockRes();
    // ヘッダー無し(未認証)でも、入力不正は403より先に400で返ることを確認する。
    await route.handler({ query, headers: {} }, res);
    assert.equal(res.statusCode, 400, JSON.stringify(query));
  }
});

test('fees-estimate: fba=0(既定)はIsAmazonFulfilled:false、fba=1はtrueでリクエストする', async () => {
  await withEnv(ENV, async () => {
    const routes = freshRoutes();
    const originalFetch = global.fetch;
    let lastBody = null;
    global.fetch = mockFetch({
      feesEstimate: (u, init, ok) => {
        lastBody = JSON.parse(init.body);
        return feesEstimateOk(ok, []);
      },
    });
    try {
      const route = routes.match('GET', '/api/fees-estimate');

      const res1 = createMockRes();
      await route.handler({ query: { asin: 'B000TEST', price: '1500' }, headers: PRO_HEADERS }, res1);
      assert.equal(res1.statusCode, 200);
      assert.equal(lastBody.FeesEstimateRequestList[0].FeesEstimateRequest.IsAmazonFulfilled, false);

      const res2 = createMockRes();
      await route.handler({ query: { asin: 'B000TEST', price: '1500', fba: '1' }, headers: PRO_HEADERS }, res2);
      assert.equal(res2.statusCode, 200);
      assert.equal(lastBody.FeesEstimateRequestList[0].FeesEstimateRequest.IsAmazonFulfilled, true);
    } finally {
      global.fetch = originalFetch;
    }
  });
});

test('fees-estimate: FeeDetailListのFeeTypeをreferral/closing/fba/otherにマッピングし、金額を落とさない', async () => {
  await withEnv(ENV, async () => {
    const routes = freshRoutes();
    const originalFetch = global.fetch;
    global.fetch = mockFetch({
      feesEstimate: (u, init, ok) =>
        feesEstimateOk(ok, [
          { FeeType: 'ReferralFee', FeeAmount: { CurrencyCode: 'JPY', Amount: 270 } },
          { FeeType: 'VariableClosingFee', FeeAmount: { CurrencyCode: 'JPY', Amount: 80 } },
          { FeeType: 'FBAPerUnitFulfillmentFee', FeeAmount: { CurrencyCode: 'JPY', Amount: 268 } },
          { FeeType: 'SomeUnknownFee', FeeAmount: { CurrencyCode: 'JPY', Amount: 50 } },
        ]),
    });
    try {
      const res = createMockRes();
      const route = routes.match('GET', '/api/fees-estimate');
      await route.handler({ query: { asin: 'B000TEST', price: '1500', fba: '1' }, headers: PRO_HEADERS }, res);
      assert.equal(res.statusCode, 200);
      const byType = Object.fromEntries(res.body.breakdown.map((r) => [r.type, r]));
      assert.equal(byType.referral.label, '販売手数料');
      assert.equal(byType.referral.amount, 270);
      assert.equal(byType.closing.label, 'カテゴリ成約料');
      assert.equal(byType.closing.amount, 80);
      assert.equal(byType.fba.label, 'FBA手数料');
      assert.equal(byType.fba.amount, 268);
      assert.equal(byType.other.label, 'SomeUnknownFee');
      assert.equal(byType.other.amount, 50);
      // 消費税欄が無い(TaxAmount欠落)ため、手数料小計(270+80+268+50=668)の10%=67(Math.round)を概算計上
      assert.equal(byType.tax.label, '消費税');
      assert.equal(byType.tax.amount, 67);
      // totalはbreakdown各行の合計と一致する
      const sum = res.body.breakdown.reduce((s, r) => s + r.amount, 0);
      assert.equal(res.body.total, sum);
      assert.equal(res.body.total, 270 + 80 + 268 + 50 + 67);
    } finally {
      global.fetch = originalFetch;
    }
  });
});

test('fees-estimate: TaxAmountがある場合はその合計を消費税として使う(小計10%概算にしない)', async () => {
  await withEnv(ENV, async () => {
    const routes = freshRoutes();
    const originalFetch = global.fetch;
    global.fetch = mockFetch({
      feesEstimate: (u, init, ok) =>
        feesEstimateOk(ok, [
          {
            FeeType: 'ReferralFee',
            FeeAmount: { CurrencyCode: 'JPY', Amount: 270 },
            TaxAmount: { CurrencyCode: 'JPY', Amount: 50 },
          },
          {
            FeeType: 'VariableClosingFee',
            FeeAmount: { CurrencyCode: 'JPY', Amount: 80 },
            TaxAmount: { CurrencyCode: 'JPY', Amount: 20 },
          },
        ]),
    });
    try {
      const res = createMockRes();
      const route = routes.match('GET', '/api/fees-estimate');
      await route.handler({ query: { asin: 'B000TEST', price: '1500' }, headers: PRO_HEADERS }, res);
      assert.equal(res.statusCode, 200);
      const byType = Object.fromEntries(res.body.breakdown.map((r) => [r.type, r]));
      // TaxAmount実合計(50+20=70)を使う。10%概算フォールバック((270+80)*0.1=35)とは異なる値になることで
      // 実合計経路が使われていることを確認する。
      assert.equal(byType.tax.amount, 70);
      const sum = res.body.breakdown.reduce((s, r) => s + r.amount, 0);
      assert.equal(res.body.total, sum);
    } finally {
      global.fetch = originalFetch;
    }
  });
});

test('fees-estimate: SP-API呼び出し失敗は502 fees_estimate_failed', async () => {
  await withEnv(ENV, async () => {
    const routes = freshRoutes();
    const originalFetch = global.fetch;
    global.fetch = mockFetch({
      // 4xxはリトライ対象外(client.jsは429/5xx・fetch自体の例外のみリトライする)なので即座に失敗させられる。
      feesEstimate: () => ({
        ok: false,
        status: 400,
        text: async () => 'bad request',
        headers: { get: () => null },
      }),
    });
    try {
      const res = createMockRes();
      const route = routes.match('GET', '/api/fees-estimate');
      await route.handler({ query: { asin: 'B000TEST', price: '1500' }, headers: PRO_HEADERS }, res);
      assert.equal(res.statusCode, 502);
      assert.equal(res.body.error, 'fees_estimate_failed');
    } finally {
      global.fetch = originalFetch;
    }
  });
});
});
