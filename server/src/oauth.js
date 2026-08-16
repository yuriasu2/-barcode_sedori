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
 *
 * stateの持ち方について(重要):
 * かつてはstate文字列をモジュールスコープのMap(インメモリ)へ保存していたが、
 * Cloudflare Workersは /oauth/login と /oauth/callback を別isolateへ振り分け得るため、
 * コールバック側のisolateにログイン側で保存したstateが存在せず「認証セッションが無効です」
 * で連携が失敗する不具合が本番で確認された。同じ問題は過去にdeviceQuota(旧実装)でも
 * 発生しており(quotaDurableObject.js冒頭コメント参照)、そのときはDurable Objectで
 * 状態を一箇所に集約して解決した。しかしstateはユーザーがAmazonの承認画面に滞在する間
 * (数十秒〜数分)保持できればよく、サーバー側の永続状態は本質的に不要なので、
 * ここではDOを増やすのではなく「サーバー側に状態を持たない自己完結トークン」にする方式を採る。
 *
 * 新方式: state = `<issuedAtMs>.<nonce>.<hmacHex>`
 * - issuedAtMs: 発行時刻(ミリ秒)
 * - nonce: ランダム値(推測不能性の担保。署名対象に含めることで改ざん検知にも使う)
 * - hmacHex: `${issuedAtMs}.${nonce}` に対するHMAC-SHA256署名(hex)
 * 検証は「署名が正しいこと」+「発行からSTATE_TTL_MS以内であること」の2点のみ。
 * どちらもサーバー側の状態(Map/DO/DB)を一切参照せずに判定できるため、
 * /oauth/login と /oauth/callback が別isolateであっても問題なく検証できる。
 * 一方でこの方式は原理上「一度きりの使い捨て」を保証できない(署名とTTLが有効な間は
 * 同じstateを何度でも検証に通せる)。これはAmazon側が同一state・同一認可コードを
 * 使った再送を許さない(認可コードは一度きりで無効化される)ため実害は無いと判断している。
 *
 * 署名鍵はOAUTH_STATE_SECRET(既存のWorker secretとは別の専用環境変数)を使う。
 * 未設定時は署名できないため、黙って署名なしで通す(=誰でも偽造stateを作れてしまう)ことは
 * 絶対に避け、/oauth/login 自体を503で拒否する(フェイルセーフ優先)。
 *
 * 実行環境について(Node版 src/index.js と Workers版 src/worker.js の両方で動く):
 * HMAC署名にはNode専用の crypto.createHmac ではなく、Node 18+・Cloudflare Workersの
 * 両方でグローバルに使える crypto.subtle (WebCrypto) を使う(admobSsv.jsの
 * getSubtle()と同じ流儀)。乱数生成(nonce)は元々のstate生成と同じくNodeの
 * crypto.randomBytes を使う(worker.js側でnodejs_compatが有効なため、Workers上でも
 * 既存コードとして動作実績がある)。
 */

const crypto = require('crypto');

const LWA_TOKEN_URL = 'https://api.amazon.com/auth/o2/token';

const STATE_TTL_MS = 10 * 60 * 1000; // 10分

/** globalThis.crypto.subtle優先、無ければNodeのwebcryptoへフォールバックする(admobSsv.jsと同じ)。 */
function getSubtle() {
  if (globalThis.crypto && globalThis.crypto.subtle) return globalThis.crypto.subtle;
  // eslint-disable-next-line global-require
  return require('crypto').webcrypto.subtle;
}

/** HMAC-SHA256用の鍵をインポートする。secretはOAUTH_STATE_SECRETの生文字列。 */
async function importHmacKey(secret) {
  const subtle = getSubtle();
  return subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign', 'verify']
  );
}

function bytesToHex(buf) {
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

/** hex文字列をUint8Arrayへ変換する。長さが奇数・非hex文字を含む場合はnullを返す。 */
function hexToBytes(hex) {
  if (typeof hex !== 'string' || hex.length === 0 || hex.length % 2 !== 0) return null;
  if (!/^[0-9a-fA-F]+$/.test(hex)) return null;
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i += 1) {
    bytes[i] = parseInt(hex.substr(i * 2, 2), 16);
  }
  return bytes;
}

/**
 * 新しいstateを生成する。OAUTH_STATE_SECRET未設定時はnullを返す
 * (呼び出し側=handleOAuthLoginがフェイルセーフに倒して503にする)。
 * @param {number} [nowOverride] テスト用: 発行時刻を固定したいときに渡す。
 */
async function _createState(nowOverride) {
  const secret = process.env.OAUTH_STATE_SECRET;
  if (!secret) return null;

  const issuedAtMs = nowOverride !== undefined ? nowOverride : Date.now();
  const nonce = crypto.randomBytes(16).toString('hex');
  const key = await importHmacKey(secret);
  const signature = await getSubtle().sign(
    'HMAC',
    key,
    new TextEncoder().encode(`${issuedAtMs}.${nonce}`)
  );
  return `${issuedAtMs}.${nonce}.${bytesToHex(signature)}`;
}

/**
 * stateを検証する。署名が正しく、かつ発行からSTATE_TTL_MS以内であればtrueを返す。
 * サーバー側の状態を一切参照しない(自己完結トークンのため「消費」の概念は無い。
 * 関数名は呼び出し側=handleOAuthCallbackとの互換のため_verifyAndConsumeStateのまま残す)。
 * OAUTH_STATE_SECRET未設定時は検証しようがないためfalseを返す。
 */
async function _verifyAndConsumeState(state) {
  if (!state || typeof state !== 'string') return false;
  const secret = process.env.OAUTH_STATE_SECRET;
  if (!secret) return false;

  const parts = state.split('.');
  if (parts.length !== 3) return false;
  const [issuedAtStr, nonce, signatureHex] = parts;
  if (!issuedAtStr || !nonce || !signatureHex) return false;

  const issuedAtMs = Number(issuedAtStr);
  if (!Number.isFinite(issuedAtMs)) return false;

  const signatureBytes = hexToBytes(signatureHex);
  if (!signatureBytes) return false;

  const key = await importHmacKey(secret);
  const valid = await getSubtle().verify(
    'HMAC',
    key,
    signatureBytes,
    new TextEncoder().encode(`${issuedAtStr}.${nonce}`)
  );
  if (!valid) return false;

  if (Date.now() - issuedAtMs > STATE_TTL_MS) return false;

  return true;
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
async function handleOAuthLogin(req, res) {
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

  const state = await _createState();
  if (state === null) {
    // OAUTH_STATE_SECRET未設定。署名鍵が無いとstateの真正性を検証できないため、
    // 黙って署名なしのstateで通す(=第三者が偽造したstateでコールバックを騙せてしまう)
    // よりも、フェイルセーフに倒してログイン自体を503で拒否する。
    return res
      .status(503)
      .html(
        renderErrorHtml(
          '設定エラー',
          'サーバー設定が未完了です。しばらくしてから再度お試しください。'
        )
      );
  }

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

  if (!(await _verifyAndConsumeState(state))) {
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
  STATE_TTL_MS,
};
