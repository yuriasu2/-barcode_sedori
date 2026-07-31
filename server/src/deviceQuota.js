'use strict';

/**
 * フリーミアムv2「無料枠ユニット」モデルのデバイス単位・日次クォータ(インメモリ)。
 *
 * なぜユニット1本化なのか:
 * /api/search のKeepa経路も /api/graph-data も、キャッシュミス時にはどちらも実際に
 * Keepaトークンを1個消費する(検索とグラフで別々の枠を持たせても、サーバー側のコスト
 * =Keepaトークン消費とは対応しない上、「検索は使えるがグラフは使えない」のような
 * わかりにくい状態を生む)。そのため「ユニット」という単一の通貨で、Keepaトークンを
 * 実際に使う操作すべてに共通で課金する。
 *
 * インメモリであることについて:
 * deviceRateLimit.js と同様、この状態は単一Workerアイソレートのメモリにしか存在しない。
 * Cloudflare Workersは需要に応じて複数アイソレートに分散され、また随時再起動されるため、
 * このクォータは全アイソレートで共有される厳密な唯一の真実の情報源ではなく、
 * クライアント側の残量管理(改ざんされ得る)を補助する「バックストップ」として機能する。
 */

const { todayString } = require('./deviceRateLimit');

// これらはモジュール読込時に一度だけ評価する(既存のFREE_DEVICE_DAILY_LIMITと同じ流儀)。
// テストでenv差し替えを反映させたい場合は require.cache からこのモジュールを削除して再require する。
const BASE_DAILY_UNITS = parseInt(process.env.BASE_DAILY_UNITS, 10) || 5;
const UNITS_PER_AD = parseInt(process.env.UNITS_PER_AD, 10) || 5;
const MAX_DAILY_UNITS = parseInt(process.env.MAX_DAILY_UNITS, 10) || 100;

/** deviceId -> { date, unitsUsed, adGrants } */
const entries = new Map();

/** メモリ肥大化防止のしきい値。超えたら当日以外のエントリを一括削除する(deviceRateLimit.jsと同じ方式)。 */
const MAX_ENTRIES = 50000;

function pruneIfNeeded(today) {
  if (entries.size > MAX_ENTRIES) {
    for (const [key, value] of entries) {
      if (value.date !== today) entries.delete(key);
    }
  }
}

/**
 * deviceIdの当日分の状態を取得する(未登録・日付が変わっている場合は0/0)。
 * @param {string|null|undefined} deviceId
 * @returns {{unitsUsed: number, adGrants: number}}
 */
function getState(deviceId) {
  if (!deviceId) return { unitsUsed: 0, adGrants: 0 };
  const today = todayString();
  const entry = entries.get(deviceId);
  if (!entry || entry.date !== today) return { unitsUsed: 0, adGrants: 0 };
  return { unitsUsed: entry.unitsUsed, adGrants: entry.adGrants };
}

/**
 * unitsUsed/adGrantsから、クライアントへ返すquotaオブジェクトを組み立てる。
 * limit = 基本枠 + (広告視聴1本あたりの付与) * adGrants を、上限(MAX_DAILY_UNITS)で頭打ちする。
 */
function buildQuota(unitsUsed, adGrants) {
  const limit = Math.min(BASE_DAILY_UNITS + UNITS_PER_AD * adGrants, MAX_DAILY_UNITS);
  const unitsRemaining = Math.max(0, limit - unitsUsed);
  const baseRemaining = Math.max(0, BASE_DAILY_UNITS - unitsUsed); // OCRゲート用(クライアントが使う)
  const capReached = limit >= MAX_DAILY_UNITS;
  const adAvailable = !capReached;
  return {
    unitsRemaining,
    baseRemaining,
    unitsUsed,
    adGrantsToday: adGrants,
    adAvailable,
    capReached,
    limit,
  };
}

/**
 * 現在のクォータ状態を返す(消費・広告付与ともに副作用なし)。
 * deviceIdが空/未指定の場合は無制限扱いを示す { unlimited: true } のみを返す。
 * @param {string|null|undefined} deviceId
 */
function computeQuota(deviceId) {
  if (!deviceId) return { unlimited: true };
  const { unitsUsed, adGrants } = getState(deviceId);
  return buildQuota(unitsUsed, adGrants);
}

/**
 * ユニットを消費できるかを判定し、可能なら消費する。
 * deviceIdが空/未指定なら常にallowed=trueで消費しない(後方互換。deviceRateLimitと同じ思想)。
 * @param {string|null|undefined} deviceId
 * @param {number} [units=1]
 * @returns {{allowed: boolean, quota: object}}
 */
function tryConsume(deviceId, units = 1) {
  if (!deviceId) return { allowed: true, quota: { unlimited: true } };

  const today = todayString();
  pruneIfNeeded(today);

  const entry = entries.get(deviceId);
  const current = entry && entry.date === today ? entry : { unitsUsed: 0, adGrants: 0 };
  let { unitsUsed, adGrants } = current;

  const limit = Math.min(BASE_DAILY_UNITS + UNITS_PER_AD * adGrants, MAX_DAILY_UNITS);
  if (unitsUsed + units > limit) {
    return { allowed: false, quota: buildQuota(unitsUsed, adGrants) };
  }

  unitsUsed += units;
  entries.set(deviceId, { date: today, unitsUsed, adGrants });
  return { allowed: true, quota: buildQuota(unitsUsed, adGrants) };
}

/**
 * 広告視聴1本分の付与を記録し、日次上限(limit)をUNITS_PER_AD分引き上げる。
 * 既にcap(MAX_DAILY_UNITS)に到達していて、これ以上limitを引き上げられない場合は
 * granted=falseとしadGrantsは増やさない(無意味な広告視聴を防ぐ判断材料としてクライアントが使う)。
 * deviceIdが空/未指定ならgranted=false(広告視聴と紐付ける対象が無いため)。
 * @param {string|null|undefined} deviceId
 * @returns {{granted: boolean, quota: object}}
 */
function grantAd(deviceId) {
  if (!deviceId) return { granted: false, quota: { unlimited: true } };

  const today = todayString();
  pruneIfNeeded(today);

  const entry = entries.get(deviceId);
  const current = entry && entry.date === today ? entry : { unitsUsed: 0, adGrants: 0 };
  const { unitsUsed, adGrants } = current;

  const currentLimit = Math.min(BASE_DAILY_UNITS + UNITS_PER_AD * adGrants, MAX_DAILY_UNITS);
  if (currentLimit >= MAX_DAILY_UNITS) {
    return { granted: false, quota: buildQuota(unitsUsed, adGrants) };
  }

  const nextAdGrants = adGrants + 1;
  entries.set(deviceId, { date: today, unitsUsed, adGrants: nextAdGrants });
  return { granted: true, quota: buildQuota(unitsUsed, nextAdGrants) };
}

/** テスト用: 全エントリをクリアする。 */
function _reset() {
  entries.clear();
}

module.exports = {
  getState,
  computeQuota,
  tryConsume,
  grantAd,
  _reset,
  _entries: entries,
  BASE_DAILY_UNITS,
  UNITS_PER_AD,
  MAX_DAILY_UNITS,
};
