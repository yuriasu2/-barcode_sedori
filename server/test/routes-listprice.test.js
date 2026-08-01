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

function freshRoutes() {
  delete require.cache[require.resolve('../src/routes')];
  delete require.cache[require.resolve('../src/spapi/pricing')];
  delete require.cache[require.resolve('../src/deviceQuota')];
  return require('../src/routes');
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

// --- extractListPriceJpy(定価抽出ヘルパー)単体 ---

test('extractListPriceJpy: 値ありは税抜→税込(×1.10)換算して整数丸め', () => {
  const routes = freshRoutes();
  const item = { attributes: { list_price: [{ currency: 'JPY', value: 1300, marketplace_id: 'X' }] } };
  assert.equal(routes.extractListPriceJpy(item), 1430);
});

test('extractListPriceJpy: 実測値 1364 -> 税込1500', () => {
  const routes = freshRoutes();
  const item = { attributes: { list_price: [{ currency: 'JPY', value: 1364 }] } };
  assert.equal(routes.extractListPriceJpy(item), 1500);
});

test('extractListPriceJpy: list_price配列が空はnull', () => {
  const routes = freshRoutes();
  const item = { attributes: { list_price: [] } };
  assert.equal(routes.extractListPriceJpy(item), null);
});

test('extractListPriceJpy: attributes/list_priceキー欠落はnull', () => {
  const routes = freshRoutes();
  assert.equal(routes.extractListPriceJpy({}), null);
  assert.equal(routes.extractListPriceJpy({ attributes: {} }), null);
  assert.equal(routes.extractListPriceJpy(null), null);
});

test('extractListPriceJpy: valueが数値でない(文字列)はnull', () => {
  const routes = freshRoutes();
  const item = { attributes: { list_price: [{ currency: 'JPY', value: '1300' }] } };
  assert.equal(routes.extractListPriceJpy(item), null);
});

// --- /api/search (spapi経路): profitInputs.listPrice に税込換算値が入ること ---

test('/api/search spapi経路: profitInputsのlistPriceにCatalogのattributes.list_priceを税込換算した値が入る', async () => {
  await withEnv(
    {
      LWA_CLIENT_ID: 'client-id',
      LWA_CLIENT_SECRET: 'client-secret',
      LWA_REFRESH_TOKEN: 'refresh-token',
    },
    async () => {
      const routes = freshRoutes();
      const pricing = require('../src/spapi/pricing');

      pricing.searchCatalogItems = async () => ({
        items: [
          {
            asin: 'B000TEST1',
            summaries: [{ itemName: 'テスト書籍', releaseDate: '2019-05-30' }],
            images: [],
            salesRanks: [],
            attributes: { list_price: [{ currency: 'JPY', value: 1300 }] },
          },
        ],
      });
      pricing.getItemOffers = async () => ({
        payload: {
          Summary: { TotalOfferCount: 1, LowestPrices: [], BuyBoxPrices: [] },
          Offers: [],
        },
      });
      pricing.getMyFeesEstimatesBatch = async () => ({ payload: [] });

      const route = routes.match('GET', '/api/search');
      const res = createMockRes();
      await route.handler(
        { query: { code: '9784000000000' }, headers: { 'x-app-plan': 'pro' } },
        res
      );

      assert.equal(res.body.profitInputs.listPrice, 1430);
      assert.equal(res.body.releaseDate, '2019-05-30');
      assert.equal(res.body.source, 'spapi');
    }
  );
});

test('/api/search spapi経路: attributes.list_priceが無い商品はlistPriceがnull', async () => {
  await withEnv(
    {
      LWA_CLIENT_ID: 'client-id',
      LWA_CLIENT_SECRET: 'client-secret',
      LWA_REFRESH_TOKEN: 'refresh-token',
    },
    async () => {
      const routes = freshRoutes();
      const pricing = require('../src/spapi/pricing');

      pricing.searchCatalogItems = async () => ({
        items: [
          {
            asin: 'B000TEST2',
            summaries: [{ itemName: 'テスト書籍2' }],
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

      const route = routes.match('GET', '/api/search');
      const res = createMockRes();
      await route.handler(
        { query: { code: '9784000000001' }, headers: { 'x-app-plan': 'pro' } },
        res
      );

      assert.equal(res.body.profitInputs.listPrice, null);
      assert.equal(res.body.releaseDate, null);
    }
  );
});

// --- extractCatalogFields: releaseDate(summaries[0].releaseDate)の抽出 ---

test('extractCatalogFields: summaries[0].releaseDateをそのままreleaseDateとして返す', () => {
  const routes = freshRoutes();
  const item = { asin: 'B000TEST9', summaries: [{ itemName: 'x', releaseDate: '2019-05-30' }] };
  assert.equal(routes.extractCatalogFields(item).releaseDate, '2019-05-30');
});

test('extractCatalogFields: releaseDate欠落/itemがnullはnullを返す', () => {
  const routes = freshRoutes();
  assert.equal(routes.extractCatalogFields({ asin: 'B000TEST10', summaries: [{}] }).releaseDate, null);
  assert.equal(routes.extractCatalogFields(null).releaseDate, null);
});

// --- extractCatalogFields: modelNumber(型番)の抽出 ---

test('extractCatalogFields: summaries[0].modelNumberをmodelNumberとして返す', () => {
  const routes = freshRoutes();
  const item = { asin: 'B000TEST11', summaries: [{ itemName: 'x', modelNumber: 'ABC-123' }] };
  assert.equal(routes.extractCatalogFields(item).modelNumber, 'ABC-123');
});

test('extractCatalogFields: modelNumberが無い場合はpartNumberにフォールバックする', () => {
  const routes = freshRoutes();
  const item = { asin: 'B000TEST12', summaries: [{ itemName: 'x', partNumber: 'PN-999' }] };
  assert.equal(routes.extractCatalogFields(item).modelNumber, 'PN-999');
});

test('extractCatalogFields: modelNumber/partNumberとも欠落(書籍等)はnullを返す', () => {
  const routes = freshRoutes();
  assert.equal(routes.extractCatalogFields({ asin: 'B000TEST13', summaries: [{ itemName: '書籍' }] }).modelNumber, null);
  assert.equal(routes.extractCatalogFields(null).modelNumber, null);
});

// --- /api/search (spapi経路): レスポンスにmodelNumberが含まれること ---

test('/api/search spapi経路: レスポンスにCatalogのmodelNumberが含まれる', async () => {
  await withEnv(
    {
      LWA_CLIENT_ID: 'client-id',
      LWA_CLIENT_SECRET: 'client-secret',
      LWA_REFRESH_TOKEN: 'refresh-token',
    },
    async () => {
      const routes = freshRoutes();
      const pricing = require('../src/spapi/pricing');

      pricing.searchCatalogItems = async () => ({
        items: [
          {
            asin: 'B000TEST3',
            summaries: [{ itemName: 'テスト商品', modelNumber: 'MODEL-001' }],
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

      const route = routes.match('GET', '/api/search');
      const res = createMockRes();
      await route.handler(
        { query: { code: '9784000000003' }, headers: { 'x-app-plan': 'pro' } },
        res
      );

      assert.equal(res.body.modelNumber, 'MODEL-001');
      assert.equal(res.body.source, 'spapi');
    }
  );
});

test('/api/search spapi経路: 型番の無い商品(書籍等)はmodelNumberがnull', async () => {
  await withEnv(
    {
      LWA_CLIENT_ID: 'client-id',
      LWA_CLIENT_SECRET: 'client-secret',
      LWA_REFRESH_TOKEN: 'refresh-token',
    },
    async () => {
      const routes = freshRoutes();
      const pricing = require('../src/spapi/pricing');

      pricing.searchCatalogItems = async () => ({
        items: [
          {
            asin: 'B000TEST4',
            summaries: [{ itemName: 'テスト書籍3' }],
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

      const route = routes.match('GET', '/api/search');
      const res = createMockRes();
      await route.handler(
        { query: { code: '9784000000002' }, headers: { 'x-app-plan': 'pro' } },
        res
      );

      assert.equal(res.body.modelNumber, null);
    }
  );
});

// --- pricing.searchCatalogItems: includedDataにattributesが含まれること ---

test('pricing.searchCatalogItems: includedDataにattributesを含めてリクエストする(fetchモック)', async (t) => {
  delete require.cache[require.resolve('../src/spapi/pricing')];
  delete require.cache[require.resolve('../src/spapi/client')];
  delete require.cache[require.resolve('../src/spapi/auth')];
  const pricing = require('../src/spapi/pricing');
  const auth = require('../src/spapi/auth');
  auth._resetCache();

  const originalFetch = global.fetch;
  let capturedUrl = null;
  global.fetch = async (url) => {
    if (String(url).includes('/auth/o2/token')) {
      return {
        ok: true,
        status: 200,
        json: async () => ({ access_token: 'test-token' }),
        text: async () => '',
      };
    }
    capturedUrl = String(url);
    return {
      ok: true,
      status: 200,
      headers: { get: () => null },
      json: async () => ({ items: [] }),
      text: async () => '',
    };
  };

  t.after(() => {
    global.fetch = originalFetch;
    auth._resetCache();
  });

  await pricing.searchCatalogItems('9784000000000', {
    clientId: 'c',
    clientSecret: 's',
    refreshToken: 'r',
  });

  assert.ok(capturedUrl, 'catalog items へのリクエストが送信されること');
  const query = new URL(capturedUrl).searchParams;
  assert.equal(query.get('includedData'), 'summaries,images,salesRanks,attributes');
});
