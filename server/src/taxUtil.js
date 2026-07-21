'use strict';

/**
 * 消費税関連の共通ヘルパー。
 *
 * SP-API(Catalog Items API 2022-04-01)の attributes.list_price、および
 * KeepaのLISTPRICE(stats.current[4])は、いずれも税抜の生値であることを実データで確認済み
 * (書籍は軽減税率の対象外のため一律10%でよい)。
 * 両経路で同じ税込換算ロジックを使うため、ここに集約する。
 */
const CONSUMPTION_TAX_RATE = 0.1;

/**
 * 税抜価格(円)を税込価格(円・整数丸め)に変換する。
 * @param {number|null|undefined} value 税抜価格。数値でない場合はnullを返す。
 * @returns {number|null}
 */
function toTaxIncludedJpy(value) {
  if (typeof value !== 'number' || !Number.isFinite(value)) return null;
  return Math.round(value * (1 + CONSUMPTION_TAX_RATE));
}

module.exports = {
  CONSUMPTION_TAX_RATE,
  toTaxIncludedJpy,
};
