'use strict';

/**
 * Amazon出品者ID(seller ID)単位のPro無料お試し期間(既定7日間)。
 *
 * なぜサーバーが唯一の権威である必要があるか:
 * 旧実装(commit 37b1e7f/c3cdd5a)はお試し開始日時をクライアント側(UserDefaults)に置き、
 * サーバーは自己申告のX-App-Trialヘッダーを無条件に信用していた。これには2つの穴があった。
 * (1) UserDefaultsは再インストールで消えるが、SP-APIのリフレッシュトークンはKeychainに残るため
 *     「再インストール→連携トグルを1回押すだけ(再認可不要)」で新規7日間を無限に取り直せる。
 * (2) 端末の時計を巻き戻せばお試しを無期限に延長でき、しかもX-App-Trialは誰でも送れる。
 * seller ID(OAuth時にアプリが受け取るselling_partner_id)は再インストール・機種変更でも
 * 変わらず、サーバー自身の時計で判定するため、この2つの穴を両方塞げる。
 *
 * write-once:
 * 保存する値はstartedAt(epoch ms)のみ。既存レコードがあれば絶対に上書きしない。
 * この不変性こそがこの仕組み全体の防御であり(再度getOrStartを呼んでも延長できない)、
 * 呼び出し側(sellerTrialDurableObject.js)のコードでも明示的にコメントしている。
 *
 * 2経路のファサード(deviceQuota.js/ipRateLimit.jsと同じ流儀):
 * - Workers本番: globalThis.__sellerTrialDO(worker.jsがenv.SELLER_TRIALを橋渡し)経由でDOへ委譲する。
 * - Node/Render/テスト: DOバインディングが存在しないため、インメモリMapへフォールバックする。
 *
 * DO障害時の方針(deviceQuota.js/ipRateLimit.jsとは異なる):
 * 他の2つは「許可(可用性優先)」で倒すが、ここは既存Proユーザー向けのフォールバックが無い
 * 純粋な無料お試し機能であり、DO障害時に「お試し有効」を返すと外部から観測できない状態で
 * お試しを無制限配布してしまう(この改修が塞ごうとしている穴そのもの)。そのため障害時は
 * 「お試し無効」で倒す(fail-closed)。お試し中の正規ユーザーが一時的に締め出される実害はあるが、
 * 出品系APIはこのゲート自体がサーバー権威であり本質的に一時的な不便で済む。
 */

const DEFAULT_TRIAL_DAYS = 7;

/**
 * 1日のミリ秒数。
 */
const DAY_MS = 24 * 60 * 60 * 1000;

/**
 * お試し期間の日数を解決する。DOのコンストラクタはenvを直接受け取るため引数優先、
 * 無ければprocess.envを見る(ipRateLimit.readLimitPerMinと同じ流儀)。
 * @param {object|null} env
 */
function readTrialDays(env) {
  const raw = (env && env.SPAPI_TRIAL_DAYS) || process.env.SPAPI_TRIAL_DAYS;
  const parsed = parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_TRIAL_DAYS;
}

/**
 * startedAt/now/trialDaysから状態オブジェクトを組み立てる(副作用なし)。
 * DO・インメモリ経路の両方から使う共通ロジック。
 * @param {number} startedAt 開始時刻(epoch ms)
 * @param {number} now 現在時刻(epoch ms)
 * @param {number} trialDays お試し日数
 * @returns {{startedAt: number, expiresAt: number, active: boolean}}
 */
function buildStatus(startedAt, now, trialDays) {
  const expiresAt = startedAt + trialDays * DAY_MS;
  return { startedAt, expiresAt, active: now < expiresAt };
}

// ---------------------------------------------------------------------------
// インメモリ経路(Node/Render/テスト用)
// ---------------------------------------------------------------------------

/** sellerId -> startedAt(インメモリ経路専用) */
const records = new Map();

/** メモリ肥大化防止のしきい値。超えたら全消しする(deviceQuota.jsと同じ方針)。 */
const MAX_RECORDS = 50000;

function getOrStartInMemory(sellerId, now, trialDays) {
  if (records.size > MAX_RECORDS) records.clear();
  let startedAt = records.get(sellerId);
  if (startedAt === undefined) {
    // write-once: 既存レコードが無いときだけ新規発行する。
    startedAt = now;
    records.set(sellerId, startedAt);
  }
  return buildStatus(startedAt, now, trialDays);
}

// ---------------------------------------------------------------------------
// DOバインディングの解決(ipRateLimit.js/deviceQuota.jsと同じ流儀)
// ---------------------------------------------------------------------------

let durableBindingOverride;

/**
 * テスト用: DOバインディングを差し替える。
 * - モックを渡すとDO経路を強制する。
 * - undefinedで通常状態(globalThis.__sellerTrialDOを見る)へ戻る。
 * - nullでインメモリ経路を強制する。
 */
function _setDurableBinding(binding) {
  durableBindingOverride = binding;
}

function getDurableBinding() {
  return durableBindingOverride !== undefined ? durableBindingOverride : globalThis.__sellerTrialDO || null;
}

/**
 * 出品者ID1件分のお試し状態を取得する。レコードが無ければ今この瞬間を開始日時として
 * 新規発行し(write-once)、あればそれを一切変更せず返す。
 * @param {string|null|undefined} sellerId
 * @param {number} [now] 現在時刻(ミリ秒)。テストから固定値を渡せるようにしている。
 * @returns {Promise<{startedAt: number, expiresAt: number, active: boolean}|null>}
 *   sellerIdが空、またはDO障害時はnull(呼び出し側はnullを「お試し無効」として扱うこと)。
 */
async function getOrStart(sellerId, now = Date.now()) {
  if (!sellerId) return null;
  const key = String(sellerId);

  const binding = getDurableBinding();
  if (!binding) return getOrStartInMemory(key, now, readTrialDays(null));

  try {
    const id = binding.idFromName(key);
    const stub = binding.get(id);
    const qs = new URLSearchParams({ now: String(now) }).toString();
    const res = await stub.fetch(`https://do/get-or-start?${qs}`, { method: 'POST' });
    if (!res.ok) throw new Error(`sellerTrial DO returned status ${res.status}`);
    return await res.json();
  } catch (err) {
    // 方針: DOが落ちたら「お試し無効」で倒す(可用性より不正付与の防止を優先。ファイル先頭コメント参照)。
    console.error('[sellerTrial] DO getOrStart failed, treating trial as inactive:', err.message);
    return null;
  }
}

/** テスト用: インメモリ経路の全レコードをクリアする。 */
function _reset() {
  records.clear();
}

module.exports = {
  DEFAULT_TRIAL_DAYS,
  DAY_MS,
  readTrialDays,
  buildStatus,
  getOrStart,
  _reset,
  _setDurableBinding,
};
