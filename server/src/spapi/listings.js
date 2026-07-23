'use strict';

/**
 * Listings Restrictions API / Listings Items API (2021-08-01) の薄い呼び出し層。
 * ロジック(ゲート・整形)はroutes.js側に置き、ここはSP-API呼び出しのみ担当する。
 */

const { callSpApi, getMarketplaceId } = require('./client');

/**
 * 出品制限を取得する。
 * GET /listings/2021-08-01/restrictions?asin=&sellerId=&marketplaceIds=&conditionType=
 * @param {{asin:string, sellerId:string, conditionType:string, credentials:object}} params
 * @returns {Promise<object>} SP-API生応答({ restrictions: [...] })
 */
async function getListingsRestrictions({ asin, sellerId, conditionType, credentials }) {
  return callSpApi({
    method: 'GET',
    path: '/listings/2021-08-01/restrictions',
    query: {
      asin,
      sellerId,
      marketplaceIds: getMarketplaceId(),
      conditionType,
    },
    credentials,
  });
}

/**
 * オファー出品(既存ASINへの相乗り)。
 * PUT /listings/2021-08-01/items/{sellerId}/{sku}?marketplaceIds=
 * @param {{sellerId:string, sku:string, body:object, credentials:object}} params
 * @returns {Promise<object>} SP-API生応答({ status, submissionId, issues })
 */
async function putListingsItem({ sellerId, sku, body, credentials }) {
  return callSpApi({
    method: 'PUT',
    path: `/listings/2021-08-01/items/${encodeURIComponent(sellerId)}/${encodeURIComponent(sku)}`,
    query: { marketplaceIds: getMarketplaceId() },
    body,
    credentials,
  });
}

module.exports = { getListingsRestrictions, putListingsItem };
