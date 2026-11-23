'use strict';

/**
 * Keepa共有キーのトークン残量が少ないときにSlack(Incoming Webhook)へ通知する。
 * 検索を止めないことが最優先なので、あらゆる失敗は握りつぶす(console.warnのみ)。
 * ログにWebhook URL(秘密)は絶対に出さない。
 */

const keepaThrottle = require('./keepaThrottle');

const DEFAULT_THRESHOLD = 60;
// 通知の最小間隔(1時間)。連続して低残量になっても通知を連投しないため。
const ALERT_INTERVAL_MS = 60 * 60 * 1000;

function readThreshold() {
  const n = Number(process.env.KEEPA_ALERT_THRESHOLD);
  return Number.isFinite(n) && n > 0 ? n : DEFAULT_THRESHOLD;
}

function formatJst(date) {
  return new Intl.DateTimeFormat('ja-JP', {
    timeZone: 'Asia/Tokyo',
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false,
  }).format(date);
}

/**
 * tokensLeftがしきい値未満(負数=枯渇も含む)なら、1時間に1回だけSlackへ通知する。
 * 呼び出し側はawaitしなくてよい(絶対にrejectしない)。
 * @param {number} tokensLeft
 * @returns {Promise<boolean>} 実際に送信を試みたか(テスト用)
 */
async function maybeAlertLowTokens(tokensLeft) {
  try {
    const url = process.env.SLACK_WEBHOOK_URL;
    if (!url) return false;
    const threshold = readThreshold();
    if (!Number.isFinite(tokensLeft) || tokensLeft >= threshold) return false;
    // しきい値判定を通ってからゲートを使う(通知しない呼び出しで枠を消費しないため)。
    if (!(await keepaThrottle.alertGate(ALERT_INTERVAL_MS))) return false;
    const text =
      `⚠️ Keepaトークン残量が少なくなっています: 残り ${tokensLeft} トークン(しきい値${threshold})。` +
      `共有キーでの検索が失敗する可能性があります。(${formatJst(new Date())} JST)`;
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text }),
    });
    if (!res.ok) console.warn(`[keepaTokenAlert] Slack webhook returned status ${res.status}`);
    return true;
  } catch (err) {
    console.warn('[keepaTokenAlert] failed (ignored):', err && err.message);
    return false;
  }
}

module.exports = { maybeAlertLowTokens, DEFAULT_THRESHOLD, ALERT_INTERVAL_MS };
