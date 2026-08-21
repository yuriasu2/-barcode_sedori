'use strict';

/**
 * コロケーション単位で共有するキャッシュ。
 *
 * 【なぜ必要か】
 * 従来のキャッシュ(cache.js の LruCache)は **Workers の isolate 内のインメモリ Map** で、
 * isolate は PoP ごとに複数あり、しかも短命に作り直される。つまり「同じ商品を別の人が
 * スキャンしたときにキャッシュが効く」という当初の狙いは、実際にはほとんど効いていない。
 * Keepa は共有APIキーのトークンを1リクエスト1個消費するため、キャッシュのヒット率が
 * そのまま共有トークンの消費量に直結する(設計書v2 §0 の「キャッシュ最優先」)。
 *
 * 【なぜ Cache API か(KVではなく)】
 * KV は無料プランで **書き込みが1日1,000回まで**。キャッシュミスのたびに書き込むため、
 * Keepa の補充レート(20トークン/分 = 28,800/日)に対して桁が足りない。
 * Cache API(caches.default)は書き込み回数の課金・上限が無く、レイテンシもKVより低い。
 * 共有範囲がコロケーション単位に限られるのが欠点だが、本アプリの利用者はほぼ日本国内で
 * 東京・大阪のPoPに集中するため、実効的なヒット率の差は小さいと判断した。
 * 有料プランへ移行してグローバル共有が欲しくなったら、L2をKVに差し替えればよい
 * (このクラスの外へは影響しない)。
 *
 * 【キャッシュキーのURLについて】
 * Cache API のキーはURLなので、worker.js がリクエストごとに渡すオリジン
 * (globalThis.__cacheOrigin)配下の `/__cache/<name>/<key>` を合成して使う。
 * 自ゾーンのURLを使う理由は、他ゾーンのURLだと put が保存されない実装差があるため。
 * このURLが外部から直接叩かれて中身が漏れることは無い: api.sellira.jp はカスタムドメイン
 * ルートでホスト全体がWorkerに向いており、**CDNキャッシュより前にWorkerが動く**ため、
 * `/__cache/...` へのリクエストはルータの404になる(キャッシュは参照されない)。
 *
 * 【Node(src/index.js)・テストでの扱い】
 * caches / __cacheOrigin が無い環境ではL2を丸ごと無効化し、従来どおりL1(LruCache)だけで
 * 動く。挙動は改修前と完全に同じになる。
 */

const { LruCache } = require('./cache');

const DEFAULT_L1_MAX_SIZE = 200;

/** Workers なら caches.default、それ以外(Node/テスト)は null。 */
function cacheApi() {
  const c = globalThis.caches;
  return c && c.default ? c.default : null;
}

class SharedCache {
  /**
   * @param {object} options
   * @param {string} options.name キャッシュ名(キャッシュキーURLの名前空間)。
   * @param {number} options.ttlMs 既定TTL。
   * @param {number} [options.maxSize] L1の最大件数。
   * @param {(key: string) => boolean} [options.shouldShare]
   *   L2へ載せるキーを絞る述語。省略時は全件。個人に紐づくデータ(SP-API経路の結果など)を
   *   コロケーション共有のキャッシュへ出さないために使う。
   */
  constructor({ name, ttlMs, maxSize = DEFAULT_L1_MAX_SIZE, shouldShare } = {}) {
    this.name = name;
    this.ttlMs = ttlMs;
    this.shouldShare = shouldShare || (() => true);
    this.l1 = new LruCache({ ttlMs, maxSize });
  }

  /** L2のキャッシュキー(Request)。L2が使えない環境ではnull。 */
  requestFor(key) {
    const origin = globalThis.__cacheOrigin;
    if (!origin) return null;
    if (!this.shouldShare(key)) return null;
    return new Request(`${origin}/__cache/${this.name}/${encodeURIComponent(key)}`, { method: 'GET' });
  }

  /**
   * L1 → L2 の順に引く。L2ヒットはL1へ載せ直す(同じisolateの次回をCache API往復なしにする)。
   * @returns {Promise<*|undefined>}
   */
  async get(key) {
    const l1Hit = this.l1.get(key);
    if (l1Hit !== undefined) return l1Hit;

    const cache = cacheApi();
    const request = this.requestFor(key);
    if (!cache || !request) return undefined;

    try {
      const res = await cache.match(request);
      if (!res) return undefined;
      const envelope = await res.json();
      if (!envelope || typeof envelope.exp !== 'number') return undefined;
      const remainingMs = envelope.exp - Date.now();
      // Cache-Controlのmax-ageでも期限は切れるが、秒単位の丸めやCloudflare側の裁量があるため
      // 保存時に埋めた期限(exp)で必ず自前でも判定する。
      if (remainingMs <= 0) return undefined;
      // L1へは「L2の残り時間」で載せる。既定TTLで載せ直すとL2の期限を超えて
      // 古い値を返し続けてしまう。
      this.l1.set(key, envelope.v, remainingMs);
      return envelope.v;
    } catch (err) {
      // キャッシュの失敗でリクエスト自体を落とさない(取得し直せばよいだけのため)。
      console.error(`[sharedCache:${this.name}] match failed:`, err.message);
      return undefined;
    }
  }

  /**
   * L1へ同期的に書いたうえで、L2への書き込みを行う。
   * 戻り値のPromiseはL2書き込みの完了を表す。呼び出し元はawaitすること
   * (Workersではレスポンス送出後に残った非同期処理は中断され得るため。
   * ctx.waitUntilはリクエストを跨ぐと "Cannot perform I/O on behalf of a different request"
   * になるため使わない)。テストなど同期的に仕込みたい場合はawaitしなくても
   * L1には確実に入る。
   * @returns {Promise<void>}
   */
  set(key, value, ttlMs) {
    const effectiveTtlMs = typeof ttlMs === 'number' ? ttlMs : this.ttlMs;
    this.l1.set(key, value, effectiveTtlMs);

    const cache = cacheApi();
    const request = this.requestFor(key);
    if (!cache || !request) return Promise.resolve();

    const body = JSON.stringify({ v: value, exp: Date.now() + effectiveTtlMs });
    const response = new Response(body, {
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Cache-Control': `max-age=${Math.max(1, Math.floor(effectiveTtlMs / 1000))}`,
      },
    });
    return cache.put(request, response).catch((err) => {
      console.error(`[sharedCache:${this.name}] put failed:`, err.message);
    });
  }

  /** L1からのみ削除する(L2は期限切れに任せる)。 */
  delete(key) {
    this.l1.delete(key);
  }

  /**
   * L1のみを空にする。Cache APIは列挙できないためL2は消せない。
   * テストではL2が無効なので、改修前のclear()と同じ意味になる。
   */
  clear() {
    this.l1.clear();
  }

  get size() {
    return this.l1.size;
  }
}

module.exports = { SharedCache };
