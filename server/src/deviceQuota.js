'use strict';

/**
 * フリーミアムv2「無料枠ユニット」モデルのデバイス単位・日次クォータ。
 *
 * なぜDurable Objects化したか:
 * 旧実装(このモジュールの旧版)はMapによるインメモリ管理だったが、本番検証で
 * 「1回消費した直後に残量を10回問い合わせても10回とも消費0が返る」ことが判明し
 * 全く機能しなかった。Cloudflare Workersはリクエストごとに別isolateへ振られるため、
 * インメモリ状態はisolateをまたいで共有されない。DO(SQLiteバックエンド。無料プランで
 * 利用可能)は同一deviceId宛のリクエストを単一オブジェクトへ直列化するため、
 * 真の意味での状態共有・排他制御が実現できる。
 *
 * 2経路のファサード:
 * - Workers本番: globalThis.__quotaDO(worker.jsがenv.DEVICE_QUOTAを橋渡し)経由でDOへ委譲する。
 *   KVバインディングを globalThis.__adsKv で橋渡ししているroutes.js側の流儀と揃えている。
 * - Node/Render/テスト: DOバインディングが存在しないため、インメモリMapへフォールバックする
 *   (厳密な唯一の真実の情報源ではなくバックストップという位置づけ。
 *   Renderは単一プロセスで動くため、インメモリのままでも実用上は問題ない)。
 *
 * 公開APIは(DO経路がfetchベースの非同期I/Oのため)すべてasync化した。戻り値の形は
 * 旧同期版と同一に保っている(呼び出し側routes.jsの契約を変えないため)。
 *
 * DO障害時の方針(重要):
 * DOへのfetchが失敗した場合は「許可(可用性優先)」で倒す。無料枠ユニットを一時的に
 * 使いすぎられるリスクより、DO障害のたびに正当なユーザーまで「使えない」状態に
 * なる方がユーザー体験上の実害が大きいため。ただしconsole.errorでログは必ず残す。
 *
 * このとき quota は { unknown: true }(残量不明)を返し、絶対に「残量フル」を返さないこと。
 * クライアントはサーバーが返したquotaで自分のローカルカウンタを上書きする設計のため、
 * 障害中に「残り5回」を返し続けると、改ざんしていない正直なクライアントまで
 * カウンタが毎回リセットされ全員が無制限になる。それはこの仕組みが防ごうとしている
 * Keepaトークン枯渇そのものを、障害時に限って自ら引き起こすことになる。
 * クライアントは quota.unknown を見たらローカルの残量を維持し、上書きしない。
 */

const { todayString } = require('./dateUtil');
const quotaMath = require('./quotaMath');

// モジュール読込時に一度だけ評価する。
// テストでenv差し替えを反映させたい場合は require.cache からこのモジュールを削除して再require する。
const BASE_DAILY_UNITS = parseInt(process.env.BASE_DAILY_UNITS, 10) || 5;
const UNITS_PER_AD = parseInt(process.env.UNITS_PER_AD, 10) || 5;
const MAX_DAILY_UNITS = parseInt(process.env.MAX_DAILY_UNITS, 10) || 100;

function limits() {
  return { base: BASE_DAILY_UNITS, perAd: UNITS_PER_AD, max: MAX_DAILY_UNITS };
}

/** deviceId -> { date, unitsUsed, adGrants }(インメモリ経路専用) */
const entries = new Map();

/** メモリ肥大化防止のしきい値。超えたら当日以外のエントリを一括削除する(dateUtil.jsと同じ方式)。 */
const MAX_ENTRIES = 50000;

function pruneIfNeeded(today) {
  if (entries.size > MAX_ENTRIES) {
    for (const [key, value] of entries) {
      if (value.date !== today) entries.delete(key);
    }
  }
}

// ---------------------------------------------------------------------------
// DOバインディングの解決
// ---------------------------------------------------------------------------

/**
 * テスト用: DOバインディングを差し替える。
 * - 何らかのモックbindingを渡すとDO経路を強制する。
 * - undefinedを渡すと通常状態(globalThis.__quotaDOを見る)に戻る。
 * - nullを渡すとインメモリ経路を強制する(globalThis.__quotaDOが設定されていても無視)。
 */
let durableBindingOverride;
function _setDurableBinding(binding) {
  durableBindingOverride = binding;
}

function getDurableBinding() {
  return durableBindingOverride !== undefined ? durableBindingOverride : globalThis.__quotaDO || null;
}

/**
 * DOへfetchし、JSONをパースして返す。
 * URLはダミーオリジン("https://do/...")でよい。DOのfetchはIDで宛先が決まるため
 * URLのホスト部自体は意味を持たない(パスとクエリのみを見る)。
 * @param {*} binding DOバインディング(idFromName/getを持つ)
 * @param {string} deviceId
 * @param {string} path 'consume' | 'grant-ad' | 'peek'
 * @param {string} method
 * @param {object} params クエリパラメータ
 */
async function callDurableObject(binding, deviceId, path, method, params) {
  const id = binding.idFromName(deviceId);
  const stub = binding.get(id);
  const qs = new URLSearchParams(params).toString();
  const res = await stub.fetch(`https://do/${path}?${qs}`, { method });
  const body = await res.json();
  if (!res.ok) {
    const err = new Error(`quota DO ${path} returned status ${res.status}`);
    err.body = body;
    throw err;
  }
  return body;
}

// ---------------------------------------------------------------------------
// インメモリ経路(Node/Render/テスト用)
// ---------------------------------------------------------------------------

function getStateInMemory(deviceId) {
  const today = todayString();
  const entry = entries.get(deviceId);
  if (!entry || entry.date !== today) return { unitsUsed: 0, adGrants: 0 };
  return { unitsUsed: entry.unitsUsed, adGrants: entry.adGrants };
}

function tryConsumeInMemory(deviceId, units) {
  const today = todayString();
  pruneIfNeeded(today);

  const entry = entries.get(deviceId);
  const current = entry && entry.date === today ? entry : { unitsUsed: 0, adGrants: 0 };
  let { unitsUsed, adGrants } = current;

  if (!quotaMath.canConsume(unitsUsed, adGrants, units, limits())) {
    return { allowed: false, quota: quotaMath.buildQuota(unitsUsed, adGrants, limits()) };
  }

  unitsUsed += units;
  entries.set(deviceId, { date: today, unitsUsed, adGrants });
  return { allowed: true, quota: quotaMath.buildQuota(unitsUsed, adGrants, limits()) };
}

function grantAdInMemory(deviceId) {
  const today = todayString();
  pruneIfNeeded(today);

  const entry = entries.get(deviceId);
  const current = entry && entry.date === today ? entry : { unitsUsed: 0, adGrants: 0 };
  const { unitsUsed, adGrants } = current;

  if (!quotaMath.canGrantAd(adGrants, limits())) {
    return { granted: false, quota: quotaMath.buildQuota(unitsUsed, adGrants, limits()) };
  }

  const nextAdGrants = adGrants + 1;
  entries.set(deviceId, { date: today, unitsUsed, adGrants: nextAdGrants });
  return { granted: true, quota: quotaMath.buildQuota(unitsUsed, nextAdGrants, limits()) };
}

// ---------------------------------------------------------------------------
// 公開API(async)
// ---------------------------------------------------------------------------

/**
 * deviceIdの当日分の状態を取得する(未登録・日付が変わっている場合は0/0)。
 * DO障害で状態が分からない場合は null を返す(0/0とは区別する。0/0を返すと
 * 「残量フル」に化けてクライアントのカウンタをリセットしてしまうため)。
 * @param {string|null|undefined} deviceId
 * @returns {Promise<{unitsUsed: number, adGrants: number}|null>}
 */
async function getState(deviceId) {
  if (!deviceId) return { unitsUsed: 0, adGrants: 0 };
  const binding = getDurableBinding();
  if (!binding) return getStateInMemory(deviceId);

  try {
    const quota = await callDurableObject(binding, deviceId, 'peek', 'GET', { date: todayString() });
    return { unitsUsed: quota.unitsUsed, adGrants: quota.adGrantsToday };
  } catch (err) {
    console.error('[deviceQuota] DO peek failed, returning unknown:', err.message);
    return null;
  }
}

/**
 * 現在のクォータ状態を返す(消費・広告付与ともに副作用なし)。
 * deviceIdが空/未指定の場合は無制限扱いを示す { unlimited: true } のみを返す。
 * DO障害で残量が分からない場合は { unknown: true } を返す(クライアントは
 * これを見たらローカルの残量を維持し、上書きしない)。
 * @param {string|null|undefined} deviceId
 */
async function computeQuota(deviceId) {
  if (!deviceId) return { unlimited: true };
  const state = await getState(deviceId);
  if (!state) return { unknown: true };
  return quotaMath.buildQuota(state.unitsUsed, state.adGrants, limits());
}

/**
 * ユニットを消費できるかを判定し、可能なら消費する。
 * deviceIdが空/未指定なら常にallowed=trueで消費しない(deviceIdが取れないクライアントを誤って
 * ブロックしないための安全側)。
 * @param {string|null|undefined} deviceId
 * @param {number} [units=1]
 * @returns {Promise<{allowed: boolean, quota: object}>}
 */
async function tryConsume(deviceId, units = 1) {
  if (!deviceId) return { allowed: true, quota: { unlimited: true } };

  const binding = getDurableBinding();
  if (!binding) return tryConsumeInMemory(deviceId, units);

  try {
    return await callDurableObject(binding, deviceId, 'consume', 'POST', {
      date: todayString(),
      units: String(units),
    });
  } catch (err) {
    // 方針: DOが落ちたら許可(可用性優先)。理由はファイル先頭のコメント参照。
    // quotaは残量不明。ここで「残量フル」を返すとクライアントのカウンタを
    // 毎回リセットしてしまい、障害中は全員が無制限になる。
    console.error('[deviceQuota] DO consume failed, allowing as fallback:', err.message);
    return { allowed: true, quota: { unknown: true } };
  }
}

/**
 * 広告視聴1本分の付与を記録し、日次上限(limit)をUNITS_PER_AD分引き上げる。
 * 既にcap(MAX_DAILY_UNITS)に到達していて、これ以上limitを引き上げられない場合は
 * granted=falseとしadGrantsは増やさない。
 * deviceIdが空/未指定ならgranted=false(広告視聴と紐付ける対象が無いため)。
 * @param {string|null|undefined} deviceId
 * @returns {Promise<{granted: boolean, quota: object}>}
 */
async function grantAd(deviceId) {
  if (!deviceId) return { granted: false, quota: { unlimited: true } };

  const binding = getDurableBinding();
  if (!binding) return grantAdInMemory(deviceId);

  try {
    return await callDurableObject(binding, deviceId, 'grant-ad', 'POST', { date: todayString() });
  } catch (err) {
    // tryConsumeと同じ方針(可用性優先)。広告視聴の対価が失われないようgranted=trueで倒す。
    // ただし付与後の残量は分からないためquotaは残量不明とする。
    console.error('[deviceQuota] DO grant-ad failed, granting as fallback:', err.message);
    return { granted: true, quota: { unknown: true } };
  }
}

/** テスト用: インメモリ経路の全エントリをクリアする。 */
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
  _setDurableBinding,
  BASE_DAILY_UNITS,
  UNITS_PER_AD,
  MAX_DAILY_UNITS,
};
