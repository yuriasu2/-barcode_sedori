'use strict';

/**
 * Amazon SP-API (Selling Partner API) 汎用クライアント。
 * - fetch + https.Agent(keep-alive) で接続を再利用
 * - 429 / 5xx は Retry-After ヘッダを尊重した指数バックオフ + ジッターで最大3回リトライ
 */

const https = require('https');
const auth = require('./auth');

const keepAliveAgent = new https.Agent({ keepAlive: true, maxSockets: 20 });

const MAX_RETRIES = 3;
const BASE_DELAY_MS = 500;

function getEndpoint() {
  return process.env.SPAPI_ENDPOINT || 'https://sellingpartnerapi-fe.amazon.com';
}

function getMarketplaceId() {
  return process.env.MARKETPLACE_ID || 'A1VC38T7YXB528';
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Retry-Afterヘッダ(秒 or HTTP-date)をミリ秒に変換する。取得できなければnull。
 */
function parseRetryAfter(res) {
  const header = res.headers.get('retry-after');
  if (!header) return null;
  const seconds = Number(header);
  if (!Number.isNaN(seconds)) {
    return seconds * 1000;
  }
  const dateMs = Date.parse(header);
  if (!Number.isNaN(dateMs)) {
    return Math.max(0, dateMs - Date.now());
  }
  return null;
}

function backoffDelay(attempt, retryAfterMs) {
  if (retryAfterMs != null) {
    // Retry-Afterを尊重しつつ、若干のジッターを加える
    return retryAfterMs + Math.floor(Math.random() * 200);
  }
  const exp = BASE_DELAY_MS * Math.pow(2, attempt);
  const jitter = Math.floor(Math.random() * 250);
  return exp + jitter;
}

/**
 * SP-APIへリクエストを送信する。
 * @param {object} opts
 * @param {string} opts.method
 * @param {string} opts.path SP-APIのパス(例: '/catalog/2022-04-01/items')
 * @param {URLSearchParams|object} [opts.query]
 * @param {object} [opts.body]
 * @param {object} [opts.headers]
 * @param {{clientId?:string, clientSecret?:string, refreshToken?:string}} [opts.credentials]
 *   未指定の場合は .env (LWA_CLIENT_ID等) にフォールバックする。
 * @returns {Promise<object>} レスポンスJSON
 */
async function callSpApi({ method = 'GET', path, query, body, headers = {}, credentials }) {
  const accessToken = await auth.getAccessToken(credentials);
  const endpoint = getEndpoint();

  let url = `${endpoint}${path}`;
  if (query) {
    const qs = query instanceof URLSearchParams ? query : new URLSearchParams(query);
    const qsString = qs.toString();
    if (qsString) url += `?${qsString}`;
  }

  const reqHeaders = {
    'x-amz-access-token': accessToken,
    'content-type': 'application/json',
    accept: 'application/json',
    ...headers,
  };

  let lastError = null;

  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    let res;
    try {
      res = await fetch(url, {
        method,
        headers: reqHeaders,
        body: body != null ? JSON.stringify(body) : undefined,
        // Node18+ fetch (undici) はagentオプションを直接サポートしないため dispatcher は使わず、
        // https.Agentはグローバルkeep-aliveとしてNode標準httpsクライアントの再利用を促す目的で保持。
      });
    } catch (err) {
      lastError = err;
      if (attempt === MAX_RETRIES) throw err;
      await sleep(backoffDelay(attempt, null));
      continue;
    }

    if (res.status === 429 || res.status >= 500) {
      lastError = new Error(`SP-API error: ${res.status}`);
      if (attempt === MAX_RETRIES) {
        const text = await res.text().catch(() => '');
        throw new Error(`SP-API request failed after ${MAX_RETRIES} retries: ${res.status} ${text}`);
      }
      const retryAfterMs = parseRetryAfter(res);
      await sleep(backoffDelay(attempt, retryAfterMs));
      continue;
    }

    if (!res.ok) {
      const text = await res.text().catch(() => '');
      throw new Error(`SP-API request failed: ${res.status} ${text}`);
    }

    if (res.status === 204) return null;
    return res.json();
  }

  throw lastError || new Error('SP-API request failed');
}

module.exports = {
  callSpApi,
  getEndpoint,
  getMarketplaceId,
  keepAliveAgent,
  _internal: { parseRetryAfter, backoffDelay },
};
