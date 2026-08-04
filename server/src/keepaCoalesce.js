'use strict';

/**
 * リクエスト・コアレッシング(single-flight): 同一keyの同時呼び出しをまとめる。
 * 設計書: docs/superpowers/specs/2026-08-02-keepa-token-depletion-design.md
 * (2026-08-03改訂で追加)。
 *
 * なぜ必要か:
 * 枯渇時に待たせるキューを撤去した代わりに、同一商品への同時アクセスバースト
 * (人気商品を多人数が同時にスキャンする等)がKeepaへの同時アウトバウンドを
 * 増やしすぎないよう、実際にKeepaを呼ぶのは同一key当たり1回にまとめる。
 *
 * スコープ: このモジュールはWorkerのisolate内メモリだけを使う(Durable Objectの
 * ような全isolate共有の一元化はしない)。理由:
 * - コアレッシングは正確性のための仕組みではなく、あくまで負荷削減のベストエフォート
 *   最適化(束ねられなかった場合も、その先のスロットル(keepaThrottle.js)が
 *   引き続き安全性を担保する)。
 * - Cloudflare Workersは1つの混雑コロケーションで多くの同時リクエストを
 *   同一isolateが捌くため、人気商品の同時アクセスバーストはisolate内で
 *   十分に束ねられる見込みがある。全isolateをまたぐ一元化(DO化)はYAGNI。
 */

/** @type {Map<string, Promise<any>>} */
const inFlight = new Map();

/**
 * keyに対応する呼び出しが進行中ならその結果を共有し、無ければfnを実行して登録する。
 * fnが解決/棄却した時点でin-flight登録を外す(次回以降は新規にfnが呼ばれる)。
 * @template T
 * @param {string} key
 * @param {() => Promise<T>} fn
 * @returns {Promise<T>}
 */
function coalesce(key, fn) {
  const existing = inFlight.get(key);
  if (existing) return existing;

  const promise = fn();
  inFlight.set(key, promise);
  promise.finally(() => {
    // 万一の入れ替わり(通常は起きないが念のため): 自分が登録した時のPromiseの
    // ままであることを確認してから消す。
    if (inFlight.get(key) === promise) inFlight.delete(key);
  });
  return promise;
}

/** テスト用: in-flight登録を全クリアする。 */
function _resetForTest() {
  inFlight.clear();
}

/** テスト用: 現在in-flightのkey数を返す。 */
function _inFlightCountForTest() {
  return inFlight.size;
}

module.exports = { coalesce, _resetForTest, _inFlightCountForTest };
