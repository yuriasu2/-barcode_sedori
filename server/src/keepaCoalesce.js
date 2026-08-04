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
 *
 * 【重要】keyの命名責任は呼び出し側にある: このモジュールはkey文字列の中身に
 * 一切関知しないため、スロットルインスタンス名(例: 'global'/'demo')や
 * BYOキーか共有キーかといった、隔離すべき軸をすべてkeyに含めること。
 * 例えば商品コードだけをkeyにすると、本番用の'global'インスタンスと
 * 開発者用の'demo'インスタンスへの呼び出しが同一keyとして束ねられてしまい、
 * 両者間で厳格に保っているはずの隔離が壊れる。必ず
 * `${instanceName}:${byoKeyOrShared}:${productCode}` のように、隔離軸を
 * すべて連結したものをkeyにすること。
 *
 * @template T
 * @param {string} key
 * @param {() => Promise<T>} fn
 * @returns {Promise<T>}
 */
function coalesce(key, fn) {
  const existing = inFlight.get(key);
  if (existing) return existing;

  // fnが同期的にthrowしたり、Promise以外の値を返したりしても、
  // coalesce()自体は必ずPromiseを返す契約を守る。
  // また、fn()の呼び出し自体が失敗した場合はin-flightに登録しないため、
  // 万一の異常時でもkeyが永久に居座って以降の呼び出しを塞ぐことはない。
  let promise;
  try {
    promise = Promise.resolve(fn());
  } catch (err) {
    return Promise.reject(err);
  }

  inFlight.set(key, promise);

  const cleanup = () => {
    // 万一の入れ替わり(通常は起きないが念のため): 自分が登録した時のPromiseの
    // ままであることを確認してから消す。
    if (inFlight.get(key) === promise) inFlight.delete(key);
  };
  // .finally()は棄却時にも棄却する新しいPromiseを生成してしまい、それを誰も
  // 処理しないとunhandledRejectionになる。成功/失敗の両方をthenの第1/第2引数で
  // 拾うことで、cleanup自体は例外を投げないため派生Promiseは必ず解決し、
  // unhandledRejectionを起こさない。
  promise.then(cleanup, cleanup);

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
