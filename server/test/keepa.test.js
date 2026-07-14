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

      t.after(() => {
        routes.searchCache.clear();
      });
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
    assert.ok(typeof res.body.new[0].breakEven === 'number');
    assert.equal(res.body.used[0].condition, 'good');
    assert.equal(res.body.used[0].landed, 1550);

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
    assert.ok(typeof res.body.new[0].breakEven === 'number');

    t.after(() => {
      routes.offersCache.clear();
    });
  });
});

test('/api/offers: source省略時(spapi既定)は既存のbreakEvenロジックを維持しつつcondition文字列に変換する', async (t) => {
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
      const originalGetFees = pricing.getMyFeesEstimatesBatch;

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
      pricing.getMyFeesEstimatesBatch = async () => null; // フォールバック手数料を使わせる

      t.after(() => {
        pricing.getItemOffers = originalGetItemOffers;
        pricing.getMyFeesEstimatesBatch = originalGetFees;
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
      // フォールバック手数料(15%+80円)でbreakEvenが計算されていること
      const expectedFallbackFee = Math.round(1200 * 0.15) + 80;
      const expectedBreakEven = Math.round((1200 - expectedFallbackFee) * 100) / 100;
      assert.equal(res.body.used[0].breakEven, expectedBreakEven);
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
