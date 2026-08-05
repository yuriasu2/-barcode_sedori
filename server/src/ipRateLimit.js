'use strict';

/**
 * 共有Keepaキーを実際に消費するリクエストに対する、クライアントIP単位のレート制限。
 *
 * なぜ必要か:
 * 無料枠クォータはX-Device-Idで数えているが、これはクライアントの自己申告に過ぎず、
 * curl等からIDを回せば1台の端末から無制限に新規クォータを取得できる。
 * アプリ側の検索クールダウン(7秒)はSwift実装なのでcurlには一切効かない。
 * 唯一の砦だった共有Keepaのスロットル(既定5トークン/分)はグローバルな上限であるため、
 * 単一の攻撃者がそれを丸ごと食い潰すと正規ユーザー全員が使えなくなる。
 * そこで「1つの発信元が単位時間に消費できるKeepa呼び出し回数」に上限を設ける。
 *
 * 適用範囲:
 * routes.jsのfetchKeepaProductWithDebug()(全Keepa商品取得の唯一のチョークポイント)
 * からのみ呼ぶ。キャッシュヒットはそこへ到達しないため自動的に対象外になり、
 * SP-API連携済みのリクエストもそもそもKeepaを呼ばないため対象外になる。
 * BYOキー(X-Keepa-Key)利用者は除外しない。BYO判定はヘッダー値の有無だけで決まるため、
 * 除外するとデタラメな値を付けるだけで制限を迂回できてしまうため。
 *
 * 状態の持ち方:
 * IPごとにDurable Objectを1つ割り当て(idFromName(ip))、固定ウィンドウで数える。
 * keepaThrottleDurableObjectの'global'インスタンスと同じ理由でstorageへは書かない
 * (レート制限に厳密な永続性は不要で、無料枠の書き込み上限も消費したくない)。
 * DOが退避されるとカウンタは0に戻るが、攻撃者が得るのは「たまに1ウィンドウ分
 * 多く通る」程度で許容範囲。
 *
 * DO障害時の方針:
 * deviceQuota.jsと同じく「許可(可用性優先)」で倒す。レート制限は攻撃の速度を
 * 落とすための仕組みであり、これが落ちたときに正規ユーザーまで止める価値はない。
 */

/** 固定ウィンドウの長さ(ミリ秒)。 */
const WINDOW_MS = 60000;

/** 環境変数が未設定・不正なときの既定値(回/分)。 */
const DEFAULT_LIMIT_PER_MIN = 30;

/**
 * 1分あたりの上限回数を解決する。
 * DOのコンストラクタはenvを直接受け取るため引数優先、無ければprocess.envを見る
 * (keepaThrottle.readThrottleConfigと同じ流儀)。
 */
function readLimitPerMin(env) {
  const raw = (env && env.IP_RATE_LIMIT_PER_MIN) || process.env.IP_RATE_LIMIT_PER_MIN;
  const parsed = parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_LIMIT_PER_MIN;
}

/**
 * 固定ウィンドウのカウンタ。DO経路・インメモリ経路の双方から使う。
 * スライディングウィンドウにしないのは、状態量(タイムスタンプの配列)を持たずに
 * 済ませるため。境界をまたぐ瞬間に最大2倍まで通り得るが、攻撃速度を桁で落とす
 * という目的には十分。
 */
class RateLimitCore {
  constructor(limitPerMin) {
    this.limitPerMin = limitPerMin;
    this.windowStartedAt = 0;
    this.count = 0;
  }

  /**
   * 1回分を数えて可否を返す。許可した場合のみカウンタが増える。
   * @param {number} [now] 現在時刻(ミリ秒)。テストから固定値を渡せるようにしている。
   */
  check(now = Date.now()) {
    if (now - this.windowStartedAt >= WINDOW_MS) {
      this.windowStartedAt = now;
      this.count = 0;
    }
    const retryAfterSec = Math.max(1, Math.ceil((this.windowStartedAt + WINDOW_MS - now) / 1000));

    if (this.count >= this.limitPerMin) {
      return { allowed: false, remaining: 0, retryAfterSec };
    }
    this.count += 1;
    return { allowed: true, remaining: this.limitPerMin - this.count, retryAfterSec };
  }
}

// ---------------------------------------------------------------------------
// インメモリ経路(Node/Render/テスト用)
// ---------------------------------------------------------------------------

/** ip -> RateLimitCore(インメモリ経路専用) */
const cores = new Map();

/** メモリ肥大化防止のしきい値。超えたら全消しする(レート制限なので取りこぼしても実害が小さい)。 */
const MAX_CORES = 10000;

function checkAndCountInMemory(ip) {
  if (cores.size > MAX_CORES) cores.clear();
  let core = cores.get(ip);
  if (!core) {
    core = new RateLimitCore(readLimitPerMin(null));
    cores.set(ip, core);
  }
  return core.check();
}

// ---------------------------------------------------------------------------
// DOバインディングの解決(deviceQuota.jsと同じ流儀)
// ---------------------------------------------------------------------------

let durableBindingOverride;

/**
 * テスト用: DOバインディングを差し替える。
 * - モックを渡すとDO経路を強制する。
 * - undefinedで通常状態(globalThis.__ipRateLimitDOを見る)へ戻る。
 * - nullでインメモリ経路を強制する。
 */
function _setDurableBinding(binding) {
  durableBindingOverride = binding;
}

function getDurableBinding() {
  return durableBindingOverride !== undefined ? durableBindingOverride : globalThis.__ipRateLimitDO || null;
}

/** 素通し(制限を適用しない)ときの戻り値。remaining=-1は「未計測」の意味。 */
function passthrough() {
  return { allowed: true, remaining: -1, retryAfterSec: 0 };
}

/**
 * IP 1件分を数えて可否を返す。
 * @param {string|null} ip クライアントIP。nullなら素通しする
 *   (Cloudflare以外の実行環境=CF-Connecting-IPが無い環境。攻撃対象ではないため)。
 */
async function checkAndCount(ip) {
  if (!ip) return passthrough();

  const binding = getDurableBinding();
  if (!binding) return checkAndCountInMemory(ip);

  try {
    const id = binding.idFromName(ip);
    const stub = binding.get(id);
    const res = await stub.fetch('https://do/check', { method: 'POST' });
    if (!res.ok) throw new Error(`ipRateLimit DO returned status ${res.status}`);
    return await res.json();
  } catch (err) {
    console.error('[ipRateLimit] DO check failed, allowing as fallback:', err.message);
    return passthrough();
  }
}

/** テスト用: インメモリ経路の全カウンタをクリアする。 */
function _reset() {
  cores.clear();
}

module.exports = {
  WINDOW_MS,
  DEFAULT_LIMIT_PER_MIN,
  readLimitPerMin,
  RateLimitCore,
  checkAndCount,
  _reset,
  _setDurableBinding,
};
