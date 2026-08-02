'use strict';

/**
 * 共有Keepaキーのトークン残量推定と優先度付き待ち行列(スロットル)。
 * 設計書: docs/superpowers/specs/2026-08-02-keepa-token-depletion-design.md §2.1
 *
 * なぜ必要か:
 * 共有Keepaキーは全ユーザーで1つのトークンバケット(補充は毎分KEEPA_REFILL_PER_MIN個)を
 * 共有する。枯渇時に即503で失敗させると「回復トークンの早い者勝ち」になり体験が悪いため、
 * 有限のキューで補充ペースに合わせて順番に流し、あふれた分だけを即座に断る(load shedding)。
 *
 * 2経路のファサード(deviceQuota.jsと同じ流儀):
 * - Workers本番: globalThis.__keepaThrottleDO(worker.jsが橋渡し)経由でKeepaThrottleDOへ委譲。
 *   キューと残量推定はグローバルに1つのDOが一元管理する(isolate間で状態共有するため)。
 * - Node/Render/テスト: インメモリのThrottleCoreへフォールバック。
 *
 * DO障害時の方針: deviceQuotaと同じく「許可」で倒す(可用性優先)。スロットルが一時的に
 * 効かなくなるリスクより、正当なユーザーが使えなくなる実害の方が大きい。ログは必ず残す。
 */

/**
 * env(またはprocess.env)からスロットル設定を読む。未設定・不正値は既定値。
 * KEEPA_BUCKET_CAPACITYは通常未設定(refill×60=Keepaのバケット仕様に一致)で、
 * テストが小さいバケットを作るためだけに存在する。
 * @param {object} env process.env互換のオブジェクト
 */
function readThrottleConfig(env) {
  const refillPerMin = (env && parseInt(env.KEEPA_REFILL_PER_MIN, 10)) || 5;
  const capacityRaw = env && parseInt(env.KEEPA_BUCKET_CAPACITY, 10);
  return {
    refillPerMin,
    capacity: Number.isFinite(capacityRaw) && capacityRaw > 0 ? capacityRaw : refillPerMin * 60,
    depth: (env && Number.isFinite(parseInt(env.KEEPA_QUEUE_DEPTH, 10))) ? parseInt(env.KEEPA_QUEUE_DEPTH, 10) : 10,
    timeoutMs: (env && parseInt(env.KEEPA_QUEUE_TIMEOUT_MS, 10)) || 25000,
  };
}

/**
 * スロットル本体。インメモリ経路とKeepaThrottleDOの両方がこのクラスを使う
 * (経路間で挙動がズレるバグを構造的に防ぐため、ロジックはここ1箇所に置く)。
 *
 * トークン残量は「推定」: 時刻差から連続的に補充を計算し、Keepaレスポンスの
 * tokensLeft(reportTokensLeft)で都度実値へ補正する。多少のズレは、過大側なら
 * Keepaの503(reportExhausted)で、過小側なら次のtokensLeft報告で収束する。
 */
class ThrottleCore {
  constructor(config) {
    this.config = config;
    this.tokens = config.capacity; // 起動直後は満タンと仮定(最初のreportで補正される)
    this.lastRefillAt = Date.now();
    /** @type {Array<{resolve: Function, timeoutTimer: any}>} */
    this.proQueue = [];
    this.freeQueue = [];
    this.grantTimer = null;
    // 監視用の日次統計(設計書§2.4)。ログにのみ使い、判定には使わない。
    // 日付が変わったらacquire時にリセットする(rollStatsDate)。
    this.stats = this.freshStats();
  }

  freshStats() {
    return {
      date: new Date().toISOString().slice(0, 10),
      granted: 0,
      queued: 0,
      shedDepth: 0,
      shedTimeout: 0,
      lastTokensLeft: null,
    };
  }

  /** 日付が変わっていたら統計をリセットする(「日次」統計にするため)。 */
  rollStatsDate() {
    const today = new Date().toISOString().slice(0, 10);
    if (this.stats.date !== today) this.stats = this.freshStats();
  }

  /** 経過時間ぶんのトークンを連続補充する(容量でクランプ)。 */
  refill(now) {
    const elapsed = now - this.lastRefillAt;
    if (elapsed <= 0) return;
    this.tokens = Math.min(this.config.capacity, this.tokens + (elapsed * this.config.refillPerMin) / 60000);
    this.lastRefillAt = now;
  }

  queueLength() {
    return this.proQueue.length + this.freeQueue.length;
  }

  /**
   * トークン1個の通行許可を求める。
   * @param {'pro'|'free'} priority
   * @returns {Promise<{allowed: boolean, reason?: 'depth'|'timeout'}>}
   */
  acquire(priority) {
    this.rollStatsDate();
    const now = Date.now();
    this.refill(now);

    if (this.tokens >= 1) {
      this.tokens -= 1;
      this.stats.granted += 1;
      return Promise.resolve({ allowed: true });
    }

    if (this.queueLength() >= this.config.depth) {
      this.stats.shedDepth += 1;
      this.logShed('depth');
      return Promise.resolve({ allowed: false, reason: 'depth' });
    }

    this.stats.queued += 1;
    return new Promise((resolve) => {
      const waiter = { resolve, timeoutTimer: null };
      waiter.timeoutTimer = setTimeout(() => {
        this.removeWaiter(waiter);
        this.stats.shedTimeout += 1;
        this.logShed('timeout');
        resolve({ allowed: false, reason: 'timeout' });
      }, this.config.timeoutMs);
      // Node環境でプロセスの終了を妨げないようにする(Workers/DOにはunrefが無い)。
      if (typeof waiter.timeoutTimer.unref === 'function') waiter.timeoutTimer.unref();

      (priority === 'pro' ? this.proQueue : this.freeQueue).push(waiter);
      this.scheduleGrant();
    });
  }

  removeWaiter(waiter) {
    for (const queue of [this.proQueue, this.freeQueue]) {
      const i = queue.indexOf(waiter);
      if (i >= 0) queue.splice(i, 1);
    }
  }

  /** 次の1トークンが貯まる時刻にgrantTickを予約する(多重予約はしない)。 */
  scheduleGrant() {
    if (this.grantTimer || this.queueLength() === 0) return;
    const now = Date.now();
    this.refill(now);
    const deficit = Math.max(0, 1 - this.tokens);
    const waitMs = Math.ceil((deficit * 60000) / this.config.refillPerMin);
    this.grantTimer = setTimeout(() => {
      this.grantTimer = null;
      this.grantTick();
    }, waitMs);
    if (typeof this.grantTimer.unref === 'function') this.grantTimer.unref();
  }

  /** 貯まったトークンぶんだけ、Pro優先でキュー先頭から許可する。 */
  grantTick() {
    this.refill(Date.now());
    while (this.tokens >= 1 && this.queueLength() > 0) {
      const waiter = this.proQueue.shift() || this.freeQueue.shift();
      clearTimeout(waiter.timeoutTimer);
      this.tokens -= 1;
      this.stats.granted += 1;
      waiter.resolve({ allowed: true });
    }
    this.scheduleGrant();
  }

  /** Keepaレスポンスの実残量で推定を上書きする。 */
  reportTokensLeft(tokensLeft) {
    if (!Number.isFinite(tokensLeft)) return;
    this.lastRefillAt = Date.now();
    this.tokens = Math.max(0, Math.min(this.config.capacity, tokensLeft));
    this.stats.lastTokensLeft = tokensLeft;
  }

  /** Keepaがkeepa_tokens_exhausted(503)を返した=実残量0。 */
  reportExhausted() {
    this.lastRefillAt = Date.now();
    this.tokens = 0;
    this.stats.lastTokensLeft = 0;
  }

  /** shedding発生時の構造化ログ(wrangler tailで確認する。設計書§2.4)。 */
  logShed(kind) {
    console.log(
      `[keepaThrottle] shed kind=${kind} stats=${JSON.stringify(this.stats)} queue=${this.queueLength()}`
    );
  }

  /** テスト用: 保留中のタイマーを全て破棄し、待機中はallowed:falseで解決する。 */
  destroy() {
    if (this.grantTimer) clearTimeout(this.grantTimer);
    this.grantTimer = null;
    for (const queue of [this.proQueue, this.freeQueue]) {
      for (const waiter of queue) {
        clearTimeout(waiter.timeoutTimer);
        waiter.resolve({ allowed: false, reason: 'timeout' });
      }
      queue.length = 0;
    }
  }
}

// ---------------------------------------------------------------------------
// DOバインディングの解決(deviceQuota.jsと同じ流儀)
// ---------------------------------------------------------------------------

let durableBindingOverride;
/**
 * テスト用: DOバインディングを差し替える。
 * - 何らかのモックbindingを渡すとDO経路を強制する。
 * - undefinedを渡すと通常状態(globalThis.__keepaThrottleDOを見る)に戻る。
 * - nullを渡すとインメモリ経路を強制する(globalThis.__keepaThrottleDOが設定されていても無視)。
 */
function _setDurableBinding(binding) {
  durableBindingOverride = binding;
}
function getDurableBinding() {
  return durableBindingOverride !== undefined ? durableBindingOverride : globalThis.__keepaThrottleDO || null;
}

/**
 * グローバルに1つのDOへfetchする。名前は固定("global")。
 * キューと残量は全ユーザー共通の状態なので、deviceQuotaのようにIDごとに分けない。
 */
async function callDurableObject(binding, path, params) {
  const id = binding.idFromName('global');
  const stub = binding.get(id);
  const qs = new URLSearchParams(params).toString();
  const res = await stub.fetch(`https://do/${path}?${qs}`, { method: 'POST' });
  const body = await res.json();
  if (!res.ok) {
    const err = new Error(`throttle DO ${path} returned status ${res.status}`);
    err.body = body;
    throw err;
  }
  return body;
}

// ---------------------------------------------------------------------------
// インメモリ経路(Node/Render/テスト用)
// ---------------------------------------------------------------------------

let core = null;
function getCore() {
  if (!core) core = new ThrottleCore(readThrottleConfig(process.env));
  return core;
}

// ---------------------------------------------------------------------------
// 公開API(async。DO経路とインメモリ経路で同じ戻り値の形)
// ---------------------------------------------------------------------------

/**
 * 共有Keepaキーでの1回の呼び出しの通行許可を求める。
 * @param {'pro'|'free'} priority
 * @returns {Promise<{allowed: boolean, reason?: 'depth'|'timeout'}>}
 */
async function acquire(priority) {
  const binding = getDurableBinding();
  if (!binding) return getCore().acquire(priority);
  try {
    return await callDurableObject(binding, 'acquire', { priority });
  } catch (err) {
    console.error('[keepaThrottle] DO acquire failed, allowing (availability first):', err.message);
    return { allowed: true };
  }
}

/** Keepaレスポンスのtokens Leftで推定を補正する(失敗しても本処理に影響させない)。 */
async function reportTokensLeft(tokensLeft) {
  const binding = getDurableBinding();
  if (!binding) return getCore().reportTokensLeft(tokensLeft);
  try {
    await callDurableObject(binding, 'report', { tokensLeft: String(tokensLeft) });
  } catch (err) {
    console.error('[keepaThrottle] DO report failed (ignored):', err.message);
  }
}

/** Keepaがkeepa_tokens_exhaustedを返したときの残量0補正。 */
async function reportExhausted() {
  const binding = getDurableBinding();
  if (!binding) return getCore().reportExhausted();
  try {
    await callDurableObject(binding, 'exhausted', {});
  } catch (err) {
    console.error('[keepaThrottle] DO exhausted-report failed (ignored):', err.message);
  }
}

/** テスト用: 環境変数を読み直してインメモリコアを作り直す。 */
function _resetForTest() {
  if (core) core.destroy();
  core = null;
}

module.exports = {
  acquire,
  reportTokensLeft,
  reportExhausted,
  ThrottleCore,
  readThrottleConfig,
  _setDurableBinding,
  _resetForTest,
};
