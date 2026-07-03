'use strict';

/**
 * LWA (Login with Amazon) refresh_token -> access_token 取得 + メモリキャッシュ。
 * トークンは55分(3300秒)有効とみなしキャッシュする(実際の有効期限は60分)。
 *
 * 認証情報(clientId/clientSecret/refreshToken)は呼び出し側から引数で受け取れる。
 * 指定が無い場合は .env の LWA_CLIENT_ID / LWA_CLIENT_SECRET / LWA_REFRESH_TOKEN に
 * フォールバックする(後方互換)。
 *
 * アクセストークンのキャッシュは認証情報ごとに分離する。キャッシュキーには
 * トークン本体やシークレットそのものではなく、clientId + refreshToken から
 * 導出したSHA256ハッシュを用いる。
 */

const crypto = require('crypto');

const LWA_TOKEN_URL = 'https://api.amazon.com/auth/o2/token';
const CACHE_TTL_MS = 55 * 60 * 1000; // 55分

// キャッシュキー(認証情報ハッシュ) -> { accessToken, expiresAt }
const tokenCache = new Map();
// キャッシュキー -> Promise<string> (同時リクエストの重複防止)
const inflightRequests = new Map();

/**
 * 引数で渡された認証情報、無ければ .env から解決する。
 * @param {{clientId?:string, clientSecret?:string, refreshToken?:string}} [credentials]
 */
function resolveConfig(credentials) {
  const clientId = (credentials && credentials.clientId) || process.env.LWA_CLIENT_ID;
  const clientSecret = (credentials && credentials.clientSecret) || process.env.LWA_CLIENT_SECRET;
  const refreshToken = (credentials && credentials.refreshToken) || process.env.LWA_REFRESH_TOKEN;
  if (!clientId || !clientSecret || !refreshToken) {
    throw new Error(
      'LWA_CLIENT_ID / LWA_CLIENT_SECRET / LWA_REFRESH_TOKEN が設定されていません'
    );
  }
  return { clientId, clientSecret, refreshToken };
}

/**
 * 認証情報からキャッシュキー(SHA256ハッシュ)を導出する。
 * トークン本体・シークレット自体をキーにせず、ハッシュ化して分離する。
 */
function credentialsCacheKey({ clientId, refreshToken }) {
  return crypto.createHash('sha256').update(`${clientId}:${refreshToken}`).digest('hex');
}

async function fetchNewToken(config) {
  const { clientId, clientSecret, refreshToken } = config;

  const body = new URLSearchParams({
    grant_type: 'refresh_token',
    refresh_token: refreshToken,
    client_id: clientId,
    client_secret: clientSecret,
  });

  const res = await fetch(LWA_TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: body.toString(),
  });

  if (!res.ok) {
    // レスポンスボディにはエラー詳細が含まれる可能性があるが、機密情報を含みうるため
    // ログ・エラーメッセージには含めずステータスコードのみを伝える。
    throw new Error(`LWA token request failed: ${res.status}`);
  }

  const json = await res.json();
  if (!json.access_token) {
    throw new Error('LWA token response missing access_token');
  }
  return json.access_token;
}

/**
 * 有効なaccess_tokenを取得する。キャッシュが有効ならそれを返す。
 * @param {{clientId?:string, clientSecret?:string, refreshToken?:string}} [credentials]
 * @returns {Promise<string>}
 */
async function getAccessToken(credentials) {
  const config = resolveConfig(credentials);
  const cacheKey = credentialsCacheKey(config);

  const now = Date.now();
  const cached = tokenCache.get(cacheKey);
  if (cached && cached.expiresAt > now) {
    return cached.accessToken;
  }

  const inflight = inflightRequests.get(cacheKey);
  if (inflight) {
    return inflight;
  }

  const requestPromise = fetchNewToken(config)
    .then((accessToken) => {
      tokenCache.set(cacheKey, { accessToken, expiresAt: Date.now() + CACHE_TTL_MS });
      inflightRequests.delete(cacheKey);
      return accessToken;
    })
    .catch((err) => {
      inflightRequests.delete(cacheKey);
      throw err;
    });

  inflightRequests.set(cacheKey, requestPromise);
  return requestPromise;
}

/** テスト用: キャッシュを明示的にクリアする */
function _resetCache() {
  tokenCache.clear();
  inflightRequests.clear();
}

module.exports = { getAccessToken, credentialsCacheKey, _resetCache };
