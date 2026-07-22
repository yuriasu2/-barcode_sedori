'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

async function withEnv(vars, fn) {
  const saved = {};
  for (const key of Object.keys(vars)) {
    saved[key] = process.env[key];
    if (vars[key] === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = vars[key];
    }
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

function freshModules() {
  delete require.cache[require.resolve('../src/routes')];
  delete require.cache[require.resolve('../src/spapi/pricing')];
  delete require.cache[require.resolve('../src/deviceRateLimit')];
  delete require.cache[require.resolve('../src/keepa/client')];
  const routes = require('../src/routes');
  const pricing = require('../src/spapi/pricing');
  const keepa = require('../src/keepa/client');
  return { routes, pricing, keepa };
}

function createMockRes() {
  const res = {
    statusCode: 200,
    body: undefined,
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(body) {
      this.body = body;
      this.ended = true;
      return this;
    },
  };
  return res;
}

function mockCatalogAndOffers(pricing, asin) {
  pricing.searchCatalogItems = async () => ({
    items: [
      {
        asin,
        summaries: [{ itemName: 'テスト書籍' }],
        images: [],
        salesRanks: [],
      },
    ],
  });
  pricing.getItemOffers = async () => ({
    payload: {
      Summary: { TotalOfferCount: 0, LowestPrices: [], BuyBoxPrices: [] },
      Offers: [],
    },
  });
  pricing.getMyFeesEstimatesBatch = async () => ({ payload: [] });
}

const SPAPI_ENV = {
  LWA_CLIENT_ID: 'client-id',
  LWA_CLIENT_SECRET: 'client-secret',
  LWA_REFRESH_TOKEN: 'refresh-token',
  KEEPA_API_KEY: 'keepa-key',
};

test('/api/search spapi経路 + Pro: Keepaのbrand/dimensionsMm/weightGが応答にマージされる', async () => {
  await withEnv(SPAPI_ENV, async () => {
    const { routes, pricing, keepa } = freshModules();
    mockCatalogAndOffers(pricing, 'B000TEST1');

    let keepaCalled = false;
    keepa.getProduct = async ({ code }) => {
      keepaCalled = true;
      assert.equal(code, '9784000000000');
      return { product: { fake: true } };
    };
    keepa.mapProductToSearchResult = () => ({
      brand: 'テストブランド',
      dimensionsMm: { length: 200, width: 150, height: 10 },
      weightG: 300,
    });

    const route = routes.match('GET', '/api/search');
    const res = createMockRes();
    await route.handler(
      { query: { code: '9784000000000' }, headers: { 'x-app-plan': 'pro' } },
      res
    );

    assert.equal(keepaCalled, true, 'Proではkeepa.getProductが呼ばれること');
    assert.equal(res.body.source, 'spapi');
    assert.equal(res.body.brand, 'テストブランド');
    assert.deepEqual(res.body.dimensionsMm, { length: 200, width: 150, height: 10 });
    assert.equal(res.body.weightG, 300);
  });
});

test('/api/search spapi経路 + 無料: Keepaは呼ばれずbrand等はnull', async () => {
  await withEnv(SPAPI_ENV, async () => {
    const { routes, pricing, keepa } = freshModules();
    mockCatalogAndOffers(pricing, 'B000TEST2');

    let keepaCalled = false;
    keepa.getProduct = async () => {
      keepaCalled = true;
      return { product: { fake: true } };
    };
    keepa.mapProductToSearchResult = () => ({
      brand: 'テストブランド',
      dimensionsMm: { length: 200, width: 150, height: 10 },
      weightG: 300,
    });

    const route = routes.match('GET', '/api/search');
    const res = createMockRes();
    await route.handler(
      { query: { code: '9784000000002' }, headers: {} },
      res
    );

    assert.equal(keepaCalled, false, '無料ではkeepa.getProductが呼ばれないこと(トークン消費ゼロ)');
    assert.equal(res.body.brand, null);
    assert.equal(res.body.dimensionsMm, null);
    assert.equal(res.body.weightG, null);
  });
});

test('/api/search spapi経路 + Pro + Keepa失敗: brand等はnullのまま検索自体は成功', async () => {
  await withEnv(SPAPI_ENV, async () => {
    const { routes, pricing, keepa } = freshModules();
    mockCatalogAndOffers(pricing, 'B000TEST3');

    keepa.getProduct = async () => {
      throw new Error('keepa down');
    };

    const route = routes.match('GET', '/api/search');
    const res = createMockRes();
    await route.handler(
      { query: { code: '9784000000003' }, headers: { 'x-app-plan': 'pro' } },
      res
    );

    assert.equal(res.statusCode, 200);
    assert.equal(res.body.brand, null);
    assert.equal(res.body.dimensionsMm, null);
    assert.equal(res.body.weightG, null);
    assert.equal(res.body.asin, 'B000TEST3');
  });
});

test('/api/search spapi経路 キャッシュ分離: 無料でキャッシュされた結果はProの再検索に使われない', async () => {
  await withEnv(SPAPI_ENV, async () => {
    const { routes, pricing, keepa } = freshModules();
    mockCatalogAndOffers(pricing, 'B000TEST4');

    keepa.getProduct = async () => ({ product: { fake: true } });
    keepa.mapProductToSearchResult = () => ({
      brand: 'Proブランド',
      dimensionsMm: null,
      weightG: null,
    });

    const route = routes.match('GET', '/api/search');

    // 1回目: 無料(brand=null がキャッシュされる)
    const freeRes = createMockRes();
    await route.handler(
      { query: { code: '9784000000004' }, headers: {} },
      freeRes
    );
    assert.equal(freeRes.body.brand, null);

    // 2回目: 同一コードでPro(30分キャッシュ期間内でも無料のnull入りキャッシュを共有しないこと)
    const proRes = createMockRes();
    await route.handler(
      { query: { code: '9784000000004' }, headers: { 'x-app-plan': 'pro' } },
      proRes
    );
    assert.equal(proRes.body.brand, 'Proブランド');
  });
});
