'use strict';

/**
 * SP-API (Amazon Selling Partner API) OAuth認可フロー。
 *
 * GET /oauth/login    : Seller Centralの認可画面へリダイレクトする(state発行)。
 * GET /oauth/callback : Amazon側から spapi_oauth_code / state / selling_partner_id を受け取り、
 *                       LWAトークンエンドポイントでrefresh_tokenを取得し、
 *                       iOSアプリへディープリンク(barcodesedori://spapi-auth)で引き渡す。
 *
 * refresh_tokenは将来Supabase等のDBに永続化する設計とし、現時点ではメモリにも保持せず、
 * レスポンスHTML生成後は変数参照が失われて破棄される(ファイル・DB・ログいずれにも書き込まない)。
 */

const crypto = require('crypto');

const LWA_TOKEN_URL = 'https://api.amazon.com/auth/o2/token';

const STATE_TTL_MS = 10 * 60 * 1000; // 10分
const STATE_MAX_ENTRIES = 100;

// state文字列 -> { createdAt }
const stateStore = new Map();

/**
 * 期限切れのstateをクリーンアップする。
 */
function cleanupExpiredStates(now = Date.now()) {
  for (const [state, entry] of stateStore.entries()) {
    if (now - entry.createdAt > STATE_TTL_MS) {
      stateStore.delete(state);
    }
  }
}

/**
 * 新しいstateを生成し、ストアに保存して返す。
 */
function _createState() {
  cleanupExpiredStates();

  // 上限を超える場合、最も古いものから削除する(Mapは挿入順を保持する)
  while (stateStore.size >= STATE_MAX_ENTRIES) {
    const oldestKey = stateStore.keys().next().value;
    if (oldestKey === undefined) break;
    stateStore.delete(oldestKey);
  }

  const state = crypto.randomBytes(16).toString('hex');
  stateStore.set(state, { createdAt: Date.now() });
  return state;
}

/**
 * stateを検証し、有効であれば消費(削除)してtrueを返す。
 * 存在しない・期限切れの場合はfalseを返す(存在すれば削除はする)。
 */
function _verifyAndConsumeState(state) {
  if (!state) return false;
  const entry = stateStore.get(state);
  if (!entry) return false;
  stateStore.delete(state);
  if (Date.now() - entry.createdAt > STATE_TTL_MS) {
    return false;
  }
  return true;
}

/** テスト用: 現在保持しているstate件数 */
function _stateCount() {
  return stateStore.size;
}

/** テスト用: 期限切れとして扱うため、createdAtを過去に書き換える */
function _expireStateForTest(state) {
  const entry = stateStore.get(state);
  if (entry) {
    entry.createdAt = Date.now() - STATE_TTL_MS - 1000;
  }
}

function escapeHtml(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function renderErrorHtml(title, message) {
  return `<!DOCTYPE html>
<html lang="ja">
<head><meta charset="utf-8"><title>${escapeHtml(title)}</title></head>
<body>
  <h1>${escapeHtml(title)}</h1>
  <p>${escapeHtml(message)}</p>
</body>
</html>`;
}

/**
 * GET /oauth/login
 * Seller Centralの認可画面(consent)へリダイレクトする。
 */
function handleOAuthLogin(req, res) {
  cleanupExpiredStates();

  const spapiAppId = process.env.SPAPI_APP_ID;
  if (!spapiAppId) {
    return res
      .status(500)
      .html(
        renderErrorHtml(
          '設定エラー',
          'SPAPI_APP_IDが設定されていません。サーバーの.envにSPAPI_APP_ID(Seller Centralのアプリ管理に表示されるapplication_id)を設定してください。'
        )
      );
  }

  const sellerCentralUrl = process.env.SELLER_CENTRAL_URL || 'https://sellercentral.amazon.co.jp';
  const state = _createState();

  const redirectUrl = `${sellerCentralUrl}/apps/authorize/consent?application_id=${encodeURIComponent(
    spapiAppId
  )}&state=${state}&version=beta`;

  return res.redirect(redirectUrl);
}

/**
 * GET /oauth/callback
 * Amazonからのリダイレクトを受け取り、LWAトークン交換を行う。
 */
async function handleOAuthCallback(req, res) {
  const query = req.query || {};
  const state = query.state;
  const spapiOauthCode = query.spapi_oauth_code;
  const sellingPartnerId = query.selling_partner_id;

  if (!_verifyAndConsumeState(state)) {
    return res
      .status(403)
      .html(renderErrorHtml('認証エラー', '認証セッションが無効です。もう一度お試しください。'));
  }

  if (!spapiOauthCode) {
    return res
      .status(400)
      .html(renderErrorHtml('認証エラー', '認可コードが取得できませんでした。もう一度お試しください。'));
  }

  const clientId = process.env.LWA_CLIENT_ID;
  const clientSecret = process.env.LWA_CLIENT_SECRET;

  if (!clientId || !clientSecret) {
    return res
      .status(500)
      .html(
        renderErrorHtml(
          '設定エラー',
          'サーバーにLWA_CLIENT_ID / LWA_CLIENT_SECRETが設定されていません。'
        )
      );
  }

  const body = new URLSearchParams({
    grant_type: 'authorization_code',
    code: spapiOauthCode,
    client_id: clientId,
    client_secret: clientSecret,
  });

  let tokenJson;
  try {
    const tokenRes = await fetch(LWA_TOKEN_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body.toString(),
    });

    if (!tokenRes.ok) {
      // 機密情報を含まない範囲(ステータスコードのみ)でログ・レスポンスに含める
      console.error(`[oauth] LWA token exchange failed: status=${tokenRes.status}`);
      return res
        .status(502)
        .html(
          renderErrorHtml(
            '認証エラー',
            `Amazonとのトークン交換に失敗しました(status: ${tokenRes.status})。もう一度お試しください。`
          )
        );
    }

    tokenJson = await tokenRes.json();
  } catch (err) {
    console.error('[oauth] LWA token exchange request error:', err.message);
    return res
      .status(502)
      .html(renderErrorHtml('認証エラー', 'Amazonとの通信中にエラーが発生しました。もう一度お試しください。'));
  }

  if (!tokenJson || !tokenJson.access_token || !tokenJson.refresh_token) {
    console.error('[oauth] LWA token response missing access_token/refresh_token');
    return res
      .status(502)
      .html(
        renderErrorHtml(
          '認証エラー',
          'Amazonからのトークン応答が不正です。もう一度お試しください。'
        )
      );
  }

  // refreshTokenはローカル変数にのみ保持し、レスポンスHTML生成後は参照を持たない
  // (ファイル・DB・ログいずれにも書き込まない。将来的にSupabase等へ永続化する設計とする)。
  const refreshToken = tokenJson.refresh_token;

  const deepLinkUrl = `barcodesedori://spapi-auth?refresh_token=${encodeURIComponent(
    refreshToken
  )}&selling_partner_id=${encodeURIComponent(sellingPartnerId || '')}`;

  const html = `<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="utf-8">
  <meta http-equiv="refresh" content="0;url=${escapeHtml(deepLinkUrl)}">
  <title>SP-API認証完了</title>
</head>
<body>
  <h1>SP-API認証が完了しました</h1>
  <p>アプリに自動で戻ります。戻らない場合は下のリンクをタップしてください。</p>
  <p><a href="${escapeHtml(deepLinkUrl)}">アプリに戻る</a></p>
  <p>自動で戻らない場合は、以下の値をコピーしてアプリの設定画面(詳細設定)に貼り付けてください。</p>
  <textarea readonly rows="4" style="width:100%;" onclick="this.select()">${escapeHtml(
    refreshToken
  )}</textarea>
  <script>
    location.href = ${JSON.stringify(deepLinkUrl)};
  </script>
</body>
</html>`;

  return res.status(200).html(html);
}

module.exports = {
  handleOAuthLogin,
  handleOAuthCallback,
  _createState,
  _verifyAndConsumeState,
  _stateCount,
  _expireStateForTest,
  _stateStoreForTest: stateStore,
};
