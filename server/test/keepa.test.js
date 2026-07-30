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
  delete require.cache[require.resolve('../src/keepa/client')];
  return require('../src/routes');
}

function createMockRes() {
  const res = {
    statusCode: 200,
    headers: {},
    body: undefined,
    binaryBody: undefined,
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(body) {
      this.body = body;
      this.ended = true;
      return this;
    },
    binary(buf, contentType) {
      this.binaryBody = buf;
      this.headers['Content-Type'] = contentType;
      this.ended = true;
      return this;
    },
  };
  return res;
}

// フリーミアム: Keepa経路のオファー(第2段階)とグラフはPro限定のため、
// それらのデータ挙動を検証するテストはPro申告ヘッダーを付けて叩く。
const PRO = { 'x-app-plan': 'pro' };

// ---------------------------------------------------------------------------
// keepa/client.js 単体テスト
// ---------------------------------------------------------------------------

test('keepa client: mapProductToSearchResult は stats.current の -1 を null に変換し、imagesCSVから画像URLを組み立てる', () => {
  const keepa = require('../src/keepa/client');

  const product = {
    asin: 'B000TEST01',
    title: 'テスト商品',
    imagesCSV: '81abcXYZ.jpg,81defXYZ.jpg',
    stats: {
      // index: 0=AMAZON,1=NEW,2=USED,3=SALES
      current: [2500, 1500, 1200, -1, 3000],
    },
  };

  const mapped = keepa.mapProductToSearchResult(product);

  assert.equal(mapped.asin, 'B000TEST01');
  assert.equal(mapped.title, 'テスト商品');
  assert.equal(mapped.imageUrl, 'https://images-na.ssl-images-amazon.com/images/I/81abcXYZ.jpg');
  assert.equal(mapped.salesRank, null); // index3が-1なのでnull
  assert.equal(mapped.prices.new, 1500);
  assert.equal(mapped.prices.used, 1200);
  assert.equal(mapped.prices.cart, null); // 第1段階ではcartは常にnull
});

test('keepa client: mapProductToSearchResult はproductがnullならnullを返す', () => {
  const keepa = require('../src/keepa/client');
  assert.equal(keepa.mapProductToSearchResult(null), null);
});

test('keepa client: mapProductToSearchResult はlistPrice(税抜)を税込×1.10換算し、sellerCountsを正規化する(値あり)', () => {
  const keepa = require('../src/keepa/client');
  const current = new Array(19).fill(-1);
  current[4] = 2200; // LISTPRICE(税抜の生値)
  current[11] = 3; // COUNT_NEW
  current[12] = 12; // COUNT_USED
  const product = { asin: 'B000TEST03', stats: { current } };

  const mapped = keepa.mapProductToSearchResult(product);
  assert.equal(mapped.listPrice, 2420); // 2200 * 1.10 = 2420
  assert.deepEqual(mapped.sellerCounts, { new: 3, used: 12 });
});

test('keepa client: mapProductToSearchResult のlistPrice税込換算は実測値(9784065291702)で1364→1500になる', () => {
  const keepa = require('../src/keepa/client');
  const current = new Array(19).fill(-1);
  current[4] = 1364; // LISTPRICE(税抜。SP-APIのattributes.list_priceと完全一致した実測値)
  const product = { asin: 'B000TEST07', stats: { current } };

  const mapped = keepa.mapProductToSearchResult(product);
  assert.equal(mapped.listPrice, 1500); // 1364 * 1.10 = 1500.4 -> 丸めで1500
});

test('keepa client: mapProductToSearchResult はlistPrice/sellerCountsが-1(データなし)ならnullにする', () => {
  const keepa = require('../src/keepa/client');
  const current = new Array(19).fill(-1);
  const product = { asin: 'B000TEST04', stats: { current } };

  const mapped = keepa.mapProductToSearchResult(product);
  assert.equal(mapped.listPrice, null);
  assert.deepEqual(mapped.sellerCounts, { new: null, used: null });
});

test('keepa client: mapProductToSearchResult はsellerCountsが0件(有効値)ならnullにしない', () => {
  const keepa = require('../src/keepa/client');
  const current = new Array(19).fill(-1);
  current[11] = 0; // COUNT_NEW: 出品者0人(有効値)
  current[12] = 0; // COUNT_USED
  const product = { asin: 'B000TEST05', stats: { current } };

  const mapped = keepa.mapProductToSearchResult(product);
  assert.deepEqual(mapped.sellerCounts, { new: 0, used: 0 });
});

test('keepa client: mapProductToSearchResult はstats.current配列が欠落(空)していてもlistPrice/sellerCountsをnullで返す', () => {
  const keepa = require('../src/keepa/client');
  const product = { asin: 'B000TEST06', stats: {} };

  const mapped = keepa.mapProductToSearchResult(product);
  assert.equal(mapped.listPrice, null);
  assert.deepEqual(mapped.sellerCounts, { new: null, used: null });
});

test('keepa client: mapKeepaReleaseDate はYYYYMMDD(8桁)をISO日付文字列に変換する', () => {
  const keepa = require('../src/keepa/client');
  assert.equal(keepa.mapKeepaReleaseDate(20150409), '2015-04-09');
});

test('keepa client: mapKeepaReleaseDate はYYYY(4桁)/YYYYMM(6桁)は日が確定しないためnullを返す', () => {
  const keepa = require('../src/keepa/client');
  assert.equal(keepa.mapKeepaReleaseDate(1978), null);
  assert.equal(keepa.mapKeepaReleaseDate(200301), null);
});

test('keepa client: mapKeepaReleaseDate は-1(取得不可)/未指定はnullを返す', () => {
  const keepa = require('../src/keepa/client');
  assert.equal(keepa.mapKeepaReleaseDate(-1), null);
  assert.equal(keepa.mapKeepaReleaseDate(undefined), null);
  assert.equal(keepa.mapKeepaReleaseDate(null), null);
});

test('keepa client: mapProductToSearchResult はproduct.releaseDateをreleaseDate(ISO文字列)にマッピングする', () => {
  const keepa = require('../src/keepa/client');
  const product = { asin: 'B000TEST08', stats: { current: [] }, releaseDate: 20190530 };
  const mapped = keepa.mapProductToSearchResult(product);
  assert.equal(mapped.releaseDate, '2019-05-30');
});

test('keepa client: mapProductToSearchResult はproduct.releaseDate未取得(-1)ならreleaseDateはnull', () => {
  const keepa = require('../src/keepa/client');
  const product = { asin: 'B000TEST09', stats: { current: [] }, releaseDate: -1 };
  const mapped = keepa.mapProductToSearchResult(product);
  assert.equal(mapped.releaseDate, null);
});

test('keepa client: resolveImageUrl は新形式images配列(images[0].l)を優先する', () => {
  const keepa = require('../src/keepa/client');
  const product = {
    images: [{ l: '91XleNxbSdL.jpg', m: 'medium.jpg' }],
    imagesCSV: 'old.jpg',
  };
  assert.equal(
    keepa.resolveImageUrl(product),
    'https://images-na.ssl-images-amazon.com/images/I/91XleNxbSdL.jpg'
  );
});

test('keepa client: resolveImageUrl はimages未設定なら旧imagesCSVへフォールバックする', () => {
  const keepa = require('../src/keepa/client');
  assert.equal(
    keepa.resolveImageUrl({ imagesCSV: 'legacy.jpg' }),
    'https://images-na.ssl-images-amazon.com/images/I/legacy.jpg'
  );
  assert.equal(keepa.resolveImageUrl({}), null);
});

test('keepa client: mapProductToSearchResult は新形式images配列から画像URLを組み立てる', () => {
  const keepa = require('../src/keepa/client');
  const product = {
    asin: 'B000TEST02',
    title: '新形式画像テスト',
    images: [{ l: 'newFormat.jpg' }],
    stats: { current: [-1, 7318, 2898, -1] },
  };
  const mapped = keepa.mapProductToSearchResult(product);
  assert.equal(mapped.imageUrl, 'https://images-na.ssl-images-amazon.com/images/I/newFormat.jpg');
  assert.equal(mapped.prices.new, 7318);
  assert.equal(mapped.prices.used, 2898);
});

test('keepa client: extractLatestOfferPrice はofferCSV末尾2要素(price, shipping)を取得する', () => {
  const keepa = require('../src/keepa/client');
  // [keepa分, price, shipping, keepa分, price, shipping]
  const offerCsv = [5000000, 1000, 300, 5000100, 1500, 0];
  const { price, shipping } = keepa.extractLatestOfferPrice(offerCsv);
  assert.equal(price, 1500);
  assert.equal(shipping, 0);
});

test('keepa client: extractLatestOfferPrice は-1/-2(データなし)をnullとして扱う', () => {
  const keepa = require('../src/keepa/client');
  const offerCsv = [5000000, -1, -2];
  const { price, shipping } = keepa.extractLatestOfferPrice(offerCsv);
  assert.equal(price, null);
  assert.equal(shipping, null);
});

test('keepa client: extractLatestOfferPrice は空/不正な配列でnullを返す', () => {
  const keepa = require('../src/keepa/client');
  assert.deepEqual(keepa.extractLatestOfferPrice(null), { price: null, shipping: null });
  assert.deepEqual(keepa.extractLatestOfferPrice([]), { price: null, shipping: null });
});

test('keepa client: conditionToString はOffer.OfferCondition定義(公式Java SDK)どおりに変換する', () => {
  const keepa = require('../src/keepa/client');
  assert.equal(keepa.conditionToString(1), 'new');
  assert.equal(keepa.conditionToString(2), 'like_new');
  assert.equal(keepa.conditionToString(3), 'very_good');
  assert.equal(keepa.conditionToString(4), 'good');
  assert.equal(keepa.conditionToString(5), 'acceptable');
});

test('keepa client: isOfferFresh はlastSeenが24時間以内かどうかを判定する', () => {
  const keepa = require('../src/keepa/client');
  const nowKeepaMinutes = Math.floor((Date.now() - keepa.keepaMinuteToUnixMs(0)) / 60000);

  // 現在時刻(新しい)
  assert.equal(keepa.isOfferFresh(nowKeepaMinutes), true);
  // 48時間前(古い)
  assert.equal(keepa.isOfferFresh(nowKeepaMinutes - 48 * 60), false);
});

test('keepa client: extractOffersFromProduct は新品/中古を仕分けし、古いオファーを除外する', () => {
  const keepa = require('../src/keepa/client');
  const nowKeepaMinutes = Math.floor((Date.now() - keepa.keepaMinuteToUnixMs(0)) / 60000);

  const product = {
    stats: {
      current: (() => {
        const arr = new Array(19).fill(-1);
        arr[18] = 1550; // BUY_BOX_SHIPPING
        arr[1] = 1500; // NEW
        return arr;
      })(),
    },
    offers: [
      {
        condition: 1, // New
        lastSeen: nowKeepaMinutes,
        offerCSV: [1, 1500, 50],
      },
      {
        condition: 4, // Used-Good
        lastSeen: nowKeepaMinutes,
        offerCSV: [1, 1200, 350],
      },
      {
        condition: 4,
        lastSeen: nowKeepaMinutes - 48 * 60, // 古い(48時間前) -> 除外
        offerCSV: [1, 999, 0],
      },
    ],
  };

  const { newOffers, usedOffers, referencePrice } = keepa.extractOffersFromProduct(product);
  assert.equal(newOffers.length, 1);
  assert.equal(usedOffers.length, 1); // 古いオファーは除外され1件のみ
  assert.equal(newOffers[0].price, 1500);
  assert.equal(newOffers[0].shipping, 50);
  assert.equal(newOffers[0].landed, 1550);
  assert.equal(usedOffers[0].condition, 'good');
  assert.equal(referencePrice, 1550); // BUY_BOX_SHIPPING優先
});

test('keepa client: extractOffersFromProduct は liveOffersOrder で現在有効なオファーのみ抽出する(古いlastSeenでも採用)', () => {
  const keepa = require('../src/keepa/client');

  const product = {
    stats: {
      current: (() => {
        const arr = new Array(19).fill(-1);
        arr[18] = 1550;
        return arr;
      })(),
    },
    // index0=過去の中古(liveでない), 1=有効な新品, 2=有効な中古
    liveOffersOrder: [2, 1],
    offers: [
      { condition: 4, lastSeen: 0, offerCSV: [1, 999, 0] }, // 古い/liveでない → 除外
      { condition: 1, lastSeen: 0, offerCSV: [1, 1500, 50] }, // live(新品) lastSeenは古いが採用
      { condition: 4, lastSeen: 0, offerCSV: [1, 1200, 350] }, // live(中古)
    ],
  };

  const { newOffers, usedOffers } = keepa.extractOffersFromProduct(product);
  assert.equal(newOffers.length, 1);
  assert.equal(usedOffers.length, 1);
  assert.equal(newOffers[0].price, 1500);
  assert.equal(usedOffers[0].price, 1200);
});

// ---------------------------------------------------------------------------
// /api/search: Keepaフォールバック経路
// ---------------------------------------------------------------------------

test('/api/search: SP-API未設定・KEEPA_API_KEYありならKeepa経路にフォールバックしsource:"keepa"を返す', async (t) => {
  await withEnv(
    {
      LWA_CLIENT_ID: undefined,
      LWA_CLIENT_SECRET: undefined,
      LWA_REFRESH_TOKEN: undefined,
      KEEPA_API_KEY: 'test-keepa-key',
    },
    async () => {
      const routes = freshRoutes();
      const keepa = require('../src/keepa/client');

      keepa.getProduct = async ({ code }) => {
        assert.equal(code, '9784471103644');
        return {
          product: {
            asin: 'B00KEEPATEST',
            title: 'Keepa経由の本',
            imagesCSV: 'sample.jpg',
            stats: { current: [2000, 1000, 800, 5000, 2200] },
            releaseDate: 20150409,
          },
        };
      };

      const req = { query: { code: '9784471103644' }, headers: {} };
      const res = createMockRes();
      const route = routes.match('GET', '/api/search');
      await route.handler(req, res);

      assert.equal(res.body.source, 'keepa');
      assert.equal(res.body.asin, 'B00KEEPATEST');
      assert.equal(res.body.prices.new, 1000);
      assert.equal(res.body.prices.used, 800);
      assert.equal(res.body.prices.cart, null);
      assert.equal(res.body.profitInputs.listPrice, 2420); // current[4]=2200(税抜) * 1.10 = 2420
      assert.equal(res.body.releaseDate, '2015-04-09'); // product.releaseDate(20150409)をISO文字列化
      assert.ok(typeof res.body.profitInputs.breakEven.new === 'number');
      assert.ok(typeof res.body.profitInputs.breakEven.used === 'number');

      t.after(() => {
        routes.searchCache.clear();
      });
    }
  );
});

test('/api/search: keepa経路のprofitInputsはunresolved等の早期returnでもnullとしてキーが存在する', async (t) => {
  await withEnv(
    {
      LWA_CLIENT_ID: undefined,
      LWA_CLIENT_SECRET: undefined,
      LWA_REFRESH_TOKEN: undefined,
      KEEPA_API_KEY: 'test-keepa-key',
    },
    async () => {
      const routes = freshRoutes();
      // convertCodeがunresolvedになる不正なコードを渡す。
      const req = { query: { code: 'not-a-valid-code' }, headers: {} };
      const res = createMockRes();
      const route = routes.match('GET', '/api/search');
      await route.handler(req, res);

      assert.ok('profitInputs' in res.body);
      assert.equal(res.body.profitInputs, null);
      assert.ok('releaseDate' in res.body);
      assert.equal(res.body.releaseDate, null);

      t.after(() => {
        routes.searchCache.clear();
      });
    }
  );
});

test('/api/search: keepa経路でproduct未取得(catalog_not_found)でもprofitInputsキーはnullで存在する', async (t) => {
  await withEnv(
    {
      LWA_CLIENT_ID: undefined,
      LWA_CLIENT_SECRET: undefined,
      LWA_REFRESH_TOKEN: undefined,
      KEEPA_API_KEY: 'test-keepa-key',
    },
    async () => {
      const routes = freshRoutes();
      const keepa = require('../src/keepa/client');
      keepa.getProduct = async () => ({ product: null });

      const req = { query: { code: '9784471103644' }, headers: {} };
      const res = createMockRes();
      const route = routes.match('GET', '/api/search');
      await route.handler(req, res);

      assert.equal(res.body.reason, 'catalog_not_found');
      assert.ok('profitInputs' in res.body);
      assert.equal(res.body.profitInputs, null);

      t.after(() => {
        routes.searchCache.clear();
      });
    }
  );
});

// ---------------------------------------------------------------------------
// /api/search: spapi経路のprofitInputs
// ---------------------------------------------------------------------------

test('/api/search: spapi経路はprofitInputs.sellerCounts/breakEvenを組み立て、attributes.list_price欠落時はlistPriceがnullを返す', async (t) => {
  await withEnv(
    {
      LWA_CLIENT_ID: 'client-id',
      LWA_CLIENT_SECRET: 'client-secret',
      LWA_REFRESH_TOKEN: 'refresh-token',
    },
    async () => {
      const routes = freshRoutes();
      const pricing = require('../src/spapi/pricing');

      const originalSearchCatalogItems = pricing.searchCatalogItems;
      const originalGetItemOffers = pricing.getItemOffers;
      const originalGetFees = pricing.getMyFeesEstimatesBatch;

      pricing.searchCatalogItems = async () => ({
        items: [
          {
            asin: 'B00SPAPITEST2',
            summaries: [{ itemName: 'SP-APIの本' }],
            images: [],
            salesRanks: [],
          },
        ],
      });

      pricing.getItemOffers = async (asin, condition) => {
        if (condition === 'New') {
          return {
            payload: {
              Summary: {
                TotalOfferCount: 4,
                LowestPrices: [{ condition: 'new', LandedPrice: { Amount: 1500 } }],
                BuyBoxPrices: [],
              },
              Offers: [
                { ListingPrice: { Amount: 1500 }, Shipping: { Amount: 0 }, IsBuyBoxWinner: true, SubCondition: 'New' },
              ],
            },
          };
        }
        return {
          payload: {
            Summary: {
              TotalOfferCount: 9,
              LowestPrices: [{ condition: 'used', LandedPrice: { Amount: 1200 } }],
              BuyBoxPrices: [],
            },
            Offers: [
              { ListingPrice: { Amount: 1000 }, Shipping: { Amount: 200 }, IsBuyBoxWinner: false, SubCondition: 'VeryGood' },
            ],
          },
        };
      };
      pricing.getMyFeesEstimatesBatch = async () => null; // フォールバック手数料を使わせる

      t.after(() => {
        pricing.searchCatalogItems = originalSearchCatalogItems;
        pricing.getItemOffers = originalGetItemOffers;
        pricing.getMyFeesEstimatesBatch = originalGetFees;
        routes.searchCache.clear();
      });

      const req = { query: { code: '9784471103644' }, headers: {} };
      const res = createMockRes();
      const route = routes.match('GET', '/api/search');
      await route.handler(req, res);

      assert.equal(res.body.source, 'spapi');
      assert.equal(res.body.profitInputs.listPrice, null);
      assert.deepEqual(res.body.profitInputs.sellerCounts, { new: 4, used: 9 });
      // オファーDTO(offers.new/used)にはbreakEvenを持たせず、profitInputs.breakEvenのみで算出する
      // (手数料APIがnullを返したため書籍フォールバック15%+80円を使用: 1500-305=1195, 1200-260=940)。
      assert.equal(res.body.offers.new[0].breakEven, undefined);
      assert.equal(res.body.offers.used[0].breakEven, undefined);
      assert.equal(res.body.profitInputs.breakEven.new, 1195);
      assert.equal(res.body.profitInputs.breakEven.used, 940);
    }
  );
});

test('/api/search: spapi経路のprofitInputs.breakEvenはgetMyFeesEstimatesBatchの実額(new/usedのlanded最安のみ2件)から算出する', async (t) => {
  await withEnv(
    {
      LWA_CLIENT_ID: 'client-id',
      LWA_CLIENT_SECRET: 'client-secret',
      LWA_REFRESH_TOKEN: 'refresh-token',
    },
    async () => {
      const routes = freshRoutes();
      const pricing = require('../src/spapi/pricing');

      const originalSearchCatalogItems = pricing.searchCatalogItems;
      const originalGetItemOffers = pricing.getItemOffers;
      const originalGetFees = pricing.getMyFeesEstimatesBatch;

      pricing.searchCatalogItems = async () => ({
        items: [{ asin: 'B00SPAPITEST3', summaries: [{ itemName: 'SP-APIの本' }], images: [], salesRanks: [] }],
      });

      pricing.getItemOffers = async (asin, condition) => {
        if (condition === 'New') {
          return {
            payload: {
              Summary: { TotalOfferCount: 2, LowestPrices: [{ condition: 'new', LandedPrice: { Amount: 1500 } }], BuyBoxPrices: [] },
              Offers: [
                { ListingPrice: { Amount: 1500 }, Shipping: { Amount: 0 }, IsBuyBoxWinner: true, SubCondition: 'New' },
                { ListingPrice: { Amount: 1800 }, Shipping: { Amount: 0 }, IsBuyBoxWinner: false, SubCondition: 'New' },
              ],
            },
          };
        }
        return {
          payload: {
            Summary: { TotalOfferCount: 1, LowestPrices: [{ condition: 'used', LandedPrice: { Amount: 1000 } }], BuyBoxPrices: [] },
            Offers: [{ ListingPrice: { Amount: 900 }, Shipping: { Amount: 100 }, IsBuyBoxWinner: false, SubCondition: 'VeryGood' }],
          },
        };
      };

      let receivedItems = null;
      pricing.getMyFeesEstimatesBatch = async (items) => {
        receivedItems = items;
        // 実応答はトップレベルが素の配列(各要素がFeesEstimateResult)
        return items.map((item) => ({
          FeesEstimateResult: { FeesEstimate: { TotalFeesEstimate: { Amount: item.price === 1500 ? 305 : 260 } } },
        }));
      };

      t.after(() => {
        pricing.searchCatalogItems = originalSearchCatalogItems;
        pricing.getItemOffers = originalGetItemOffers;
        pricing.getMyFeesEstimatesBatch = originalGetFees;
        routes.searchCache.clear();
      });

      const req = { query: { code: '9784471103644' }, headers: {} };
      const res = createMockRes();
      const route = routes.match('GET', '/api/search');
      await route.handler(req, res);

      assert.equal(res.body.source, 'spapi');
      // new/usedのlanded最安1件ずつ、計2件のみを見積り対象にする
      assert.equal(receivedItems.length, 2);
      assert.equal(receivedItems[0].price, 1500); // new最安(1500 < 1800)
      assert.equal(receivedItems[1].price, 1000); // used最安(900+100)
      assert.equal(res.body.profitInputs.breakEven.new, 1195); // 1500-305
      assert.equal(res.body.profitInputs.breakEven.used, 740); // 1000-260
    }
  );
});

test('/api/search: spapi経路でnew/usedともオファー0件ならprofitInputs.breakEvenはnullで、手数料APIを呼ばない', async (t) => {
  await withEnv(
    {
      LWA_CLIENT_ID: 'client-id',
      LWA_CLIENT_SECRET: 'client-secret',
      LWA_REFRESH_TOKEN: 'refresh-token',
    },
    async () => {
      const routes = freshRoutes();
      const pricing = require('../src/spapi/pricing');

      const originalSearchCatalogItems = pricing.searchCatalogItems;
      const originalGetItemOffers = pricing.getItemOffers;
      const originalGetFees = pricing.getMyFeesEstimatesBatch;

      pricing.searchCatalogItems = async () => ({
        items: [{ asin: 'B00SPAPITEST4', summaries: [{ itemName: 'SP-APIの本' }], images: [], salesRanks: [] }],
      });
      pricing.getItemOffers = async () => ({
        payload: { Summary: { TotalOfferCount: 0, LowestPrices: [], BuyBoxPrices: [] }, Offers: [] },
      });
      let feesCalled = false;
      pricing.getMyFeesEstimatesBatch = async () => {
        feesCalled = true;
        return [];
      };

      t.after(() => {
        pricing.searchCatalogItems = originalSearchCatalogItems;
        pricing.getItemOffers = originalGetItemOffers;
        pricing.getMyFeesEstimatesBatch = originalGetFees;
        routes.searchCache.clear();
      });

      const req = { query: { code: '9784471103644' }, headers: {} };
      const res = createMockRes();
      const route = routes.match('GET', '/api/search');
      await route.handler(req, res);

      assert.equal(res.body.source, 'spapi');
      assert.equal(res.body.profitInputs.breakEven.new, null);
      assert.equal(res.body.profitInputs.breakEven.used, null);
      assert.equal(feesCalled, false);
    }
  );
});

test('/api/search: spapi経路でgetMyFeesEstimatesBatchが例外を投げてもprofitInputsは壊れず書籍フォールバック(15%+80円)で算出する', async (t) => {
  await withEnv(
    {
      LWA_CLIENT_ID: 'client-id',
      LWA_CLIENT_SECRET: 'client-secret',
      LWA_REFRESH_TOKEN: 'refresh-token',
    },
    async () => {
      const routes = freshRoutes();
      const pricing = require('../src/spapi/pricing');

      const originalSearchCatalogItems = pricing.searchCatalogItems;
      const originalGetItemOffers = pricing.getItemOffers;
      const originalGetFees = pricing.getMyFeesEstimatesBatch;

      pricing.searchCatalogItems = async () => ({
        items: [{ asin: 'B00SPAPITEST5', summaries: [{ itemName: 'SP-APIの本' }], images: [], salesRanks: [] }],
      });
      pricing.getItemOffers = async (asin, condition) => {
        if (condition === 'New') {
          return {
            payload: {
              Summary: { TotalOfferCount: 1, LowestPrices: [{ condition: 'new', LandedPrice: { Amount: 1500 } }], BuyBoxPrices: [] },
              Offers: [{ ListingPrice: { Amount: 1500 }, Shipping: { Amount: 0 }, IsBuyBoxWinner: true, SubCondition: 'New' }],
            },
          };
        }
        return { payload: { Summary: { TotalOfferCount: 0, LowestPrices: [], BuyBoxPrices: [] }, Offers: [] } };
      };
      pricing.getMyFeesEstimatesBatch = async () => {
        throw new Error('fees_estimate_boom');
      };

      t.after(() => {
        pricing.searchCatalogItems = originalSearchCatalogItems;
        pricing.getItemOffers = originalGetItemOffers;
        pricing.getMyFeesEstimatesBatch = originalGetFees;
        routes.searchCache.clear();
      });

      const req = { query: { code: '9784471103644' }, headers: {} };
      const res = createMockRes();
      const route = routes.match('GET', '/api/search');
      await route.handler(req, res);

      assert.equal(res.body.source, 'spapi');
      assert.equal(res.body.profitInputs.breakEven.new, 1195); // 1500-(round(1500*0.15)+80)
      assert.equal(res.body.profitInputs.breakEven.used, null);
    }
  );
});

test('/api/search: spapi経路はunresolvedの早期returnでもprofitInputsキーがnullで存在する', async () => {
  await withEnv(
    {
      LWA_CLIENT_ID: 'client-id',
      LWA_CLIENT_SECRET: 'client-secret',
      LWA_REFRESH_TOKEN: 'refresh-token',
    },
    async () => {
      const routes = freshRoutes();
      const req = { query: { code: 'not-a-valid-code' }, headers: {} };
      const res = createMockRes();
      const route = routes.match('GET', '/api/search');
      await route.handler(req, res);

      assert.ok('profitInputs' in res.body);
      assert.equal(res.body.profitInputs, null);
    }
  );
});

test('/api/search: SP-API未設定かつKEEPA_API_KEYも未設定なら503(メッセージ更新済み)', async () => {
  await withEnv(
    {
      LWA_CLIENT_ID: undefined,
      LWA_CLIENT_SECRET: undefined,
      LWA_REFRESH_TOKEN: undefined,
      KEEPA_API_KEY: undefined,
    },
    async () => {
      const routes = freshRoutes();
      const req = { query: { code: '9784471103644' }, headers: {} };
      const res = createMockRes();
      const route = routes.match('GET', '/api/search');
      await route.handler(req, res);

      assert.equal(res.statusCode, 503);
      assert.equal(res.body.error, 'spapi_credentials_missing');
      assert.equal(res.body.message, 'SP-API連携またはサーバーのKeepa設定が必要です');
    }
  );
});

// ---------------------------------------------------------------------------
// /api/offers: 統一契約(spapi/keepa)
// ---------------------------------------------------------------------------

test('/api/offers: source=keepaで統一契約(source/referencePrice/newCount/usedCount/new/used)を返す', async (t) => {
  await withEnv({ KEEPA_API_KEY: 'test-keepa-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');

    const nowKeepaMinutes = Math.floor((Date.now() - keepa.keepaMinuteToUnixMs(0)) / 60000);

    keepa.getProduct = async ({ asin, offers }) => {
      assert.equal(asin, 'B00KEEPATEST');
      assert.equal(offers, 20);
      return {
        product: {
          asin: 'B00KEEPATEST',
          stats: {
            current: (() => {
              const arr = new Array(19).fill(-1);
              arr[18] = 1700; // BUY_BOX_SHIPPING
              return arr;
            })(),
          },
          offers: [
            { condition: 1, lastSeen: nowKeepaMinutes, offerCSV: [1, 1500, 0] },
            { condition: 4, lastSeen: nowKeepaMinutes, offerCSV: [1, 1200, 350] },
          ],
        },
      };
    };

    const req = { query: { asin: 'B00KEEPATEST', source: 'keepa' }, headers: PRO };
    const res = createMockRes();
    const route = routes.match('GET', '/api/offers');
    await route.handler(req, res);

    assert.equal(res.body.source, 'keepa');
    assert.equal(res.body.referencePrice, 1700);
    assert.equal(res.body.newCount, 1);
    assert.equal(res.body.usedCount, 1);
    assert.equal(res.body.new[0].price, 1500);
    assert.equal(res.body.new[0].condition, 'new');
    assert.equal(res.body.new[0].breakEven, undefined);
    assert.equal(res.body.used[0].condition, 'good');
    assert.equal(res.body.used[0].landed, 1550);
    assert.equal(res.body.used[0].breakEven, undefined);

    t.after(() => {
      routes.offersCache.clear();
    });
  });
});

test('/api/offers: source=keepaで個別オファーが空でもstats.currentの最安値でフォールバック表示する', async (t) => {
  await withEnv({ KEEPA_API_KEY: 'test-keepa-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');

    // offers配列は空 / 24時間フィルタで全除外を想定。statsには new=7318, used=2898 がある。
    keepa.getProduct = async ({ asin, offers }) => {
      assert.equal(asin, 'B00KEEPAFALLBACK');
      assert.equal(offers, 20);
      return {
        product: {
          asin: 'B00KEEPAFALLBACK',
          stats: {
            current: (() => {
              const arr = new Array(19).fill(-1);
              arr[1] = 7318; // NEW
              arr[2] = 2898; // USED
              return arr;
            })(),
          },
          offers: [],
        },
      };
    };

    const req = { query: { asin: 'B00KEEPAFALLBACK', source: 'keepa' }, headers: PRO };
    const res = createMockRes();
    const route = routes.match('GET', '/api/offers');
    await route.handler(req, res);

    assert.equal(res.body.source, 'keepa');
    assert.equal(res.body.newCount, 1);
    assert.equal(res.body.usedCount, 1);
    assert.equal(res.body.new[0].price, 7318);
    assert.equal(res.body.new[0].condition, 'new');
    assert.equal(res.body.used[0].price, 2898);
    assert.equal(res.body.used[0].condition, 'used');
    assert.equal(res.body.new[0].breakEven, undefined);
    assert.equal(res.body.used[0].breakEven, undefined);

    t.after(() => {
      routes.offersCache.clear();
    });
  });
});

test('/api/offers: source省略時(spapi既定)はcondition文字列に変換し、オファーDTOにbreakEvenを含まない', async (t) => {
  await withEnv(
    {
      LWA_CLIENT_ID: 'client-id',
      LWA_CLIENT_SECRET: 'client-secret',
      LWA_REFRESH_TOKEN: 'refresh-token',
    },
    async () => {
      const routes = freshRoutes();
      const pricing = require('../src/spapi/pricing');

      const originalGetItemOffers = pricing.getItemOffers;

      pricing.getItemOffers = async (asin, condition) => {
        if (condition === 'New') {
          return {
            payload: {
              Summary: { LowestPrices: [{ LandedPrice: { Amount: 1500 } }], BuyBoxPrices: [{ LandedPrice: { Amount: 1600 } }] },
              Offers: [{ ListingPrice: { Amount: 1500 }, Shipping: { Amount: 0 }, IsBuyBoxWinner: true, SubCondition: 'New' }],
            },
          };
        }
        return {
          payload: {
            Summary: { LowestPrices: [{ LandedPrice: { Amount: 1200 } }], BuyBoxPrices: [] },
            Offers: [
              { ListingPrice: { Amount: 1000 }, Shipping: { Amount: 200 }, IsBuyBoxWinner: false, SubCondition: 'VeryGood' },
            ],
          },
        };
      };

      t.after(() => {
        pricing.getItemOffers = originalGetItemOffers;
        routes.offersCache.clear();
      });

      const req = { query: { asin: 'B00SPAPITEST' }, headers: {} };
      const res = createMockRes();
      const route = routes.match('GET', '/api/offers');
      await route.handler(req, res);

      assert.equal(res.body.source, 'spapi');
      assert.equal(res.body.newCount, 1);
      assert.equal(res.body.usedCount, 1);
      assert.equal(res.body.new[0].condition, 'new');
      assert.equal(res.body.used[0].condition, 'very_good');
      assert.equal(res.body.new[0].breakEven, undefined);
      assert.equal(res.body.used[0].breakEven, undefined);
    }
  );
});

// ---------------------------------------------------------------------------
// GET /api/graph?asin=
// ---------------------------------------------------------------------------

test('/api/graph: KEEPA_API_KEY未設定なら404', async () => {
  await withEnv({ KEEPA_API_KEY: undefined }, async () => {
    const routes = freshRoutes();
    const req = { query: { asin: 'B000TEST' }, headers: PRO };
    const res = createMockRes();
    const route = routes.match('GET', '/api/graph');
    await route.handler(req, res);

    assert.equal(res.statusCode, 404);
    assert.equal(res.body.error, 'keepa_not_configured');
  });
});

test('/api/graph: KEEPA_API_KEY設定時はimage/pngのBufferをres.binaryで返す', async (t) => {
  await withEnv({ KEEPA_API_KEY: 'test-keepa-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');

    const fakeBuffer = Buffer.from([0x89, 0x50, 0x4e, 0x47]);
    keepa.getGraphImage = async (asin) => {
      assert.equal(asin, 'B000TEST');
      return { buffer: fakeBuffer, contentType: 'image/png' };
    };

    const req = { query: { asin: 'B000TEST' }, headers: PRO };
    const res = createMockRes();
    const route = routes.match('GET', '/api/graph');
    await route.handler(req, res);

    assert.equal(res.headers['Content-Type'], 'image/png');
    assert.ok(Buffer.isBuffer(res.binaryBody));
    assert.deepEqual(res.binaryBody, fakeBuffer);

    t.after(() => {
      routes.graphCache.clear();
    });
  });
});

test('/api/graph: asin未指定は400', async () => {
  await withEnv({ KEEPA_API_KEY: 'test-keepa-key' }, async () => {
    const routes = freshRoutes();
    const req = { query: {}, headers: {} };
    const res = createMockRes();
    const route = routes.match('GET', '/api/graph');
    await route.handler(req, res);
    assert.equal(res.statusCode, 400);
  });
});

test('/api/graph: range未指定はKeepaへ90として渡す', async (t) => {
  await withEnv({ KEEPA_API_KEY: 'test-keepa-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');

    const fakeBuffer = Buffer.from([0x89, 0x50, 0x4e, 0x47]);
    let receivedRange;
    keepa.getGraphImage = async (asin, range) => {
      receivedRange = range;
      return { buffer: fakeBuffer, contentType: 'image/png' };
    };

    const req = { query: { asin: 'B000TEST' }, headers: PRO };
    const res = createMockRes();
    const route = routes.match('GET', '/api/graph');
    await route.handler(req, res);

    assert.equal(receivedRange, 90);

    t.after(() => {
      routes.graphCache.clear();
    });
  });
});

test('/api/graph: range=365/1095は許可値としてそのままKeepaへ渡す', async (t) => {
  await withEnv({ KEEPA_API_KEY: 'test-keepa-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');

    const fakeBuffer = Buffer.from([0x89, 0x50, 0x4e, 0x47]);
    const receivedRanges = [];
    keepa.getGraphImage = async (asin, range) => {
      receivedRanges.push(range);
      return { buffer: fakeBuffer, contentType: 'image/png' };
    };

    const route = routes.match('GET', '/api/graph');

    const res365 = createMockRes();
    await route.handler({ query: { asin: 'B000TEST', range: '365' }, headers: PRO }, res365);
    const res1095 = createMockRes();
    await route.handler({ query: { asin: 'B000TEST', range: '1095' }, headers: PRO }, res1095);

    assert.deepEqual(receivedRanges, [365, 1095]);

    t.after(() => {
      routes.graphCache.clear();
    });
  });
});

test('/api/graph: 不正なrange値(例:30,abc,負数)は90として扱う', async (t) => {
  await withEnv({ KEEPA_API_KEY: 'test-keepa-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');

    const fakeBuffer = Buffer.from([0x89, 0x50, 0x4e, 0x47]);
    const receivedRanges = [];
    keepa.getGraphImage = async (asin, range) => {
      receivedRanges.push(range);
      return { buffer: fakeBuffer, contentType: 'image/png' };
    };

    const route = routes.match('GET', '/api/graph');

    // asinを毎回変えてキャッシュヒットを避け、正規化ロジック自体(不正値→90)を検証する。
    for (const invalid of ['30', 'abc', '-1', '9999']) {
      const res = createMockRes();
      await route.handler({ query: { asin: `B000TEST_${invalid}`, range: invalid }, headers: PRO }, res);
    }

    assert.deepEqual(receivedRanges, [90, 90, 90, 90]);

    t.after(() => {
      routes.graphCache.clear();
    });
  });
});

test('/api/graph: キャッシュキーはrangeごとに分離される(range違いは別々にKeepaを呼ぶ)', async (t) => {
  await withEnv({ KEEPA_API_KEY: 'test-keepa-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');

    let callCount = 0;
    keepa.getGraphImage = async (asin, range) => {
      callCount += 1;
      return { buffer: Buffer.from([callCount]), contentType: 'image/png' };
    };

    const route = routes.match('GET', '/api/graph');

    const res90a = createMockRes();
    await route.handler({ query: { asin: 'B000TEST', range: '90' }, headers: PRO }, res90a);
    const res90b = createMockRes();
    await route.handler({ query: { asin: 'B000TEST', range: '90' }, headers: PRO }, res90b);
    const res365 = createMockRes();
    await route.handler({ query: { asin: 'B000TEST', range: '365' }, headers: PRO }, res365);

    // 同じrange(90)への2回目はキャッシュヒットしKeepaを呼ばない → callCountは2のまま(90用に1回、365用に1回)
    assert.equal(callCount, 2);
    assert.deepEqual(res90a.binaryBody, res90b.binaryBody);
    assert.notDeepEqual(res90a.binaryBody, res365.binaryBody);

    t.after(() => {
      routes.graphCache.clear();
    });
  });
});

// ---------------------------------------------------------------------------
// keepa client: extractGraphSeries(グラフ生データ)
// ---------------------------------------------------------------------------

test('keepa client: extractGraphSeries はcsvの交互配列([keepa分,value,...])を[[unixSec,value],...]に変換する', () => {
  const keepa = require('../src/keepa/client');
  const csv = [];
  csv[0] = [5000000, 2500, 5000100, 2600]; // AMAZON
  csv[1] = [5000000, 1500, 5000100, 1600]; // NEW
  csv[2] = [5000000, 1200]; // USED
  csv[3] = [5000000, 3000]; // SALES(rank)
  const product = { csv };

  const series = keepa.extractGraphSeries(product);

  assert.equal(series.amazon.length, 2);
  assert.deepEqual(series.amazon[0], [(5000000 + 21564000) * 60, 2500]);
  assert.deepEqual(series.amazon[1], [(5000100 + 21564000) * 60, 2600]);
  assert.deepEqual(series.new[0], [(5000000 + 21564000) * 60, 1500]);
  assert.deepEqual(series.used[0], [(5000000 + 21564000) * 60, 1200]);
  assert.deepEqual(series.rank[0], [(5000000 + 21564000) * 60, 3000]);
});

test('keepa client: extractGraphSeries は-1(データなし)の値もそのまま保持する', () => {
  const keepa = require('../src/keepa/client');
  const csv = [];
  csv[1] = [5000000, 1500, 5000100, -1]; // NEW: 2点目は在庫切れ等でデータなし
  const product = { csv };

  const series = keepa.extractGraphSeries(product);
  assert.deepEqual(series.new, [
    [(5000000 + 21564000) * 60, 1500],
    [(5000100 + 21564000) * 60, -1],
  ]);
});

test('keepa client: extractGraphSeries はcsvが無い/該当系列が無い場合は空配列を返す', () => {
  const keepa = require('../src/keepa/client');
  assert.deepEqual(keepa.extractGraphSeries(null), { amazon: [], new: [], used: [], rank: [] });
  assert.deepEqual(keepa.extractGraphSeries({}), { amazon: [], new: [], used: [], rank: [] });
  assert.deepEqual(keepa.extractGraphSeries({ csv: [] }), { amazon: [], new: [], used: [], rank: [] });
});

test('keepa client: extractGraphSeries は1001点以上の系列を1000点へ間引き、最初と最後の点は保持する', () => {
  const keepa = require('../src/keepa/client');
  const pointCount = 1001;
  const rawCsv = [];
  for (let i = 0; i < pointCount; i += 1) {
    rawCsv.push(i * 10, 1000 + i); // keepa分は単調増加させる(実データも昇順)
  }
  const csv = [];
  csv[1] = rawCsv; // NEW
  const product = { csv };

  const series = keepa.extractGraphSeries(product);
  assert.equal(series.new.length, 1000);
  // 最初の点(rawCsvの先頭ペア)
  assert.deepEqual(series.new[0], [(0 + 21564000) * 60, 1000]);
  // 最後の点(rawCsvの末尾ペア)
  const lastKeepaTime = (pointCount - 1) * 10;
  assert.deepEqual(series.new[series.new.length - 1], [(lastKeepaTime + 21564000) * 60, 1000 + pointCount - 1]);
});

test('keepa client: extractGraphSeries は1000点以下の系列は間引かない', () => {
  const keepa = require('../src/keepa/client');
  const rawCsv = [];
  for (let i = 0; i < 500; i += 1) {
    rawCsv.push(i * 10, i);
  }
  const csv = [];
  csv[0] = rawCsv;
  const product = { csv };

  const series = keepa.extractGraphSeries(product);
  assert.equal(series.amazon.length, 500);
});

// ---------------------------------------------------------------------------
// GET /api/graph-data?asin= — グラフ生データ(画像でなくJSON)
// ---------------------------------------------------------------------------

test('/api/graph-data: 無料(ヘッダーなし)は403 plan_required', async () => {
  await withEnv({ KEEPA_API_KEY: 'test-keepa-key' }, async () => {
    const routes = freshRoutes();
    const req = { query: { asin: 'B000TEST' }, headers: {} };
    const res = createMockRes();
    const route = routes.match('GET', '/api/graph-data');
    await route.handler(req, res);

    assert.equal(res.statusCode, 403);
    assert.equal(res.body.error, 'plan_required');
  });
});

test('/api/graph-data: asin未指定は400', async () => {
  await withEnv({ KEEPA_API_KEY: 'test-keepa-key' }, async () => {
    const routes = freshRoutes();
    const req = { query: {}, headers: PRO };
    const res = createMockRes();
    const route = routes.match('GET', '/api/graph-data');
    await route.handler(req, res);

    assert.equal(res.statusCode, 400);
  });
});

test('/api/graph-data: KEEPA_API_KEY未設定なら404 keepa_not_configured', async () => {
  await withEnv({ KEEPA_API_KEY: undefined }, async () => {
    const routes = freshRoutes();
    const req = { query: { asin: 'B000TEST' }, headers: PRO };
    const res = createMockRes();
    const route = routes.match('GET', '/api/graph-data');
    await route.handler(req, res);

    assert.equal(res.statusCode, 404);
    assert.equal(res.body.error, 'keepa_not_configured');
  });
});

test('/api/graph-data: 正常応答は{series:{amazon,new,used,rank}}の形で返す', async (t) => {
  await withEnv({ KEEPA_API_KEY: 'test-keepa-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');

    keepa.getProduct = async ({ asin, history }) => {
      assert.equal(asin, 'B000GRAPHDATA');
      assert.equal(history, 1);
      const csv = [];
      csv[1] = [5000000, 1500]; // NEW
      return { product: { asin, csv } };
    };

    const req = { query: { asin: 'B000GRAPHDATA' }, headers: PRO };
    const res = createMockRes();
    const route = routes.match('GET', '/api/graph-data');
    await route.handler(req, res);

    assert.equal(res.statusCode, 200);
    assert.deepEqual(Object.keys(res.body), ['series']);
    assert.deepEqual(Object.keys(res.body.series).sort(), ['amazon', 'new', 'rank', 'used']);
    assert.deepEqual(res.body.series.new, [[(5000000 + 21564000) * 60, 1500]]);

    t.after(() => {
      routes.graphDataCache.clear();
    });
  });
});

test('/api/graph-data: キャッシュ命中時はKeepaを再度呼ばない', async (t) => {
  await withEnv({ KEEPA_API_KEY: 'test-keepa-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');

    let callCount = 0;
    keepa.getProduct = async ({ asin }) => {
      callCount += 1;
      const csv = [];
      csv[1] = [5000000, 1500];
      return { product: { asin, csv } };
    };

    const route = routes.match('GET', '/api/graph-data');
    const req = { query: { asin: 'B000GRAPHCACHE' }, headers: PRO };

    const res1 = createMockRes();
    await route.handler(req, res1);
    const res2 = createMockRes();
    await route.handler(req, res2);

    assert.equal(callCount, 1);
    assert.deepEqual(res1.body, res2.body);

    t.after(() => {
      routes.graphDataCache.clear();
    });
  });
});

test('/api/graph-data: keepa_tokens_exhaustedは503、その他エラーは502で返す', async () => {
  await withEnv({ KEEPA_API_KEY: 'test-keepa-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');

    keepa.getProduct = async () => {
      const err = new Error('keepa_tokens_exhausted');
      err.code = 'keepa_tokens_exhausted';
      throw err;
    };

    const req = { query: { asin: 'B000GRAPHERR1' }, headers: PRO };
    const res = createMockRes();
    const route = routes.match('GET', '/api/graph-data');
    await route.handler(req, res);

    assert.equal(res.statusCode, 503);
    assert.equal(res.body.error, 'keepa_tokens_exhausted');
  });
});

test('/api/graph-data: getProductが想定外エラーを投げたら502 graph_data_failed', async () => {
  await withEnv({ KEEPA_API_KEY: 'test-keepa-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');

    keepa.getProduct = async () => {
      throw new Error('boom');
    };

    const req = { query: { asin: 'B000GRAPHERR2' }, headers: PRO };
    const res = createMockRes();
    const route = routes.match('GET', '/api/graph-data');
    await route.handler(req, res);

    assert.equal(res.statusCode, 502);
    assert.equal(res.body.error, 'graph_data_failed');
  });
});

// ---------------------------------------------------------------------------
// handleSearchViaKeepa: graphDataCacheの先入れ(トークン追加消費ゼロ化)
// ---------------------------------------------------------------------------

test('/api/search(keepa経路): history:1でgetProductを呼び、graphDataCacheへ先入れする(応答自体には含めない)', async (t) => {
  await withEnv(
    {
      LWA_CLIENT_ID: undefined,
      LWA_CLIENT_SECRET: undefined,
      LWA_REFRESH_TOKEN: undefined,
      KEEPA_API_KEY: 'test-keepa-key',
    },
    async () => {
      const routes = freshRoutes();
      const keepa = require('../src/keepa/client');

      let receivedHistory;
      keepa.getProduct = async ({ code, history }) => {
        receivedHistory = history;
        const csv = [];
        csv[1] = [5000000, 1500]; // NEW
        return {
          product: {
            asin: 'B00PREFILL01',
            title: 'グラフ先入れテスト',
            imagesCSV: 'sample.jpg',
            stats: { current: [2000, 1500, 800, 5000, 2200] },
            csv,
          },
        };
      };

      const req = { query: { code: '9784471103644' }, headers: {} };
      const res = createMockRes();
      const route = routes.match('GET', '/api/search');
      await route.handler(req, res);

      assert.equal(receivedHistory, 1);
      // 検索応答自体にはグラフ生データを含めない(契約を変えない)。
      assert.ok(!('series' in res.body));
      assert.ok(!('graph' in res.body));

      // graphDataCacheへ先入れされているため、後続の/api/graph-dataはKeepaを再度呼ばない。
      let graphDataCallCount = 0;
      const originalGetProduct = keepa.getProduct;
      keepa.getProduct = async (params) => {
        graphDataCallCount += 1;
        return originalGetProduct(params);
      };

      const graphReq = { query: { asin: 'B00PREFILL01' }, headers: PRO };
      const graphRes = createMockRes();
      const graphRoute = routes.match('GET', '/api/graph-data');
      await graphRoute.handler(graphReq, graphRes);

      assert.equal(graphDataCallCount, 0); // キャッシュ命中のためKeepaは呼ばれない
      assert.deepEqual(graphRes.body.series.new, [[(5000000 + 21564000) * 60, 1500]]);

      t.after(() => {
        routes.searchCache.clear();
        routes.graphDataCache.clear();
      });
    }
  );
});
