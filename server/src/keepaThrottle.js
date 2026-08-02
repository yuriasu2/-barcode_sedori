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
    // iOSの通信タイムアウト(APIClient.swiftのtimeoutInterval=10秒)より短くする必要がある。
    // これより長いと、iOS側が先に切断した後にサーバー側で許可が出て「誰も受け取らない
    // レスポンス」のためだけにユニット・トークンを消費する経路が生まれる。
    timeoutMs: (env && parseInt(env.KEEPA_QUEUE_TIMEOUT_MS, 10)) || 8000,
  };
}

// 適応ブレーキ(設計書§2.6)の安全圏(分)。コード内定数(YAGNI、環境変数化はしない)。
// Proは無料より短い安全圏(=枯渇ギリギリまでブレーキが掛からない)にして、
// §1の「キュー内でProを常に無料より優先する」と一貫させる。
const BRAKE_SAFE_TTE_MIN_FREE = 10;
const BRAKE_SAFE_TTE_MIN_PRO = 2;
// 消費レートを測る観測窓(ミリ秒)。直近60秒のgrant件数がconsumeRatePerMin。
const BRAKE_WINDOW_MS = 60000;

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
    // 適応ブレーキ(設計書§2.6)用: 直近許可(grant)のタイムスタンプ。60秒窓でprune。
    /** @type {number[]} */
    this.grantTimestamps = [];
    // ブレーキ待ち(sleep)中のタイマー。destroy()でまとめて解除する。
    /** @type {Set<{timer: any, resolve: Function}>} */
    this.brakeWaiters = new Set();
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
      braked: 0,
      lastTokensLeft: null,
      // 直近のconsumeRatePerMin(設計書§2.6)。logShed時に計算した値を格納するのみ
      // (判定には使わない。ログ・観測用)。
      consumeRatePerMin: 0,
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

  /**
   * refill()と同じ計算式で「今この瞬間の推定トークン数」を求めるが、
   * this.tokens/this.lastRefillAtへは書き込まない読み取り専用版。
   * デバッグ表示(debugSnapshot)専用: 観測のためだけに呼ぶ処理が本処理の状態
   * (実際のトークン消費計算の起点となるlastRefillAt)を書き換えてしまうと、
   * 見ただけで残量推定がズレるという副作用が生まれるため分離している。
   */
  peekTokens(now) {
    const elapsed = now - this.lastRefillAt;
    if (elapsed <= 0) return this.tokens;
    return Math.min(this.config.capacity, this.tokens + (elapsed * this.config.refillPerMin) / 60000);
  }

  queueLength() {
    return this.proQueue.length + this.freeQueue.length;
  }

  /** 許可(grant)の実績を記録する(適応ブレーキの消費レート計測用。設計書§2.6)。 */
  recordGrant(now) {
    this.grantTimestamps.push(now);
    this.pruneGrantTimestamps(now);
  }

  /** 60秒窓より古い記録を捨てる。 */
  pruneGrantTimestamps(now) {
    const cutoff = now - BRAKE_WINDOW_MS;
    while (this.grantTimestamps.length > 0 && this.grantTimestamps[0] < cutoff) {
      this.grantTimestamps.shift();
    }
  }

  /** 直近60秒の許可件数(=消費レート/分。全呼び出しが1トークンなので件数=トークン数)。 */
  consumeRatePerMin(now) {
    this.pruneGrantTimestamps(now);
    return this.grantTimestamps.length;
  }

  /**
   * 適応ブレーキ(設計書§2.6)の遅延時間(ms)を計算する。
   * 消費レートが補充レートを上回り(net>0)、かつ枯渇予測時間(TTE)が安全圏を
   * 切っている場合のみ、0〜cap(下記)の範囲で線形に遅延を返す。
   * 補充が消費に勝っている(net<=0)間は常に0(空いている時は残量が少なくても即応答)。
   * @param {'pro'|'free'} priority
   * @param {number} now
   */
  computeBrakeMs(priority, now) {
    const rate = this.consumeRatePerMin(now);
    const net = rate - this.config.refillPerMin;
    if (net <= 0) return 0;

    const tteMin = this.tokens / net;
    const safeMin = priority === 'pro' ? BRAKE_SAFE_TTE_MIN_PRO : BRAKE_SAFE_TTE_MIN_FREE;
    if (tteMin >= safeMin) return 0;

    // floorMs=補充間隔(補充と同速まで遅延させれば、そこで消費≦補充となり均衡する)。
    // ただし低速プラン(現行本番=5トークン/分ではfloorMs=12000ms)ではfloorMsだけで
    // 既に config.timeoutMs(既定8000ms)を超えてしまい、ブレーキ単体でiOSの通信
    // タイムアウトに抵触しかねない。そのためcapは「floorMsとtimeoutMs-1秒(=キュー
    // 経路に最低1秒分の予算を残す)の小さい方」にクランプする。20/分ならfloor=3000msで
    // timeoutMs-1000(既定7000ms)より十分小さいため挙動は変わらない。
    const floorMs = 60000 / this.config.refillPerMin;
    const cap = Math.min(floorMs, Math.max(0, this.config.timeoutMs - 1000));
    return Math.round(Math.min(cap, cap * (1 - tteMin / safeMin)));
  }

  /**
   * ブレーキ待ちのsleep。destroy()で強制的に打ち切られた場合はfalseを返す
   * (通常のタイマー満了ならtrue)。
   * @returns {Promise<boolean>}
   */
  sleepForBrake(ms) {
    return new Promise((resolve) => {
      const entry = { timer: null, resolve: null };
      entry.timer = setTimeout(() => {
        this.brakeWaiters.delete(entry);
        resolve(true);
      }, ms);
      if (typeof entry.timer.unref === 'function') entry.timer.unref();
      entry.resolve = () => resolve(false);
      this.brakeWaiters.add(entry);
    });
  }

  /**
   * トークン1個の通行許可を求める。
   * @param {'pro'|'free'} priority
   * @returns {Promise<{allowed: boolean, reason?: 'depth'|'timeout'}>}
   */
  async acquire(priority) {
    this.rollStatsDate();
    let now = Date.now();
    this.refill(now);

    // キューに待機者がいるのにトークンがあるからと新参を先に通すと、残量補正
    // (reportTokensLeft/reportExhausted)直後などの窓で新参が待機中のPro/freeを
    // 追い越せてしまう。自分の判定に進む前に、先にキューを流しておく。
    if (this.queueLength() > 0 && this.tokens >= 1) {
      this.grantTick();
    }

    // 適応ブレーキ(設計書§2.6): 即時許可できる状況でも、消費速度が枯渇へ向かっている
    // 場合は補充間隔を上限に遅延を入れる。1回のacquireにつき最大1回だけ適用する。
    let brakeMs = 0;
    if (this.tokens >= 1) {
      brakeMs = this.computeBrakeMs(priority, now);
      if (brakeMs > 0) {
        this.stats.braked += 1;
        const completedNormally = await this.sleepForBrake(brakeMs);
        if (!completedNormally) {
          // destroy()による強制解除。テストがぶら下がらないよう即座に拒否で返す。
          return { allowed: false, reason: 'timeout' };
        }
        now = Date.now();
        this.refill(now);
        // 待っている間に他の待機者がいれば先に流す(既存の追い越し防止ルールと同じ理由)。
        if (this.queueLength() > 0 && this.tokens >= 1) {
          this.grantTick();
        }
      }
    }

    if (this.tokens >= 1) {
      this.tokens -= 1;
      this.recordGrant(now);
      this.stats.granted += 1;
      return { allowed: true };
    }

    if (this.queueLength() >= this.config.depth) {
      this.stats.shedDepth += 1;
      this.logShed('depth');
      return { allowed: false, reason: 'depth' };
    }

    this.stats.queued += 1;
    // ブレーキで既に使った時間の分だけキュー待ちの上限を短くし、合計がtimeoutMsを
    // 超えないようにする(設計書§2.6: iOSの通信タイムアウトより短く保つ必要があるため)。
    const remainingTimeoutMs = Math.max(0, this.config.timeoutMs - brakeMs);
    return new Promise((resolve) => {
      const waiter = { resolve, timeoutTimer: null };
      waiter.timeoutTimer = setTimeout(() => {
        this.removeWaiter(waiter);
        this.stats.shedTimeout += 1;
        this.logShed('timeout');
        resolve({ allowed: false, reason: 'timeout' });
      }, remainingTimeoutMs);
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
    const now = Date.now();
    this.refill(now);
    while (this.tokens >= 1 && this.queueLength() > 0) {
      const waiter = this.proQueue.shift() || this.freeQueue.shift();
      clearTimeout(waiter.timeoutTimer);
      this.tokens -= 1;
      this.recordGrant(now);
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
    this.reflowQueueAfterCorrection();
  }

  /** Keepaがkeepa_tokens_exhausted(503)を返した=実残量0。 */
  reportExhausted() {
    this.lastRefillAt = Date.now();
    this.tokens = 0;
    this.stats.lastTokensLeft = 0;
    this.reflowQueueAfterCorrection();
  }

  /**
   * 残量補正(reportTokensLeft/reportExhausted)の直後に呼ぶ。
   * 補正前の残量見積もりを前提に予約されたgrantTimerを一度破棄してgrantTickを
   * やり直すことで、上方補正なら待機者を即座に流し、下方補正なら現在の残量から
   * 正しい待ち時間で再予約されるようにする(古いタイマーを放置すると、上方補正時に
   * 補充ペース分だけ余計に待たされたり、下方補正時に時期尚早な許可が起きたりする)。
   */
  reflowQueueAfterCorrection() {
    if (this.grantTimer) {
      clearTimeout(this.grantTimer);
      this.grantTimer = null;
    }
    if (this.queueLength() > 0) this.grantTick();
  }

  /**
   * デバッグ用: 現在の推定状態のスナップショット(観測のみ、副作用なし)。
   * refill()を呼ぶとthis.tokens/this.lastRefillAtが書き換わってしまうため、
   * ここでは読み取り専用のpeekTokens()で見かけ上のトークン数だけを計算する。
   */
  debugSnapshot(now = Date.now()) {
    return {
      tokensEstimate: Math.round(this.peekTokens(now) * 10) / 10,
      capacity: this.config.capacity,
      consumeRatePerMin: this.consumeRatePerMin(now),
      refillPerMin: this.config.refillPerMin,
      queueLength: this.queueLength(),
      depth: this.config.depth,
    };
  }

  /** shedding発生時の構造化ログ(wrangler tailで確認する。設計書§2.4)。直近消費レートも出す(§2.6)。 */
  logShed(kind) {
    const rate = this.consumeRatePerMin(Date.now());
    this.stats.consumeRatePerMin = rate;
    console.log(
      `[keepaThrottle] shed kind=${kind} rate=${rate} stats=${JSON.stringify(this.stats)} queue=${this.queueLength()}`
    );
  }

  /** テスト用: 保留中のタイマーを全て破棄し、待機中はallowed:falseで解決する。 */
  destroy() {
    if (this.grantTimer) clearTimeout(this.grantTimer);
    this.grantTimer = null;
    // ブレーキ待ち(sleep)中のacquireも、destroy中に取り残されないよう強制解除する。
    for (const entry of this.brakeWaiters) {
      clearTimeout(entry.timer);
      entry.resolve();
    }
    this.brakeWaiters.clear();
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

/**
 * デバッグ表示用: 現在の推定状態のスナップショット(観測のみ、副作用なし)。
 * DO障害時はnullを返す(可用性優先のacquireと違い、デバッグ情報が取れないだけで
 * 実害が無いため、reportTokensLeftと同じ「失敗を無視」の作法。ただし戻り値はnull)。
 */
async function debugSnapshot() {
  const binding = getDurableBinding();
  if (!binding) return getCore().debugSnapshot();
  try {
    return await callDurableObject(binding, 'debug', {});
  } catch (err) {
    console.error('[keepaThrottle] DO debug snapshot failed (ignored):', err.message);
    return null;
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
  debugSnapshot,
  ThrottleCore,
  readThrottleConfig,
  _setDurableBinding,
  _resetForTest,
};
