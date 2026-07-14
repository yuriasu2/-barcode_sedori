'use strict';

/**
 * 無料プランのデバイス単位・日次リクエスト数バックストップ(インメモリ)。
 *
 * クライアント側(ScanQuotaStore)の日次100件制限はUserDefaults改ざんで回避され得るため、
 * サーバー側でもデバイスID(iOSのidentifierForVendor)単位で /api/search の回数を数え、
 * 過剰なフリー検索(Keepaトークンの浪費)を防ぐ。
 *
 * - あくまでバックストップ。プランの「100件/日」の厳密適用はクライアント側が担う。
 *   誤ブロックを避けるため、既定上限はクライアントの100より高め(手動検索・リトライを吸収)。
 * - インメモリのためサーバー再起動でカウントはリセットされる(バックストップとして許容)。
 * - 日付はUTC基準(サーバーTZ非依存)。クライアントのローカル日付とは境界がずれ得るが許容。
 */

/** UTC基準の当日を "YYYY-M-D" で返す。 */
function todayString() {
  const d = new Date();
  return `${d.getUTCFullYear()}-${d.getUTCMonth() + 1}-${d.getUTCDate()}`;
}

/** deviceId -> { date, count } */
const counts = new Map();

/** メモリ肥大化防止のしきい値。超えたら当日以外のエントリを一括削除する。 */
const MAX_ENTRIES = 50000;

/**
 * デバイスの当日カウントを1件加算し、上限内かを返す。
 * @param {string|null|undefined} deviceId 端末識別子。空/未指定なら制限しない(後方互換)。
 * @param {number} limit 日次上限
 * @returns {{allowed: boolean, count: number}} allowed=falseなら上限到達(加算はしない)
 */
function registerAndCheck(deviceId, limit) {
  if (!deviceId) return { allowed: true, count: 0 };

  const today = todayString();

  if (counts.size > MAX_ENTRIES) {
    for (const [key, value] of counts) {
      if (value.date !== today) counts.delete(key);
    }
  }

  const entry = counts.get(deviceId);
  let count = entry && entry.date === today ? entry.count : 0;

  if (count >= limit) {
    return { allowed: false, count };
  }

  count += 1;
  counts.set(deviceId, { date: today, count });
  return { allowed: true, count };
}

/** テスト用: 全カウントをクリアする。 */
function _reset() {
  counts.clear();
}

module.exports = {
  todayString,
  registerAndCheck,
  _reset,
  _counts: counts,
};
