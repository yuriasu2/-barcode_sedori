'use strict';

const crypto = require('crypto');

const { MiniRouter } = require('./miniRouter');
const { convertCode, CODE_TYPES } = require('./instore/convert');
const { LruCache } = require('./cache');
const pricing = require('./spapi/pricing');
const spapiAuth = require('./spapi/auth');
const oauth = require('./oauth');

const searchCache = new LruCache();
const offersCache = new LruCache();

const router = new MiniRouter();

const SPAPI_CREDENTIALS_MISSING_MESSAGE = 'SP-API認証情報が設定されていません';

/**
 * リクエストヘッダーからSP-API(LWA)認証情報を解決する。
 * clientId / clientSecret は常にサーバーの .env (LWA_CLIENT_ID / LWA_CLIENT_SECRET) を使用する
 * (ヘッダーは一切見ない。アプリ配布用のOAuthフローに一本化したため)。
 * refreshToken のみ、ヘッダー(X-Spapi-Refresh-Token)を優先し、
 * 無ければ .env (LWA_REFRESH_TOKEN) にフォールバックする(利用者ごとの部分オーバーライド)。
 * いずれか一つでも欠ければnull。
 */
function resolveSpApiCredentials(headers) {
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

// GET /api/search?code=
router.get('/api/search', async (req, res) => {
  const code = String(req.query.code || '').trim();
  if (!code) {
    return res.status(400).json({ error: 'code query parameter is required' });
  }

  const credentials = resolveSpApiCredentials(req.headers);
  if (!credentials) {
    return res.status(503).json({ error: 'spapi_credentials_missing', message: SPAPI_CREDENTIALS_MISSING_MESSAGE });
  }

  const cacheKey = `${credentialsHashPrefix(credentials)}:${code}`;

  const cached = searchCache.get(cacheKey);
  if (cached) {
    return res.json(cached);
  }

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
    };

    searchCache.set(cacheKey, responseBody);
    res.json(responseBody);
  } catch (err) {
    console.error(`[search] code=${code} failed:`, err.message);
    res.status(502).json({ error: 'search_failed', message: err.message });
  }
});

// GET /api/offers?asin=
router.get('/api/offers', async (req, res) => {
  const asin = String(req.query.asin || '').trim();
  if (!asin) {
    return res.status(400).json({ error: 'asin query parameter is required' });
  }

  const credentials = resolveSpApiCredentials(req.headers);
  if (!credentials) {
    return res.status(503).json({ error: 'spapi_credentials_missing', message: SPAPI_CREDENTIALS_MISSING_MESSAGE });
  }

  const cacheKey = `${credentialsHashPrefix(credentials)}:${asin}`;

  const cached = offersCache.get(cacheKey);
  if (cached) {
    return res.json(cached);
  }

  try {
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
      const sameCount = allOffers.filter(
        (x) => x._bucket === o._bucket && x.landed === o.landed
      ).length;
      const dto = {
        price: o.price,
        shipping: o.shipping,
        landed: o.landed,
        isBuyBox: o.isBuyBox,
        sameCount,
        breakEven,
      };
      if (o._bucket === 'used') {
        dto.condition = o.condition;
      }
      return dto;
    }

    const newDtos = [];
    const usedDtos = [];
    allOffers.forEach((o, index) => {
      const dto = toOfferDto(o, index);
      if (o._bucket === 'new') newDtos.push(dto);
      else usedDtos.push(dto);
    });

    const responseBody = {
      referencePrice: newSummary.buyBoxLandedPrice || newSummary.lowestLandedPrice || null,
      releaseDate: null,
      new: newDtos,
      used: usedDtos,
    };

    offersCache.set(cacheKey, responseBody);
    res.json(responseBody);
  } catch (err) {
    console.error(`[offers] asin=${asin} failed:`, err.message);
    res.status(502).json({ error: 'offers_failed', message: err.message });
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

module.exports = router;
