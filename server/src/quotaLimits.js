'use strict';

/**
 * 無料枠ユニットモデルの3設定(base / perAd / max)の解決。
 *
 * なぜKVから読むのか:
 * この3値はもともとWorkerの環境変数(wrangler.jsonc の vars)だったため、
 * 「無料枠を1日3回に絞る」「広告1本で10回にする」といった調整のたびにデプロイが
 * 必要だった。広告配信設定(ads)・障害告知(notice)と同じく、既存の ADS_CONFIG
 * KV namespace に別キー(quota-limits)で同居させることで、デプロイなしで
 * 調整できるようにする。
 *
 * KVに格納するJSONの形:
 * {
 *   "baseDailyUnits": 5,
 *   "unitsPerAd": 5,
 *   "maxDailyUnits": 100
 * }
 *
 * フェイルセーフ設計(loadNotice()と同じ流儀):
 * KV未設定・キー無し・JSON破損・型不正はすべて環境変数(さらにその既定値)へ
 * フォールバックする。無料枠は「使えなくなる」より「少し多く使える」方が実害が
 * 小さいが、いずれにせよ設定ミスで無料枠が壊れることは避けたいため、
 * 疑わしい入力は一切採用しない。
 */

const { LruCache } = require('./cache');

// 環境変数すら無い場合の最終フォールバック。wrangler.jsonc の vars と同じ値。
const DEFAULT_BASE_DAILY_UNITS = 5;
const DEFAULT_UNITS_PER_AD = 5;
const DEFAULT_MAX_DAILY_UNITS = 100;

const QUOTA_LIMITS_KV_KEY = 'quota-limits';
const QUOTA_LIMITS_CACHE_KEY = 'quota_limits';

// 60秒キャッシュ(KV読み取り抑制。KV書き換え後、最大60秒は古い設定が使われ得る
// =ads設定・noticeと同じ挙動)。
const quotaLimitsCache = new LruCache({ ttlMs: 60 * 1000, maxSize: 1 });

// 妥当性チェックの範囲。運用上あり得ない値(桁の打ち間違い等)を弾くための上限。
const BASE_DAILY_UNITS_MAX = 1000;
const UNITS_PER_AD_MAX = 1000;
const MAX_DAILY_UNITS_MAX = 10000;

/**
 * 環境変数(process.env)から3値を組み立てる。未設定・不正値は既定値へ倒す。
 * Workers経路では worker.js が env の文字列値を process.env へコピー済み。
 * @returns {{base: number, perAd: number, max: number}}
 */
function envLimits() {
  const base = parseInt(process.env.BASE_DAILY_UNITS, 10);
  const perAd = parseInt(process.env.UNITS_PER_AD, 10);
  const max = parseInt(process.env.MAX_DAILY_UNITS, 10);
  return {
    // base のみ「0」を有効値として許容する(広告なしでは使えない設定)。
    // || では0が既定値5に化けるため Number.isFinite で判定する。
    base: Number.isFinite(base) && base >= 0 ? base : DEFAULT_BASE_DAILY_UNITS,
    perAd: perAd || DEFAULT_UNITS_PER_AD,
    max: max || DEFAULT_MAX_DAILY_UNITS,
  };
}

/** 正の整数(または0以上の整数)であることの判定。文字列・小数・NaN・Infinityはすべて不正。 */
function isInteger(value) {
  return typeof value === 'number' && Number.isInteger(value);
}

/**
 * KVから読んだ生オブジェクトを検証し、limits({base, perAd, max})へ絞り込む。
 * 1項目でも不正なら null を返す(=全項目フォールバック)。
 *
 * なぜ「その項目だけフォールバック」にしないのか:
 * 3値は互いに関係し合う(limit = min(base + perAd * adGrants, max))ため、
 * 一部だけKV値・一部だけ既定値という混成は、運用者が意図していない中途半端な
 * 無料枠設定を生む。例えば max だけ書き換えたつもりが base のタイポで無効化され、
 * 「maxはKVの新値・baseは旧既定値」という誰も設計していない組み合わせになる。
 * 全部採用するか、全部やめるか、の二択の方が結果を予測しやすい。
 *
 * @param {*} parsed
 * @returns {{base: number, perAd: number, max: number}|null}
 */
function validateLimits(parsed) {
  if (!parsed || typeof parsed !== 'object') return null;

  const base = parsed.baseDailyUnits;
  const perAd = parsed.unitsPerAd;
  const max = parsed.maxDailyUnits;

  // base は0を許容する(「広告を見ないと1回も使えない」設定を取れるようにするため)。
  if (!isInteger(base) || base < 0 || base > BASE_DAILY_UNITS_MAX) return null;
  // perAd が0だと広告を見ても枠が増えず、リワード広告のボタンが無意味になるため1以上。
  if (!isInteger(perAd) || perAd < 1 || perAd > UNITS_PER_AD_MAX) return null;
  if (!isInteger(max) || max < 1 || max > MAX_DAILY_UNITS_MAX) return null;
  // max < base だと base の分すら使えない(limit = min(base, max))。設定ミスとして無効にする。
  if (max < base) return null;

  return { base, perAd, max };
}

/**
 * 現在の limits を解決する(KV → 環境変数 → 既定値の順にフォールバック)。
 * loadNotice()と同じ流儀でWorkerメモリ60秒キャッシュを使う。
 * @returns {Promise<{base: number, perAd: number, max: number}>}
 */
async function loadLimits() {
  const cached = quotaLimitsCache.get(QUOTA_LIMITS_CACHE_KEY);
  if (cached !== undefined) return cached;

  const fallback = envLimits();
  // routes.js の getAdsKv() と同じく worker.js が橋渡ししたバインディングを見る
  // (KVはオブジェクトのため process.env へはコピーできない)。
  const kv = globalThis.__adsKv || null;
  if (!kv) {
    quotaLimitsCache.set(QUOTA_LIMITS_CACHE_KEY, fallback);
    return fallback;
  }

  let limits = fallback;
  try {
    const raw = await kv.get(QUOTA_LIMITS_KV_KEY);
    if (raw) {
      const validated = validateLimits(JSON.parse(raw));
      if (validated) limits = validated;
      else console.error('[quotaLimits] invalid quota-limits JSON, falling back to env');
    }
  } catch (err) {
    console.error('[quotaLimits] config parse failed:', err.message);
    limits = fallback;
  }

  quotaLimitsCache.set(QUOTA_LIMITS_CACHE_KEY, limits);
  return limits;
}

/** テスト用: 60秒キャッシュを捨てて次回のloadLimits()でKVを読み直させる。 */
function _resetCache() {
  quotaLimitsCache.delete(QUOTA_LIMITS_CACHE_KEY);
}

module.exports = {
  loadLimits,
  envLimits,
  validateLimits,
  _resetCache,
  _cache: quotaLimitsCache,
  QUOTA_LIMITS_KV_KEY,
  DEFAULT_BASE_DAILY_UNITS,
  DEFAULT_UNITS_PER_AD,
  DEFAULT_MAX_DAILY_UNITS,
};
