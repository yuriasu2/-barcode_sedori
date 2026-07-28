'use strict';

/**
 * Product Pricing API (getItemOffers) / Product Fees API (getMyFeesEstimates) の呼び出しと、
 * オファー整形・損益分岐点(breakEven)算出ロジック。
 */

const { callSpApi, getMarketplaceId } = require('./client');

// カテゴリ既定フォールバック料率(書籍): 販売手数料15% + 成約料80円
const FALLBACK_FEE_RATE = 0.15;
const FALLBACK_CLOSING_FEE = 80;

/**
 * getItemOffers を呼び出す。
 * @param {string} asin
 * @param {'New'|'Used'} condition
 * @param {{clientId?:string, clientSecret?:string, refreshToken?:string}} [credentials]
 *   未指定の場合は .env にフォールバックする。
 */
async function getItemOffers(asin, condition, credentials) {
  const marketplaceId = getMarketplaceId();
  return callSpApi({
    method: 'GET',
    path: `/products/pricing/v0/items/${encodeURIComponent(asin)}/offers`,
    query: {
      MarketplaceId: marketplaceId,
      ItemCondition: condition,
    },
    credentials,
  });
}

/**
 * searchCatalogItems を呼び出す(identifiersでISBN/JAN検索)。
 * @param {string} identifier ISBN-13 または JAN
 * @param {{clientId?:string, clientSecret?:string, refreshToken?:string}} [credentials]
 *   未指定の場合は .env にフォールバックする。
 */
async function searchCatalogItems(identifier, credentials) {
  const marketplaceId = getMarketplaceId();
  return callSpApi({
    method: 'GET',
    path: '/catalog/2022-04-01/items',
    query: {
      marketplaceIds: marketplaceId,
      identifiers: identifier,
      identifiersType: 'EAN',
      includedData: 'summaries,images,salesRanks,attributes',
    },
    credentials,
  });
}

/**
 * getMyFeesEstimates をバッチ呼び出しする。
 * @param {Array<{asin: string, price: number, identifier: string, isAmazonFulfilled?: boolean}>} items
 *   isAmazonFulfilled未指定の項目は従来通りtrue扱い(既存呼び出し元の挙動を変えないため)。
 * @param {{clientId?:string, clientSecret?:string, refreshToken?:string}} [credentials]
 *   未指定の場合は .env にフォールバックする。
 */
async function getMyFeesEstimatesBatch(items, credentials) {
  const marketplaceId = getMarketplaceId();
  const feesEstimateRequests = items.map((item) => ({
    FeesEstimateRequest: {
      MarketplaceId: marketplaceId,
      IsAmazonFulfilled: item.isAmazonFulfilled != null ? item.isAmazonFulfilled : true,
      PriceToEstimateFees: {
        ListingPrice: { CurrencyCode: 'JPY', Amount: item.price },
      },
      Identifier: item.identifier,
    },
    IdType: 'ASIN',
    IdValue: item.asin,
  }));

  // getMyFeesEstimatesのリクエストボディはトップレベルが素の配列
  // (FeesEstimateRequestListで包むとSP-APIが400 "Missing objects [PriceToEstimateFees]" を返す。
  // 本番実機で確認済み)。
  return callSpApi({
    method: 'POST',
    path: '/products/fees/v0/feesEstimate',
    body: feesEstimateRequests,
    credentials,
  });
}

/**
 * フォールバック手数料計算(書籍カテゴリ既定率)。
 * @param {number} landedPrice
 * @returns {number} 手数料合計(円)
 */
function fallbackFees(landedPrice) {
  return Math.round(landedPrice * FALLBACK_FEE_RATE) + FALLBACK_CLOSING_FEE;
}

/**
 * getItemOffersのレスポンスから最安値・BuyBox・オファー一覧を抽出する。
 * SP-APIレスポンス構造の揺れに対して防御的に処理する。
 */
function extractOffersSummary(offersResponse, condition) {
  const payload = offersResponse && offersResponse.payload;
  if (!payload) {
    return { lowestLandedPrice: null, buyBoxLandedPrice: null, offers: [], totalOfferCount: null };
  }

  const summary = payload.Summary || {};
  const lowestPrices = summary.LowestPrices || [];
  const buyBoxPrices = summary.BuyBoxPrices || [];
  // 出品者数。SummaryにTotalOfferCountが無ければ取得済みオファー件数で代替する。
  const totalOfferCount =
    typeof summary.TotalOfferCount === 'number' ? summary.TotalOfferCount : (payload.Offers || []).length;

  const rawOffers = payload.Offers || [];
  const offers = rawOffers.map((o) => {
    // JPYには本来小数円が存在しないが、一部セラーはSP-API上で小数円の価格設定が可能。
    // iOS側Offer型のprice/shipping/landedはInt?のため、ここで整数円に丸めないとJSONDecoderが
    // 小数値のデコードに失敗しアプリ側で「応答の解析に失敗しました」エラーになる。
    const price = Math.round(o.ListingPrice ? o.ListingPrice.Amount : 0);
    const shipping = Math.round(o.Shipping ? o.Shipping.Amount : 0);
    return {
      condition: o.SubCondition || o.ItemCondition || null,
      price,
      shipping,
      landed: price + shipping,
      isBuyBox: Boolean(o.IsBuyBoxWinner),
      sellerId: o.SellerId || null,
    };
  });

  // condition指定時はSummaryを該当条件のみに絞る(Amazonのcondition値は小文字 "new"/"used")。
  // GetItemOffersのSummary.LowestPricesには要求条件と異なる条件が混在することがあり、
  // 絞らないと新品要求時に中古最安を拾ってしまう(condition未指定は従来動作=全体最小)。
  const wanted = condition ? String(condition).toLowerCase() : null;
  const filteredLowest = wanted
    ? lowestPrices.filter((p) => String(p.condition || '').toLowerCase() === wanted)
    : lowestPrices;

  let lowestLandedPrice = filteredLowest.length
    ? Math.min(
        ...filteredLowest.map((p) => (p.LandedPrice ? p.LandedPrice.Amount : Infinity))
      )
    : null;
  // 該当条件がLowestPricesに無い場合は、取得済みオファー(要求条件で取得)の最安landedで代替
  if ((lowestLandedPrice == null || !Number.isFinite(lowestLandedPrice)) && offers.length) {
    lowestLandedPrice = Math.min(...offers.map((o) => o.landed));
  }
  if (!Number.isFinite(lowestLandedPrice)) {
    lowestLandedPrice = null;
  } else {
    // iOS側 SearchPrices.new/used/cart は Int? のため、SP-APIが返しうる小数円をここで整数丸めする
    // (理由はofferのprice/shipping/landedと同様: 丸めないとJSONDecoderが小数値のデコードに失敗する)。
    lowestLandedPrice = Math.round(lowestLandedPrice);
  }

  const filteredBuyBox = wanted
    ? buyBoxPrices.filter((p) => String(p.condition || '').toLowerCase() === wanted)
    : buyBoxPrices;
  const buyBoxEntry = filteredBuyBox[0];
  const buyBoxLandedPrice = buyBoxEntry && buyBoxEntry.LandedPrice
    ? Math.round(buyBoxEntry.LandedPrice.Amount)
    : null;

  return { lowestLandedPrice, buyBoxLandedPrice, offers, totalOfferCount };
}

module.exports = {
  getItemOffers,
  searchCatalogItems,
  getMyFeesEstimatesBatch,
  fallbackFees,
  extractOffersSummary,
  FALLBACK_FEE_RATE,
  FALLBACK_CLOSING_FEE,
};
