'use strict';

const crypto = require('crypto');

const { MiniRouter } = require('./miniRouter');
const { convertCode, CODE_TYPES } = require('./instore/convert');
const { LruCache } = require('./cache');
const pricing = require('./spapi/pricing');
const spapiAuth = require('./spapi/auth');
const oauth = require('./oauth');
const keepa = require('./keepa/client');

const searchCache = new LruCache();
const offersCache = new LruCache();
const graphCache = new LruCache({ ttlMs: 60 * 60 * 1000, maxSize: 200 }); // グラフ画像: 1時間キャッシュ

const router = new MiniRouter();

const SPAPI_CREDENTIALS_MISSING_MESSAGE = 'SP-API連携またはサーバーのKeepa設定が必要です';

/**
 * リクエストヘッダーからSP-API(LWA)認証情報を解決する。
 * clientId / clientSecret は常にサーバーの .env (LWA_CLIENT_ID / LWA_CLIENT_SECRET) を使用する
 * (ヘッダーは一切見ない。アプリ配布用のOAuthフローに一本化したため)。
 * refreshToken のみ、ヘッダー(X-Spapi-Refresh-Token)を優先し、
 * 無ければ .env (LWA_REFRESH_TOKEN) にフォールバックする(利用者ごとの部分オーバーライド)。
 * いずれか一つでも欠ければnull。
 */
function resolveSpApiCredentials(headers) {
  // アプリ設定でRender側SP-APIをオフにした場合、X-Disable-Spapiヘッダーが送られる。
  // このときは.envのSP-API認証情報も含め一切使わずnullを返し、呼び出し側をKeepaへフォールバックさせる。
  const disableSpApi =
    headers && (headers['x-disable-spapi'] || headers['X-Disable-Spapi']);
  if (disableSpApi) return null;

  const clientId = process.env.LWA_CLIENT_ID || null;
  const clientSecret = process.env.LWA_CLIENT_SECRET || null;
  const refreshToken =
    (headers && (headers['x-spapi-refresh-token'] || headers['X-Spapi-Refresh-Token'])) ||
    process.env.LWA_REFRESH_TOKEN ||
    null;

  if (!clientId || !clientSecret || !refreshToken) return null;
  return { clientId, clientSecret, refreshToken };
}

/**
 * 認証情報から、キャッシュキーに混ぜて使うためのハッシュ(先頭8文字)を生成する。
 * 異なるアカウント間でキャッシュ結果が混ざらないようにする目的であり、
 * 機密情報そのものをキーに含めない。
 */
function credentialsHashPrefix(credentials) {
  if (!credentials) return 'noauth';
  const hash = crypto
    .createHash('sha256')
    .update(`${credentials.clientId}:${credentials.refreshToken}`)
    .digest('hex');
  return hash.slice(0, 8);
}

/**
 * SP-APIのsearchCatalogItemsレスポンスから、検索に使ったidentifierに対応する
 * 最初のアイテム(summaries/images/salesRanks込み)を抽出する。
 */
function pickCatalogItem(catalogResponse) {
  const items = catalogResponse && catalogResponse.items;
  if (!items || !items.length) return null;
  return items[0];
}

function extractCatalogFields(item) {
  if (!item) return { asin: null, title: null, imageUrl: null, salesRank: null };
  const asin = item.asin || null;
  const summary = (item.summaries && item.summaries[0]) || {};
  const title = summary.itemName || null;
  const images = (item.images && item.images[0] && item.images[0].images) || [];
  const imageUrl = images.length ? images[0].link : null;
  const salesRanks = item.salesRanks || [];
  let salesRank = null;
  if (salesRanks.length) {
    const displayRanks = salesRanks[0].displayGroupRanks || salesRanks[0].classificationRanks || [];
    if (displayRanks.length) salesRank = displayRanks[0].rank;
  }
  return { asin, title, imageUrl, salesRank };
}

/**
 * ポイント推定(Amazonポイント表示は取得APIが別途必要なため、価格の一定割合で概算)。
 * DESIGN.mdのレスポンス例に合わせて cart/new/used 各値に対応するポイントを付与する。
 * 実データ取得ができない場合は概算(価格の約2/3程度、例示値ベース)ではなく、
 * 明確化のためnullを許容しつつ簡易推定(price*0.665程度)を行う。
 * 注: SP-APIには直接的な「ポイント」フィールドが無いため、ここでは
 * ポイント制度の一般的な還元率が取得できないケースに備えnullを返す設計とし、
 * 呼び出し側で価格のみ表示できるようにする。
 */
function estimatePoints() {
  return null;
}

async function resolveAsinFromCode(codeType, converted) {
  // isbn/jan は isbn13 または jan を持つのでそれをidentifierとしてCatalog検索
  const identifier = converted.isbn13 || converted.jan;
  if (!identifier) return { identifier: null, asin: null };
  return { identifier, asin: null };
}

/**
 * SP-API経路での/api/search処理(既存ロジック)。source:"spapi"を付与する。
 */
async function handleSearchViaSpApi(req, res, code, credentials, cacheKey) {
  try {
    const converted = convertCode(code);

    if (converted.codeType === CODE_TYPES.UNRESOLVED) {
      const body = {
        codeType: CODE_TYPES.UNRESOLVED,
        asin: null,
        title: null,
        isbn13: null,
        imageUrl: null,
        salesRank: null,
        prices: null,
        reason: converted.reason || 'unresolved',
        source: 'spapi',
      };
      return res.json(body);
    }

    const { identifier, asin: knownAsin } = await resolveAsinFromCode(converted.codeType, converted);

    let asin = knownAsin;
    let title = null;
    let imageUrl = null;
    let salesRank = null;
    let isbn13 = converted.isbn13 || null;

    if (!asin) {
      if (!identifier) {
        return res.json({
          codeType: CODE_TYPES.UNRESOLVED,
          asin: null,
          title: null,
          isbn13: null,
          imageUrl: null,
          salesRank: null,
          prices: null,
          reason: 'no_identifier',
          source: 'spapi',
        });
      }
      const catalogResponse = await pricing.searchCatalogItems(identifier, credentials);
      const item = pickCatalogItem(catalogResponse);
      if (!item) {
        return res.json({
          codeType: CODE_TYPES.UNRESOLVED,
          asin: null,
          title: null,
          isbn13,
          imageUrl: null,
          salesRank: null,
          prices: null,
          reason: 'catalog_not_found',
          source: 'spapi',
        });
      }
      const fields = extractCatalogFields(item);
      asin = fields.asin;
      title = fields.title;
      imageUrl = fields.imageUrl;
      salesRank = fields.salesRank;
    }

    if (!asin) {
      return res.json({
        codeType: converted.codeType,
        asin: null,
        title,
        isbn13,
        imageUrl,
        salesRank,
        prices: null,
        reason: 'asin_not_resolved',
        source: 'spapi',
      });
    }

    const [newOffersResp, usedOffersResp] = await Promise.all([
      pricing.getItemOffers(asin, 'New', credentials).catch(() => null),
      pricing.getItemOffers(asin, 'Used', credentials).catch(() => null),
    ]);

    const newSummary = pricing.extractOffersSummary(newOffersResp);
    const usedSummary = pricing.extractOffersSummary(usedOffersResp);

    const cart = newSummary.buyBoxLandedPrice;
    const newPrice = newSummary.lowestLandedPrice;
    const usedPrice = usedSummary.lowestLandedPrice;

    const responseBody = {
      codeType: converted.codeType,
      asin,
      title,
      isbn13,
      imageUrl,
      salesRank,
      prices: {
        cart: cart != null ? cart : null,
        new: newPrice != null ? newPrice : null,
        used: usedPrice != null ? usedPrice : null,
        points: {
          cart: estimatePoints(cart),
          new: estimatePoints(newPrice),
          used: estimatePoints(usedPrice),
        },
      },
      source: 'spapi',
    };

    searchCache.set(cacheKey, responseBody);
    res.json(responseBody);
  } catch (err) {
    console.error(`[search] code=${code} failed:`, err.message);
    res.status(502).json({ error: 'search_failed', message: err.message });
  }
}

/**
 * Keepa経路での/api/search処理(第1段階・offersなし=1トークン)。source:"keepa"を付与する。
 * SP-API認証情報が無い場合のフォールバック(KEEPA_API_KEYが必要)。
 */
async function handleSearchViaKeepa(req, res, code, cacheKey) {
  try {
    const converted = convertCode(code);

    if (converted.codeType === CODE_TYPES.UNRESOLVED) {
      return res.json({
        codeType: CODE_TYPES.UNRESOLVED,
        asin: null,
        title: null,
        isbn13: null,
        imageUrl: null,
        salesRank: null,
        prices: null,
        reason: converted.reason || 'unresolved',
        source: 'keepa',
      });
    }

    const isbn13 = converted.isbn13 || null;
    const janOrIsbn = converted.isbn13 || converted.jan;

    if (!janOrIsbn) {
      return res.json({
        codeType: CODE_TYPES.UNRESOLVED,
        asin: null,
        title: null,
        isbn13,
        imageUrl: null,
        salesRank: null,
        prices: null,
        reason: 'no_identifier',
        source: 'keepa',
      });
    }

    const { product } = await keepa.getProduct({ code: janOrIsbn });
    const mapped = keepa.mapProductToSearchResult(product);

    if (!mapped) {
      return res.json({
        codeType: converted.codeType,
        asin: null,
        title: null,
        isbn13,
        imageUrl: null,
        salesRank: null,
        prices: null,
        reason: 'catalog_not_found',
        source: 'keepa',
      });
    }

    const responseBody = {
      codeType: converted.codeType,
      asin: mapped.asin,
      title: mapped.title,
      isbn13,
      imageUrl: mapped.imageUrl,
      salesRank: mapped.salesRank,
      prices: mapped.prices,
      source: 'keepa',
    };

    searchCache.set(cacheKey, responseBody);
    res.json(responseBody);
  } catch (err) {
    if (err.code === 'keepa_tokens_exhausted') {
      return res.status(503).json({ error: 'keepa_tokens_exhausted', message: err.message });
    }
    console.error(`[search:keepa] code=${code} failed:`, err.message);
    res.status(502).json({ error: 'search_failed', message: err.message });
  }
}

// GET /api/search?code=
router.get('/api/search', async (req, res) => {
  const code = String(req.query.code || '').trim();
  if (!code) {
    return res.status(400).json({ error: 'code query parameter is required' });
  }

  const credentials = resolveSpApiCredentials(req.headers);

  if (credentials) {
    const cacheKey = `spapi:${credentialsHashPrefix(credentials)}:${code}`;
    const cached = searchCache.get(cacheKey);
    if (cached) return res.json(cached);
    return handleSearchViaSpApi(req, res, code, credentials, cacheKey);
  }

  if (keepa.getApiKey()) {
    const cacheKey = `keepa:${code}`;
    const cached = searchCache.get(cacheKey);
    if (cached) return res.json(cached);
    return handleSearchViaKeepa(req, res, code, cacheKey);
  }

  return res.status(503).json({ error: 'spapi_credentials_missing', message: SPAPI_CREDENTIALS_MISSING_MESSAGE });
});

/**
 * SP-APIのSubCondition文字列を統一契約のcondition文字列に変換する。
 * SP-APIのSubConditionは実運用上ケースの揺れが確認されている
 * (GitHub Issue amzn/selling-partner-api-models#2902: ドキュメント上の表記と実際のレスポンスの大文字/小文字が異なる)ため、
 * 小文字化・区切り除去して緩く一致させる。
 * 値の一覧(MWS/SP-API文書由来): New, Mint, VeryGood/Very Good, Good, Acceptable, Poor, Club, Refurbished, OEM, Warranty, Open Box, Other
 */
function subConditionToString(subCondition) {
  if (!subCondition) return 'acceptable';
  const normalized = String(subCondition).toLowerCase().replace(/[\s_-]/g, '');
  if (normalized === 'new') return 'new';
  if (normalized === 'mint' || normalized === 'likenew') return 'like_new';
  if (normalized === 'verygood') return 'very_good';
  if (normalized === 'good') return 'good';
  if (normalized === 'acceptable') return 'acceptable';
  // poor/club/refurbished/openbox/oem/warranty/other等は契約外のため中古下位(acceptable)にフォールバック
  return 'acceptable';
}

/**
 * spapi経路: getItemOffers結果を /api/offers 統一契約にマッピングする(既存breakEvenロジック維持)。
 */
async function buildOffersResponseViaSpApi(asin, credentials) {
  const [newOffersResp, usedOffersResp] = await Promise.all([
    pricing.getItemOffers(asin, 'New', credentials).catch(() => null),
    pricing.getItemOffers(asin, 'Used', credentials).catch(() => null),
  ]);

  const newSummary = pricing.extractOffersSummary(newOffersResp);
  const usedSummary = pricing.extractOffersSummary(usedOffersResp);

  const allOffers = [
    ...newSummary.offers.map((o) => ({ ...o, _bucket: 'new' })),
    ...usedSummary.offers.map((o) => ({ ...o, _bucket: 'used' })),
  ];

  // 手数料バッチ見積り(各オファー価格ごと)
  let feesResp = null;
  if (allOffers.length) {
    try {
      feesResp = await pricing.getMyFeesEstimatesBatch(
        allOffers.map((o) => ({ asin, price: o.landed, identifier: asin })),
        credentials
      );
    } catch (err) {
      feesResp = null; // フォールバック計算へ
    }
  }

  const feesList = (feesResp && feesResp.payload) || [];

  function feeForIndex(index, landed) {
    const entry = feesList[index];
    const feesEstimate =
      entry &&
      entry.FeesEstimateResult &&
      entry.FeesEstimateResult.FeesEstimate &&
      entry.FeesEstimateResult.FeesEstimate.TotalFeesEstimate;
    if (feesEstimate && typeof feesEstimate.Amount === 'number') {
      return feesEstimate.Amount;
    }
    return pricing.fallbackFees(landed);
  }

  function toOfferDto(o, index) {
    const totalFees = feeForIndex(index, o.landed);
    const breakEven = Math.round((o.landed - totalFees) * 100) / 100;
    return {
      price: o.price,
      shipping: o.shipping,
      landed: o.landed,
      condition: o._bucket === 'new' ? 'new' : subConditionToString(o.condition),
      isBuyBox: o.isBuyBox,
      breakEven,
    };
  }

  const newDtos = [];
  const usedDtos = [];
  allOffers.forEach((o, index) => {
    const dto = toOfferDto(o, index);
    if (o._bucket === 'new') newDtos.push(dto);
    else usedDtos.push(dto);
  });

  return {
    source: 'spapi',
    referencePrice: newSummary.buyBoxLandedPrice || newSummary.lowestLandedPrice || null,
    newCount: newDtos.length,
    usedCount: usedDtos.length,
    new: newDtos,
    used: usedDtos,
  };
}

/**
 * keepa経路: getProduct(offers=20)結果を /api/offers 統一契約にマッピングする。
 * breakEvenはKeepaの手数料情報(referralFeePercent/fbaFees.pickAndPackFee)が取得できればそれを使い、
 * 取得できなければ書籍フォールバック(15%+80円、pricing.fallbackFeesと同じ料率)で近似する。
 */
async function buildOffersResponseViaKeepa(asin) {
  const { product } = await keepa.getProduct({ asin, offers: 20 });
  const { newOffers, usedOffers, referencePrice } = keepa.extractOffersFromProduct(product);

  const referralFeePercent =
    product && typeof product.referralFeePercent === 'number' ? product.referralFeePercent : null;
  const fbaPickAndPackFee =
    product && product.fbaFees && typeof product.fbaFees.pickAndPackFee === 'number'
      ? product.fbaFees.pickAndPackFee
      : null;

  function computeBreakEven(landed) {
    if (referralFeePercent != null && fbaPickAndPackFee != null) {
      const referralFee = landed * (referralFeePercent / 100);
      const closingFee = 80; // 書籍カテゴリの成約料(円)
      return Math.round((landed - referralFee - closingFee - fbaPickAndPackFee) * 100) / 100;
    }
    // 書籍フォールバック: 15%手数料 + 成約料80円(pricing.fallbackFeesと同一料率)
    return Math.round((landed - pricing.fallbackFees(landed)) * 100) / 100;
  }

  function toDto(o) {
    return {
      price: o.price,
      shipping: o.shipping,
      landed: o.landed,
      condition: o.condition,
      isBuyBox: o.isBuyBox,
      breakEven: computeBreakEven(o.landed),
    };
  }

  // 価格(landed)の安い順に並べる(パネル表示を最安値から見せる)。
  const byLandedAsc = (a, b) => (a.landed ?? Infinity) - (b.landed ?? Infinity);
  const newDtos = newOffers.map(toDto).sort(byLandedAsc);
  const usedDtos = usedOffers.map(toDto).sort(byLandedAsc);

  // フォールバック: Keepaが個別オファーを返さない、または鮮度フィルタで全除外された場合でも、
  // stats.current の新品/中古最安値でパネルに価格を表示する(価格が全く出ない事態を防ぐ)。
  const current = (product && product.stats && product.stats.current) || [];
  const statsNew = keepa.normalizePrice(current[keepa.CSV_TYPE.NEW]);
  const statsUsed = keepa.normalizePrice(current[keepa.CSV_TYPE.USED]);
  function statsOffer(price, condition) {
    return {
      price,
      shipping: 0,
      landed: price,
      condition,
      isBuyBox: false,
      breakEven: computeBreakEven(price),
    };
  }
  const finalNew = newDtos.length ? newDtos : statsNew != null ? [statsOffer(statsNew, 'new')] : [];
  const finalUsed = usedDtos.length ? usedDtos : statsUsed != null ? [statsOffer(statsUsed, 'used')] : [];

  return {
    source: 'keepa',
    referencePrice: referencePrice != null ? referencePrice : null,
    newCount: finalNew.length,
    usedCount: finalUsed.length,
    new: finalNew,
    used: finalUsed,
  };
}

// GET /api/offers?asin=&source=spapi|keepa
router.get('/api/offers', async (req, res) => {
  const asin = String(req.query.asin || '').trim();
  if (!asin) {
    return res.status(400).json({ error: 'asin query parameter is required' });
  }

  const source = String(req.query.source || 'spapi').trim().toLowerCase();

  if (source === 'keepa') {
    if (!keepa.getApiKey()) {
      return res.status(503).json({ error: 'spapi_credentials_missing', message: SPAPI_CREDENTIALS_MISSING_MESSAGE });
    }

    const cacheKey = `keepa:${asin}`;
    const cached = offersCache.get(cacheKey);
    if (cached) return res.json(cached);

    try {
      const responseBody = await buildOffersResponseViaKeepa(asin);
      offersCache.set(cacheKey, responseBody);
      res.json(responseBody);
    } catch (err) {
      if (err.code === 'keepa_tokens_exhausted') {
        return res.status(503).json({ error: 'keepa_tokens_exhausted', message: err.message });
      }
      console.error(`[offers:keepa] asin=${asin} failed:`, err.message);
      res.status(502).json({ error: 'offers_failed', message: err.message });
    }
    return;
  }

  // デフォルト: spapi経路
  const credentials = resolveSpApiCredentials(req.headers);
  if (!credentials) {
    return res.status(503).json({ error: 'spapi_credentials_missing', message: SPAPI_CREDENTIALS_MISSING_MESSAGE });
  }

  const cacheKey = `spapi:${credentialsHashPrefix(credentials)}:${asin}`;

  const cached = offersCache.get(cacheKey);
  if (cached) {
    return res.json(cached);
  }

  try {
    const responseBody = await buildOffersResponseViaSpApi(asin, credentials);
    offersCache.set(cacheKey, responseBody);
    res.json(responseBody);
  } catch (err) {
    console.error(`[offers] asin=${asin} failed:`, err.message);
    res.status(502).json({ error: 'offers_failed', message: err.message });
  }
});

// GET /api/graph?asin= — Keepaグラフ画像プロキシ(APIキーをアプリに晒さないため必須)
router.get('/api/graph', async (req, res) => {
  const asin = String(req.query.asin || '').trim();
  if (!asin) {
    return res.status(400).json({ error: 'asin query parameter is required' });
  }

  if (!keepa.getApiKey()) {
    return res.status(404).json({ error: 'keepa_not_configured' });
  }

  const cacheKey = `graph:${asin}`;
  const cached = graphCache.get(cacheKey);
  if (cached) {
    return res.binary(cached.buffer, cached.contentType);
  }

  try {
    const { buffer, contentType } = await keepa.getGraphImage(asin);
    graphCache.set(cacheKey, { buffer, contentType });
    res.binary(buffer, contentType);
  } catch (err) {
    if (err.code === 'keepa_tokens_exhausted') {
      return res.status(503).json({ error: 'keepa_tokens_exhausted', message: err.message });
    }
    console.error(`[graph] asin=${asin} failed:`, err.message);
    res.status(502).json({ error: 'graph_failed', message: err.message });
  }
});

// GET /api/spapi/test
// ヘッダー(なければ.env)の認証情報でLWAトークン取得を1回試行し、疎通確認する。
// SP-API本体(Catalog/Pricing等)は呼ばない。トークン取得成功=連携成功とみなす。
router.get('/api/spapi/test', async (req, res) => {
  const credentials = resolveSpApiCredentials(req.headers);
  if (!credentials) {
    return res.json({ ok: false, message: SPAPI_CREDENTIALS_MISSING_MESSAGE });
  }

  try {
    await spapiAuth.getAccessToken(credentials);
    return res.json({ ok: true });
  } catch (err) {
    return res.json({ ok: false, message: err.message });
  }
});

router.get('/oauth/login', oauth.handleOAuthLogin);
router.get('/oauth/callback', oauth.handleOAuthCallback);

router.searchCache = searchCache;
router.offersCache = offersCache;
router.graphCache = graphCache;

module.exports = router;
