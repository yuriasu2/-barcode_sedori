'use strict';

/**
 * Sellers API (getMarketplaceParticipations) による sellerId 解決 + インメモリキャッシュ。
 *
 * Listings Restrictions API / Listings Items API は sellerId が必須だが、
 * アプリはBYOリフレッシュトークンしか持たないため、サーバーがSellers APIで解決する。
 * DPP整合のため保存はインメモリキャッシュのみ(キーはリフレッシュトークンのSHA256ハッシュ。
 * トークン本体をキーにも値にも保持しない)。プロセス再起動で消える揮発キャッシュで良い
 * (sellerIdは不変のため再取得コストはSellers API 1回のみ)。
 */

const crypto = require('crypto');

const { callSpApi, getMarketplaceId } = require('./client');
const { LruCache } = require('../cache');

// sellerIdは実質不変のため長め(24時間)にキャッシュする。
const SELLER_ID_TTL_MS = 24 * 60 * 60 * 1000;
const sellerIdCache = new LruCache({ ttlMs: SELLER_ID_TTL_MS, maxSize: 500 });

/**
 * リフレッシュトークンからキャッシュキー(SHA256ハッシュ先頭16文字)を導出する。
 * トークン本体をキャッシュキーに含めないための一方向ハッシュ。
 */
function tokenHashKey(refreshToken) {
  return crypto.createHash('sha256').update(String(refreshToken)).digest('hex').slice(0, 16);
}

/**
 * getMarketplaceParticipations応答からsellerIdを抽出する(純粋関数)。
 * 応答形状の揺れに備え、トップレベル sellerId と participation.sellerId の両方を見る。
 * 対象マーケットプレイスのエントリを優先し、無ければ先頭エントリで代替する。
 * 取れなければnull。
 * @param {object|null} response Sellers APIレスポンス
 * @param {string} marketplaceId
 * @returns {string|null}
 */
function extractSellerId(response, marketplaceId) {
  const payload = (response && response.payload) || [];
  if (!Array.isArray(payload) || !payload.length) return null;
  const entry =
    payload.find((p) => p && p.marketplace && p.marketplace.id === marketplaceId) || payload[0];
  if (!entry) return null;
  const sellerId =
    entry.sellerId || (entry.participation && entry.participation.sellerId) || null;
  return typeof sellerId === 'string' && sellerId ? sellerId : null;
}

/**
 * BYO認証情報からsellerIdを解決する。キャッシュヒット時はSellers APIを呼ばない。
 * @param {{clientId:string, clientSecret:string, refreshToken:string}} credentials
 * @returns {Promise<string>}
 */
async function resolveSellerId(credentials) {
  const key = tokenHashKey(credentials.refreshToken);
  const cached = sellerIdCache.get(key);
  if (cached) return cached;

  const response = await callSpApi({
    method: 'GET',
    path: '/sellers/v1/marketplaceParticipations',
    credentials,
  });

  const sellerId = extractSellerId(response, getMarketplaceId());
  if (!sellerId) {
    const err = new Error('seller_id_not_found: Sellers API応答からsellerIdを取得できませんでした。Sellersロールの追加と再認可を確認してください。');
    err.code = 'seller_id_not_found';
    throw err;
  }

  sellerIdCache.set(key, sellerId);
  return sellerId;
}

/** テスト用: キャッシュをクリアする。 */
function clearCache() {
  sellerIdCache.map.clear();
}

module.exports = { resolveSellerId, extractSellerId, clearCache, tokenHashKey };
