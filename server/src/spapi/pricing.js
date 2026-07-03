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
      includedData: 'summaries,images,salesRanks',
    },
    credentials,
  });
}

/**
 * getMyFeesEstimates をバッチ呼び出しする。
 * @param {Array<{asin: string, price: number, identifier: string}>} items
 * @param {{clientId?:string, clientSecret?:string, refreshToken?:string}} [credentials]
 *   未指定の場合は .env にフォールバックする。
 */
async function getMyFeesEstimatesBatch(items, credentials) {
  const marketplaceId = getMarketplaceId();
  const feesEstimateRequests = items.map((item) => ({
    FeesEstimateRequest: {
      MarketplaceId: marketplaceId,
      IsAmazonFulfilled: true,
      PriceToEstimateFees: {
        ListingPrice: { CurrencyCode: 'JPY', Amount: item.price },
      },
      Identifier: item.identifier,
    },
    IdType: 'ASIN',
    IdValue: item.asin,
  }));

  return callSpApi({
    method: 'POST',
    path: '/products/fees/v0/feesEstimate',
    body: { FeesEstimateRequestList: feesEstimateRequests },
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
function extractOffersSummary(offersResponse) {
  const payload = offersResponse && offersResponse.payload;
  if (!payload) {
    return { lowestLandedPrice: null, buyBoxLandedPrice: null, offers: [] };
  }

  const summary = payload.Summary || {};
  const lowestPrices = summary.LowestPrices || [];
  const buyBoxPrices = summary.BuyBoxPrices || [];

  const lowestLandedPrice = lowestPrices.length
    ? Math.min(
        ...lowestPrices.map((p) => (p.LandedPrice ? p.LandedPrice.Amount : Infinity))
      )
    : null;

  const buyBoxEntry = buyBoxPrices[0];
  const buyBoxLandedPrice = buyBoxEntry && buyBoxEntry.LandedPrice
    ? buyBoxEntry.LandedPrice.Amount
    : null;

  const rawOffers = payload.Offers || [];
  const offers = rawOffers.map((o) => {
    const price = o.ListingPrice ? o.ListingPrice.Amount : 0;
    const shipping = o.Shipping ? o.Shipping.Amount : 0;
    return {
      condition: o.SubCondition || o.ItemCondition || null,
      price,
      shipping,
      landed: Math.round((price + shipping) * 100) / 100,
      isBuyBox: Boolean(o.IsBuyBoxWinner),
      sellerId: o.SellerId || null,
    };
  });

  return { lowestLandedPrice, buyBoxLandedPrice, offers };
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
