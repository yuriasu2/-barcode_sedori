'use strict';

/**
 * Keepa API (https://api.keepa.com) クライアント。依存ゼロ(標準fetch使用)。
 *
 * 実装前の公式ドキュメント裏取り(2026-07-04時点、WebSearch/web_fetchで確認):
 * - Keepa公式Java SDK (api_backend) のソースコードを一次情報として参照した。
 *   - Product/Stats: https://github.com/keepacom/api_backend/blob/master/src/main/java/com/keepa/api/backend/structs/Stats.java
 *   - Offer:         https://github.com/keepacom/api_backend/blob/master/src/main/java/com/keepa/api/backend/structs/Offer.java
 *   - CsvType (index定義): https://raw.githubusercontent.com/keepacom/api_backend/master/src/main/java/com/keepa/api/backend/structs/Product.java
 *
 * 【domain(ロケール)ID】
 *   1=com, 2=co.uk, 3=de, 4=fr, 5=co.jp, 6=ca, 8=it, 9=es, 10=in, 11=com.mx
 *   → 日本(amazon.co.jp)は仕様どおり domain=5 (Product.javaのDomainId列挙 / 各種フォーラム記載と一致)。
 *
 * 【stats.current 配列のインデックス(Product.CsvType enum, 0始まり)】
 *   0 = AMAZON              Amazon本体の価格
 *   1 = NEW                 3rd party 新品最安値(送料別)
 *   2 = USED                3rd party 中古最安値(送料別)
 *   3 = SALES               売れ筋ランキング(Sales Rank)
 *   4 = LISTPRICE           定価
 *   18 = BUY_BOX_SHIPPING   Buy Box価格(送料込み)。Buy Box不成立時は-1。
 *   ※ CHANGES-v6.mdの記載(0=Amazon,1=新品最安,2=中古最安,3=ランキング,18=BuyBox)と一致することを確認済み。
 *   価格はすべて日本円などその通貨の最小単位の整数。データなしは -1。
 *
 * 【offers配列 / Offer.offerCSV】
 *   各offerの offerCSV は [keepa時刻, price, shipping, keepa時刻, price, shipping, ...] のフラットな履歴配列。
 *   最新の価格・送料は配列の末尾2要素: offerCSV[len-2]=price, offerCSV[len-1]=shipping (公式Javadoc記載どおり)。
 *   price/shippingが-1の場合「不明」、-2の場合「取得不可」。当実装では -1/-2 を「データなし」として扱いnullにする。
 *
 * 【offer.condition (Offer.OfferCondition enum, 公式定義)】
 *   0 = Unknown, 1 = New, 2 = Used-LikeNew, 3 = Used-VeryGood, 4 = Used-Good, 5 = Used-Acceptable,
 *   6 = Refurbished, 7 = Collectible-LikeNew, 8 = Collectible-VeryGood, 9 = Collectible-Good, 10 = Collectible-Acceptable
 *   → CHANGES-v6.mdの記載(1=New,2=Used-LikeNew,3=Used-VeryGood,4=Used-Good,5=Used-Acceptable)と一致。
 *   本実装では 1 を "new" 系、2〜5(および6以降の中古相当)を "used" 系として扱う。
 *
 * 【画像URL】
 *   imagesCSV の先頭ファイル名を `https://images-na.ssl-images-amazon.com/images/I/{name}` に組み立てる
 *   (Keepa公式ドキュメント記載のCDNパターン。Product Objectの `imagesCSV` はカンマ区切りの画像ファイル名リスト)。
 *
 * 【トークン枯渇】
 *   Keepa APIはレスポンスJSONに tokensLeft を含む。tokensLeft < 0 の場合や
 *   HTTP 429 (Too Many Requests) はトークン枯渇として扱い、呼び出し元には
 *   { error: 'keepa_tokens_exhausted' } を投げ、ルート側でHTTP 503にマップする。
 */

const KEEPA_BASE_URL = 'https://api.keepa.com';
const JP_DOMAIN_ID = 5; // amazon.co.jp

// Product.CsvType インデックス(公式Java SDKソースより)
const CSV_TYPE = {
  AMAZON: 0,
  NEW: 1,
  USED: 2,
  SALES: 3,
  LISTPRICE: 4,
  BUY_BOX_SHIPPING: 18,
};

// Offer.OfferCondition インデックス(公式Java SDKソースより)
const OFFER_CONDITION = {
  UNKNOWN: 0,
  NEW: 1,
  USED_LIKE_NEW: 2,
  USED_VERY_GOOD: 3,
  USED_GOOD: 4,
  USED_ACCEPTABLE: 5,
  REFURBISHED: 6,
  COLLECTIBLE_LIKE_NEW: 7,
  COLLECTIBLE_VERY_GOOD: 8,
  COLLECTIBLE_GOOD: 9,
  COLLECTIBLE_ACCEPTABLE: 10,
};

// Offer.condition(int) -> 契約上のcondition文字列 へのマッピング
const CONDITION_STRING_MAP = {
  [OFFER_CONDITION.NEW]: 'new',
  [OFFER_CONDITION.USED_LIKE_NEW]: 'like_new',
  [OFFER_CONDITION.USED_VERY_GOOD]: 'very_good',
  [OFFER_CONDITION.USED_GOOD]: 'good',
  [OFFER_CONDITION.USED_ACCEPTABLE]: 'acceptable',
  // Refurbished/Collectible系は契約に該当文字列が無いため中古(good)寄せのフォールバックとする。
  [OFFER_CONDITION.REFURBISHED]: 'good',
  [OFFER_CONDITION.COLLECTIBLE_LIKE_NEW]: 'like_new',
  [OFFER_CONDITION.COLLECTIBLE_VERY_GOOD]: 'very_good',
  [OFFER_CONDITION.COLLECTIBLE_GOOD]: 'good',
  [OFFER_CONDITION.COLLECTIBLE_ACCEPTABLE]: 'acceptable',
};

// 24時間(Keepa分単位ではなくミリ秒で扱う。lastSeenはKeepa時刻(分, 2010-01-01起点)なので変換して比較する)
const KEEPA_EPOCH_MS = Date.UTC(2010, 0, 1);
const ONE_DAY_MS = 24 * 60 * 60 * 1000;

function keepaMinuteToUnixMs(keepaMinute) {
  return KEEPA_EPOCH_MS + keepaMinute * 60 * 1000;
}

function getApiKey() {
  return process.env.KEEPA_API_KEY || null;
}

/**
 * -1 / -2 (データなし/取得不可)を null に変換する。
 */
function normalizePrice(value) {
  if (typeof value !== 'number' || value < 0) return null;
  return value;
}

/**
 * Keepa APIへGETリクエストを送る共通関数。
 * @param {string} path 例: '/product'
 * @param {object} params クエリパラメータ(keyは自動付与)
 */
async function keepaFetch(path, params) {
  const apiKey = getApiKey();
  if (!apiKey) {
    const err = new Error('keepa_api_key_missing');
    err.code = 'keepa_api_key_missing';
    throw err;
  }

  const query = new URLSearchParams({ key: apiKey, ...params });
  const url = `${KEEPA_BASE_URL}${path}?${query.toString()}`;

  let res;
  try {
    res = await fetch(url);
  } catch (err) {
    const wrapped = new Error(`keepa_request_failed: ${err.message}`);
    wrapped.code = 'keepa_request_failed';
    throw wrapped;
  }

  if (res.status === 429) {
    const err = new Error('keepa_tokens_exhausted');
    err.code = 'keepa_tokens_exhausted';
    throw err;
  }

  if (!res.ok) {
    const text = await res.text().catch(() => '');
    const err = new Error(`keepa_request_failed: ${res.status} ${text}`);
    err.code = 'keepa_request_failed';
    err.status = res.status;
    throw err;
  }

  const json = await res.json();

  if (typeof json.tokensLeft === 'number' && json.tokensLeft < 0) {
    const err = new Error('keepa_tokens_exhausted');
    err.code = 'keepa_tokens_exhausted';
    throw err;
  }

  return json;
}

/**
 * imagesCSV先頭の画像ファイル名からフルURLを組み立てる(旧形式フォールバック)。
 * @param {string|null|undefined} imagesCsv
 */
function buildImageUrl(imagesCsv) {
  if (!imagesCsv || typeof imagesCsv !== 'string') return null;
  const first = imagesCsv.split(',')[0];
  if (!first) return null;
  return `https://images-na.ssl-images-amazon.com/images/I/${first}`;
}

/**
 * Keepa Product から画像URLを解決する。
 * Keepaは旧 `imagesCSV`(カンマ区切りファイル名)を廃止し、構造化された `images` 配列
 * (Image{ l: 大, m: 中 }) へ移行済み。そのため現在の応答では imagesCSV が null になり画像が出ない。
 * 新形式(images[0].l)を優先し、無ければ旧形式(imagesCSV)にフォールバックする。
 * @param {object|null|undefined} product Keepa Product Object
 */
function resolveImageUrl(product) {
  if (!product) return null;
  if (Array.isArray(product.images) && product.images.length) {
    const img = product.images[0] || {};
    const name = img.l || img.m || null;
    if (name && typeof name === 'string') {
      return `https://images-na.ssl-images-amazon.com/images/I/${name}`;
    }
  }
  return buildImageUrl(product.imagesCSV);
}

/**
 * offerCSVの末尾から最新の価格・送料を抽出する。
 * フォーマット: [keepa分, price, shipping, keepa分, price, shipping, ...]
 * 最新は末尾2要素 (offerCSV[len-2]=price, offerCSV[len-1]=shipping)。
 * @param {number[]|null|undefined} offerCsv
 * @returns {{price: number|null, shipping: number|null}}
 */
function extractLatestOfferPrice(offerCsv) {
  if (!Array.isArray(offerCsv) || offerCsv.length < 2) {
    return { price: null, shipping: null };
  }
  const price = normalizePrice(offerCsv[offerCsv.length - 2]);
  const shippingRaw = offerCsv[offerCsv.length - 1];
  // 送料は0(送料無料)を許容しつつ、-1/-2(不明/取得不可)はnullではなく0扱いにはしない。
  const shipping = typeof shippingRaw === 'number' && shippingRaw >= 0 ? shippingRaw : null;
  return { price, shipping };
}

/**
 * offer.lastSeen (Keepa時刻・分) が24時間以内かどうか判定する。
 * @param {number|null|undefined} lastSeen
 */
function isOfferFresh(lastSeen) {
  if (typeof lastSeen !== 'number') return false;
  const seenMs = keepaMinuteToUnixMs(lastSeen);
  return Date.now() - seenMs <= ONE_DAY_MS;
}

/**
 * Offer.condition(int) を契約上のcondition文字列に変換する。
 * @param {number} conditionInt
 * @returns {string} "new"|"like_new"|"very_good"|"good"|"acceptable"
 */
function conditionToString(conditionInt) {
  return CONDITION_STRING_MAP[conditionInt] || 'acceptable';
}

/**
 * conditionIntが新品扱いかどうか。
 * @param {number} conditionInt
 */
function isNewCondition(conditionInt) {
  return conditionInt === OFFER_CONDITION.NEW;
}

/**
 * Keepa product リクエスト。
 * GET /product?key=&domain=5&(code=|asin=)&stats=90&history=0(&offers=20)
 * @param {{code?: string, asin?: string, offers?: number}} params
 */
async function getProduct({ code, asin, offers } = {}) {
  if (!code && !asin) {
    throw new Error('getProduct: code または asin が必要です');
  }

  const query = {
    domain: JP_DOMAIN_ID,
    stats: 90,
    history: 0,
  };
  if (code) query.code = code;
  if (asin) query.asin = asin;
  if (offers) query.offers = offers;

  const json = await keepaFetch('/product', query);
  const products = json && json.products;
  const product = Array.isArray(products) && products.length ? products[0] : null;
  return { product, tokensLeft: json ? json.tokensLeft : undefined };
}

/**
 * getProductの結果を /api/search 契約(第1段階、offersなし)にマッピングする。
 * @param {object} product Keepa Product Object
 */
function mapProductToSearchResult(product) {
  if (!product) return null;

  const current = (product.stats && product.stats.current) || [];
  const salesRank = normalizePrice(current[CSV_TYPE.SALES]);
  const newPrice = normalizePrice(current[CSV_TYPE.NEW]);
  const usedPrice = normalizePrice(current[CSV_TYPE.USED]);

  return {
    asin: product.asin || null,
    title: product.title || null,
    imageUrl: resolveImageUrl(product),
    salesRank,
    prices: {
      cart: null, // BuyBox取得には追加トークンが必要なため第1段階ではnull
      new: newPrice,
      used: usedPrice,
      points: { cart: null, new: null, used: null },
    },
  };
}

/**
 * getProduct(offers指定)の結果から /api/offers 統一契約向けのオファー配列を抽出する。
 * lastSeenが24時間超のオファーは除外する。
 * @param {object} product Keepa Product Object (offers配列を含む)
 */
function extractOffersFromProduct(product) {
  if (!product || !Array.isArray(product.offers)) {
    return { newOffers: [], usedOffers: [], referencePrice: null };
  }

  const current = (product.stats && product.stats.current) || [];
  const buyBoxPrice = normalizePrice(current[CSV_TYPE.BUY_BOX_SHIPPING]);
  const referencePrice = buyBoxPrice != null ? buyBoxPrice : normalizePrice(current[CSV_TYPE.NEW]);

  const newOffers = [];
  const usedOffers = [];

  for (const offer of product.offers) {
    if (!isOfferFresh(offer.lastSeen)) continue;

    const { price, shipping } = extractLatestOfferPrice(offer.offerCSV);
    if (price == null) continue;

    const shippingValue = shipping != null ? shipping : 0;
    const landed = Math.round((price + shippingValue) * 100) / 100;
    const conditionStr = conditionToString(offer.condition);

    const dto = {
      price,
      shipping: shippingValue,
      landed,
      condition: conditionStr,
      isBuyBox: Boolean(buyBoxPrice != null && landed === buyBoxPrice),
    };

    if (isNewCondition(offer.condition)) {
      newOffers.push(dto);
    } else {
      usedOffers.push(dto);
    }
  }

  return { newOffers, usedOffers, referencePrice };
}

/**
 * Keepaグラフ画像を取得する(プロキシ用)。
 * GET /graphimage?key=&domain=5&asin=&salesrank=1&amazon=1&new=1&used=1&range=90&width=1000&height=400
 * @param {string} asin
 * @returns {Promise<{buffer: Buffer, contentType: string}>}
 */
async function getGraphImage(asin) {
  const apiKey = getApiKey();
  if (!apiKey) {
    const err = new Error('keepa_api_key_missing');
    err.code = 'keepa_api_key_missing';
    throw err;
  }

  const query = new URLSearchParams({
    key: apiKey,
    domain: String(JP_DOMAIN_ID),
    asin,
    salesrank: '1',
    amazon: '1',
    new: '1',
    used: '1',
    range: '90',
    width: '1000',
    height: '400',
  });
  const url = `${KEEPA_BASE_URL}/graphimage?${query.toString()}`;

  let res;
  try {
    res = await fetch(url);
  } catch (err) {
    const wrapped = new Error(`keepa_request_failed: ${err.message}`);
    wrapped.code = 'keepa_request_failed';
    throw wrapped;
  }

  if (res.status === 429) {
    const err = new Error('keepa_tokens_exhausted');
    err.code = 'keepa_tokens_exhausted';
    throw err;
  }

  if (!res.ok) {
    const text = await res.text().catch(() => '');
    const err = new Error(`keepa_request_failed: ${res.status} ${text}`);
    err.code = 'keepa_request_failed';
    err.status = res.status;
    throw err;
  }

  const contentType = res.headers.get('content-type') || 'image/png';
  const arrayBuffer = await res.arrayBuffer();
  return { buffer: Buffer.from(arrayBuffer), contentType };
}

module.exports = {
  JP_DOMAIN_ID,
  CSV_TYPE,
  OFFER_CONDITION,
  CONDITION_STRING_MAP,
  getApiKey,
  normalizePrice,
  buildImageUrl,
  resolveImageUrl,
  extractLatestOfferPrice,
  isOfferFresh,
  conditionToString,
  isNewCondition,
  getProduct,
  mapProductToSearchResult,
  extractOffersFromProduct,
  getGraphImage,
  keepaMinuteToUnixMs,
};
