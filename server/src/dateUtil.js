'use strict';

/**
 * UTC基準の当日を "YYYY-M-D" で返す。
 * deviceQuota.js / quotaDurableObject.js の日次リセット判定で共通利用する
 * (サーバーのタイムゾーンに依存せず、Workers/Node両方で同じ日付になるようUTCで揃える)。
 */
function todayString() {
  const d = new Date();
  return `${d.getUTCFullYear()}-${d.getUTCMonth() + 1}-${d.getUTCDate()}`;
}

module.exports = { todayString };
