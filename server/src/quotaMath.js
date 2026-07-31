'use strict';

/**
 * フリーミアムv2「無料枠ユニット」モデルのクォータ計算式(純粋関数のみ)。
 *
 * なぜ計算式をここに切り出すのか:
 * インメモリ経路(deviceQuota.js)とDurable Objects経路(quotaDurableObject.js)の
 * 両方が同じ式で limit/unitsRemaining/capReached 等を計算する必要があり、
 * 二重実装すると片方だけ改修漏れが起きる(実際、旧deviceQuota.jsではbuildQuota/
 * tryConsume/grantAdの3箇所に式が散らばっていた)。I/Oやモジュール読込時のenv参照は
 * 一切行わず、呼び出し側が limits を都度渡す設計にすることで、Workers(DO)側の
 * env読込タイミングとNode側のprocess.env読込タイミングの違いに影響されないようにする。
 *
 * @typedef {{base: number, perAd: number, max: number}} QuotaLimits
 *   base: 1日あたりの基本ユニット数
 *   perAd: 広告視聴1本あたりに付与されるユニット数
 *   max: 1日の上限(cap)
 */

/**
 * adGrants本の広告視聴後のlimit(日次上限)を計算する。
 * limit = min(base + perAd * adGrants, max)
 * @param {number} adGrants
 * @param {QuotaLimits} limits
 * @returns {number}
 */
function computeLimit(adGrants, limits) {
  return Math.min(limits.base + limits.perAd * adGrants, limits.max);
}

/**
 * unitsUsed/adGrants/limitsから、クライアントへ返すquotaオブジェクトを組み立てる。
 * @param {number} unitsUsed
 * @param {number} adGrants
 * @param {QuotaLimits} limits
 * @returns {{unitsRemaining:number, baseRemaining:number, unitsUsed:number, adGrantsToday:number, adAvailable:boolean, capReached:boolean, limit:number}}
 */
function buildQuota(unitsUsed, adGrants, limits) {
  const limit = computeLimit(adGrants, limits);
  const unitsRemaining = Math.max(0, limit - unitsUsed);
  const baseRemaining = Math.max(0, limits.base - unitsUsed); // OCRゲート用(クライアントが使う)
  const capReached = limit >= limits.max;
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
 * unitsUsed + units が limit を超えないか(=消費できるか)を判定する。副作用なし。
 * @param {number} unitsUsed
 * @param {number} adGrants
 * @param {number} units 消費しようとしているユニット数
 * @param {QuotaLimits} limits
 * @returns {boolean}
 */
function canConsume(unitsUsed, adGrants, units, limits) {
  const limit = computeLimit(adGrants, limits);
  return unitsUsed + units <= limit;
}

/**
 * 広告視聴1本分を追加してもlimitが引き上がるか(=既にcapへ到達していないか)を判定する。
 * cap到達後に広告を視聴させても無意味なため、grantAd側の事前判定に使う。
 * @param {number} adGrants
 * @param {QuotaLimits} limits
 * @returns {boolean}
 */
function canGrantAd(adGrants, limits) {
  const currentLimit = computeLimit(adGrants, limits);
  return currentLimit < limits.max;
}

module.exports = {
  buildQuota,
  computeLimit,
  canConsume,
  canGrantAd,
};
