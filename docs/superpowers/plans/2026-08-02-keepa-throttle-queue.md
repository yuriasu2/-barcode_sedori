# Keepaトークン枯渇対応（優先度付きキュー＋load shedding）実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 共有Keepaキーの枯渇時に、リクエストを優先度付きキュー（Pro優先）で補充ペースに合わせて流し、あふれた分は「混み合っているので時間を空けてお試しください。」で即座に返す。

**Architecture:** 新Durable Object `KeepaThrottleDO`（グローバル1個）がトークン残量推定と待ち行列を一元管理。`deviceQuota.js` と同じファサード方式（Workers=DO委譲 / Node・テスト=インメモリ）。ロジック本体は共有クラス `ThrottleCore` に置き、DOとインメモリの両経路が同じコアを使う。iOSは新エラー `keepa_busy`(429) を判別して再試行＋誘導UIを出す。

**Tech Stack:** Cloudflare Workers + Durable Objects (SQLite backend, ESM) / Node.js CJS (routes.js) / node --test / SwiftUI (iOS 16+)

**設計書:** `docs/superpowers/specs/2026-08-02-keepa-token-depletion-design.md`（要件・決定事項はすべてこちらが正）

> **事後訂正(2026-08-02)**: 本計画書は`KEEPA_QUEUE_TIMEOUT_MS`の既定値を8000msとして
> 記述しているが、本番実測でiOS側タイムアウト(10秒)とのマージン不足が判明し、
> 実際の運用値は**6000ms**に変更されている。本計画書は実行当時の記録として原文のまま
> 残し、現在値・理由は設計書§2.5・§5を参照。

## Global Constraints

- お断り文言は正確に「混み合っているので時間を空けてお試しください。」（設計書 §1）
- エラーレスポンスは **HTTP 429** `{ "error": "keepa_busy", "message": "<上記文言>" }`（既存の `quota_exceeded` と `error` コードで区別）
- 環境変数: `KEEPA_REFILL_PER_MIN`(既定"5") / `KEEPA_QUEUE_DEPTH`(既定"10") / `KEEPA_QUEUE_TIMEOUT_MS`(既定"8000")
- キュー拒否時に無料枠ユニットを消費しないこと（acquire成功後にのみ消費）（設計書 §2.2）
- BYO Keepaキー（`X-Keepa-Key` ヘッダー非空）・キャッシュヒット・SP-API経路はスロットル対象外
- DO障害時は「許可」で倒す（可用性優先、`deviceQuota.js` と同方針）
- サーバーのコメントは日本語で「なぜ」を書く（既存流儀）
- コミットメッセージ末尾: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **iOSビルドの注意**: 増分ビルドがdylib署名を壊すことがある。ビルド前に `rm -rf "$APP"`、ビルド後に `codesign -f -s -` で3ファイル(`__preview.dylib`/`BarcodeSedori.debug.dylib`/バンドル本体)を再署名してからインストールする（本文書末尾の「iOSビルド手順」参照）

---

### Task 1: ThrottleCore＋インメモリファサード（server/src/keepaThrottle.js）

**Files:**
- Create: `server/src/keepaThrottle.js`
- Test: `server/test/keepa-throttle.test.js`

**Interfaces:**
- Produces（後続タスクが依存する公開API。CJS `module.exports`）:
  - `acquire(priority: 'pro'|'free') => Promise<{allowed: boolean, reason?: 'depth'|'timeout'}>`
  - `reportTokensLeft(tokensLeft: number) => Promise<void>`（Keepaレスポンスの実残量で推定を補正）
  - `reportExhausted() => Promise<void>`（Keepaが503を返したとき残量0へ補正）
  - `ThrottleCore`（クラス。Task 2のDOが再利用）
  - `readThrottleConfig(env) => {refillPerMin, capacity, depth, timeoutMs}`（Task 2のDOが再利用）
  - テスト用: `_setDurableBinding(binding|null|undefined)` / `_resetForTest()`（環境変数を読み直してコアを作り直し、保留中のタイマーを破棄）

- [ ] **Step 1: 失敗するテストを書く**

`server/test/keepa-throttle.test.js` を新規作成:

```js
'use strict';

const test = require('node:test');
const assert = require('node:assert');

const keepaThrottle = require('../src/keepaThrottle');

/** 各テストの前に環境変数を設定してコアを作り直すヘルパ。t.afterで必ず復元する。 */
function configure(t, { refillPerMin, depth, timeoutMs, capacity }) {
  const saved = {
    KEEPA_REFILL_PER_MIN: process.env.KEEPA_REFILL_PER_MIN,
    KEEPA_QUEUE_DEPTH: process.env.KEEPA_QUEUE_DEPTH,
    KEEPA_QUEUE_TIMEOUT_MS: process.env.KEEPA_QUEUE_TIMEOUT_MS,
    KEEPA_BUCKET_CAPACITY: process.env.KEEPA_BUCKET_CAPACITY,
  };
  if (refillPerMin !== undefined) process.env.KEEPA_REFILL_PER_MIN = String(refillPerMin);
  if (depth !== undefined) process.env.KEEPA_QUEUE_DEPTH = String(depth);
  if (timeoutMs !== undefined) process.env.KEEPA_QUEUE_TIMEOUT_MS = String(timeoutMs);
  if (capacity !== undefined) process.env.KEEPA_BUCKET_CAPACITY = String(capacity);
  keepaThrottle._resetForTest();
  t.after(() => {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
    keepaThrottle._resetForTest();
  });
}

test('keepaThrottle: 残量がある間は即時allowed', async (t) => {
  configure(t, { capacity: 2, refillPerMin: 60, depth: 10, timeoutMs: 1000 });
  assert.deepEqual(await keepaThrottle.acquire('free'), { allowed: true });
  assert.deepEqual(await keepaThrottle.acquire('free'), { allowed: true });
});

test('keepaThrottle: 枯渇するとキューに入り、補充で順に許可される', async (t) => {
  // capacity=1: 1件目で枯渇。refillPerMin=600 → 100msに1トークン補充。
  configure(t, { capacity: 1, refillPerMin: 600, depth: 10, timeoutMs: 5000 });
  assert.deepEqual(await keepaThrottle.acquire('free'), { allowed: true });
  const started = Date.now();
  const result = await keepaThrottle.acquire('free');
  assert.deepEqual(result, { allowed: true });
  // 即時ではなく補充を待ったこと(≒100ms)を確認。CIの揺らぎを見て50ms以上とする。
  assert.ok(Date.now() - started >= 50, '補充を待たずに許可された');
});

test('keepaThrottle: キュー内ではProがfreeより先に許可される', async (t) => {
  configure(t, { capacity: 1, refillPerMin: 600, depth: 10, timeoutMs: 5000 });
  await keepaThrottle.acquire('free'); // 枯渇させる
  const order = [];
  const freeWaiter = keepaThrottle.acquire('free').then(() => order.push('free'));
  const proWaiter = keepaThrottle.acquire('pro').then(() => order.push('pro'));
  await Promise.all([freeWaiter, proWaiter]);
  assert.deepEqual(order, ['pro', 'free']);
});

test('keepaThrottle: キュー深さ超過は即時 reason=depth で拒否', async (t) => {
  configure(t, { capacity: 1, refillPerMin: 1, depth: 1, timeoutMs: 60000 });
  await keepaThrottle.acquire('free'); // 枯渇
  const queued = keepaThrottle.acquire('free'); // depth 1/1 を占有(補充は1分後なので待ち続ける)
  const rejected = await keepaThrottle.acquire('free'); // 満杯 → 即拒否
  assert.deepEqual(rejected, { allowed: false, reason: 'depth' });
  keepaThrottle._resetForTest(); // queuedを破棄(テストをぶら下げない)
  await queued; // resetで解決される(allowed:falseでよい)
});

test('keepaThrottle: 待ちがtimeoutMsを超えると reason=timeout で拒否', async (t) => {
  configure(t, { capacity: 1, refillPerMin: 1, depth: 10, timeoutMs: 100 });
  await keepaThrottle.acquire('free'); // 枯渇(補充は1分後=間に合わない)
  const started = Date.now();
  const result = await keepaThrottle.acquire('free');
  assert.deepEqual(result, { allowed: false, reason: 'timeout' });
  assert.ok(Date.now() - started >= 90, 'タイムアウトまで待っていない');
});

test('keepaThrottle: reportTokensLeftで推定残量が補正される', async (t) => {
  configure(t, { capacity: 10, refillPerMin: 1, depth: 0, timeoutMs: 100 });
  await keepaThrottle.reportTokensLeft(0); // 実残量0と報告
  // depth=0なのでキューに入れず即拒否になる=残量0が反映されている証拠
  assert.deepEqual(await keepaThrottle.acquire('free'), { allowed: false, reason: 'depth' });
});

test('keepaThrottle: reportExhaustedで残量0になる', async (t) => {
  configure(t, { capacity: 10, refillPerMin: 1, depth: 0, timeoutMs: 100 });
  await keepaThrottle.reportExhausted();
  assert.deepEqual(await keepaThrottle.acquire('free'), { allowed: false, reason: 'depth' });
});

test('keepaThrottle: DO経路はbindingのfetchへ委譲する', async (t) => {
  const calls = [];
  const binding = {
    idFromName: (name) => ({ name }),
    get: () => ({
      fetch: async (url) => {
        calls.push(url);
        return new Response(JSON.stringify({ allowed: true }), { status: 200 });
      },
    }),
  };
  keepaThrottle._setDurableBinding(binding);
  t.after(() => keepaThrottle._setDurableBinding(undefined));
  assert.deepEqual(await keepaThrottle.acquire('pro'), { allowed: true });
  assert.ok(calls[0].includes('/acquire') && calls[0].includes('priority=pro'));
});

test('keepaThrottle: DO障害時はallowed:trueで倒す(可用性優先)', async (t) => {
  const binding = {
    idFromName: (name) => ({ name }),
    get: () => ({ fetch: async () => { throw new Error('DO unreachable'); } }),
  };
  keepaThrottle._setDurableBinding(binding);
  t.after(() => keepaThrottle._setDurableBinding(undefined));
  const result = await keepaThrottle.acquire('free');
  assert.equal(result.allowed, true);
});
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `cd server && node --test test/keepa-throttle.test.js`
Expected: FAIL（`Cannot find module '../src/keepaThrottle'`）

- [ ] **Step 3: 実装を書く**

`server/src/keepaThrottle.js` を新規作成:

```js
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
    timeoutMs: (env && parseInt(env.KEEPA_QUEUE_TIMEOUT_MS, 10)) || 8000,
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
  return res.json();
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
```

- [ ] **Step 4: テストが通ることを確認**

Run: `cd server && node --test test/keepa-throttle.test.js`
Expected: PASS（9件）

- [ ] **Step 5: 既存テストへの影響が無いことを確認**

Run: `cd server && npm test`
Expected: 全件PASS（既存219件＋新規9件）

- [ ] **Step 6: コミット**

```bash
git add server/src/keepaThrottle.js server/test/keepa-throttle.test.js
git commit -m "Keepaスロットルのコア(トークン推定+優先度キュー+shedding)を追加

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: KeepaThrottleDO＋Workersバインディング配線

**Files:**
- Create: `server/src/keepaThrottleDurableObject.js`
- Modify: `server/src/worker.js`（DO再エクスポートとglobalThis橋渡し）
- Modify: `server/wrangler.jsonc`（binding・migration・vars追加）
- Test: `server/test/keepa-throttle-do.test.js`

**Interfaces:**
- Consumes: Task 1の `ThrottleCore` / `readThrottleConfig`
- Produces: DOクラス `KeepaThrottleDO`（fetchルート: POST `/acquire?priority=` → `{allowed, reason?}` / POST `/report?tokensLeft=` → `{ok:true}` / POST `/exhausted` → `{ok:true}`）。バインディング名 `KEEPA_THROTTLE`、`globalThis.__keepaThrottleDO`

- [ ] **Step 1: 失敗するテストを書く**

`server/test/keepa-throttle-do.test.js` を新規作成（DOクラスを直接インスタンス化して検証する。`quota-do.test.js` と同じ発想でstate/envを手作りする）:

```js
'use strict';

const test = require('node:test');
const assert = require('node:assert');

// ESMのDOクラスをCJSテストから読む(quotaDurableObject.jsと同じくdynamic importを使う)
async function loadDoClass() {
  const mod = await import('../src/keepaThrottleDurableObject.js');
  return mod.KeepaThrottleDO;
}

function makeDo(env) {
  // KeepaThrottleDOはstorageを使わない(残量はインメモリ推定、キューはPromise)ため、stateはダミーでよい。
  return loadDoClass().then((KeepaThrottleDO) => new KeepaThrottleDO({}, env));
}

test('KeepaThrottleDO: /acquireは残量があればallowed:true', async () => {
  const doInstance = await makeDo({ KEEPA_BUCKET_CAPACITY: '2', KEEPA_REFILL_PER_MIN: '60' });
  const res = await doInstance.fetch(new Request('https://do/acquire?priority=free', { method: 'POST' }));
  assert.deepEqual(await res.json(), { allowed: true });
});

test('KeepaThrottleDO: /reportで残量0にすると、depth=0の/acquireは即拒否', async () => {
  const doInstance = await makeDo({
    KEEPA_BUCKET_CAPACITY: '10',
    KEEPA_REFILL_PER_MIN: '1',
    KEEPA_QUEUE_DEPTH: '0',
  });
  await doInstance.fetch(new Request('https://do/report?tokensLeft=0', { method: 'POST' }));
  const res = await doInstance.fetch(new Request('https://do/acquire?priority=pro', { method: 'POST' }));
  assert.deepEqual(await res.json(), { allowed: false, reason: 'depth' });
});

test('KeepaThrottleDO: /exhaustedで残量0になる', async () => {
  const doInstance = await makeDo({
    KEEPA_BUCKET_CAPACITY: '10',
    KEEPA_REFILL_PER_MIN: '1',
    KEEPA_QUEUE_DEPTH: '0',
  });
  await doInstance.fetch(new Request('https://do/exhausted', { method: 'POST' }));
  const res = await doInstance.fetch(new Request('https://do/acquire?priority=free', { method: 'POST' }));
  assert.deepEqual(await res.json(), { allowed: false, reason: 'depth' });
});

test('KeepaThrottleDO: 不明なパスは404', async () => {
  const doInstance = await makeDo({});
  const res = await doInstance.fetch(new Request('https://do/unknown', { method: 'POST' }));
  assert.equal(res.status, 404);
});
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `cd server && node --test test/keepa-throttle-do.test.js`
Expected: FAIL（`Cannot find module .../keepaThrottleDurableObject.js`）

- [ ] **Step 3: DOクラスを実装**

`server/src/keepaThrottleDurableObject.js` を新規作成:

```js
/**
 * 共有Keepaキーのスロットル状態(トークン残量推定+優先度付きキュー)を一元管理するDurable Object。
 * Workers専用(Node/Render側では読み込まれない)。
 *
 * deviceQuotaのDOと違い、全ユーザー共通の状態なのでインスタンスはグローバルに1つ
 * (呼び出し側keepaThrottle.jsがidFromName('global')で固定)。
 *
 * 永続化しない理由:
 * - 残量はあくまで「推定」で、Keepaレスポンスのtokens Leftで毎回補正される。
 *   DOが退避(evict)されて満タン仮定から再開しても、数リクエストで実値へ収束する。
 * - キューは保留中のHTTPリクエスト(Promise)そのものなので、そもそも永続化できない
 *   (リクエスト保持中はDOが生き続けるため、実害もない)。
 * - storageを使わないことで、無料枠の書き込み上限も消費しない。
 */

import * as throttleNs from './keepaThrottle.js';

// keepaThrottle.jsはCommonJS。バンドラのCJS→ESM相互運用のフォールバック
// (worker.js/quotaDurableObject.jsと同じ流儀)。
const throttle = throttleNs.default || throttleNs;

export class KeepaThrottleDO {
  constructor(state, env) {
    // stateは使わない(上記コメント参照)が、DOの規約上コンストラクタで受け取る。
    this.core = new throttle.ThrottleCore(throttle.readThrottleConfig(env));
  }

  async fetch(request) {
    const url = new URL(request.url);

    if (request.method === 'POST' && url.pathname === '/acquire') {
      const priority = url.searchParams.get('priority') === 'pro' ? 'pro' : 'free';
      // DOは同一オブジェクトへのリクエストを直列化するが、awaitで待つ間は他リクエストを
      // 受け付ける(input gateはstorage操作間のみ排他)ため、キュー待ちで詰まらない。
      const result = await this.core.acquire(priority);
      return Response.json(result);
    }
    if (request.method === 'POST' && url.pathname === '/report') {
      const tokensLeft = parseInt(url.searchParams.get('tokensLeft'), 10);
      this.core.reportTokensLeft(tokensLeft);
      return Response.json({ ok: true });
    }
    if (request.method === 'POST' && url.pathname === '/exhausted') {
      this.core.reportExhausted();
      return Response.json({ ok: true });
    }
    return new Response('not found', { status: 404 });
  }
}
```

- [ ] **Step 4: worker.jsへ配線**

`server/src/worker.js` の既存行:

```js
export { DeviceQuotaDO } from './quotaDurableObject.js';
```

の直後に追加:

```js
// Keepaスロットル(共有キーのトークン推定+優先度キュー)のDO。グローバルに1つ。
export { KeepaThrottleDO } from './keepaThrottleDurableObject.js';
```

同ファイルの既存行:

```js
    globalThis.__quotaDO = env.DEVICE_QUOTA || null;
```

の直後に追加:

```js
    // Keepaスロットルのバインディング。keepaThrottle.js側がglobalThis経由で参照する
    // (__quotaDOと同じ簡易な受け渡し方式)。
    globalThis.__keepaThrottleDO = env.KEEPA_THROTTLE || null;
```

- [ ] **Step 5: wrangler.jsoncへbinding・migration・varsを追加**

`server/wrangler.jsonc` の `durable_objects.bindings` 配列へ追加:

```jsonc
  "durable_objects": {
    "bindings": [
      { "name": "DEVICE_QUOTA", "class_name": "DeviceQuotaDO" },
      { "name": "KEEPA_THROTTLE", "class_name": "KeepaThrottleDO" }
    ]
  },
```

`migrations` 配列へ追記（既存のv1はそのまま残す）:

```jsonc
  "migrations": [
    { "tag": "v1", "new_sqlite_classes": ["DeviceQuotaDO"] },
    { "tag": "v2", "new_sqlite_classes": ["KeepaThrottleDO"] }
  ]
```

`vars` へ追加:

```jsonc
    // Keepaスロットル(keepaThrottle.js)。契約プランの毎分トークン数 / キュー深さ上限 /
    // キュー待ちの最大ミリ秒(iOSの通信タイムアウトより短くすること)。
    // プランを20トークン/分へ上げたらKEEPA_REFILL_PER_MINだけ更新してデプロイする。
    "KEEPA_REFILL_PER_MIN": "5",
    "KEEPA_QUEUE_DEPTH": "10",
    "KEEPA_QUEUE_TIMEOUT_MS": "8000"
```

- [ ] **Step 6: テストが通ることを確認**

Run: `cd server && node --test test/keepa-throttle-do.test.js && npm test`
Expected: 全件PASS

- [ ] **Step 7: コミット**

```bash
git add server/src/keepaThrottleDurableObject.js server/src/worker.js server/wrangler.jsonc server/test/keepa-throttle-do.test.js
git commit -m "KeepaThrottleDOを追加しWorkersバインディングを配線

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: ルートへの組み込み（/api/search・/api/graph-data）

**Files:**
- Modify: `server/src/routes.js`
- Test: `server/test/keepa-throttle-routes.test.js`

**Interfaces:**
- Consumes: Task 1の `acquire`/`reportTokensLeft`/`reportExhausted`、既存の `resolveKeepaApiKey(headers)`・`isProRequest(headers)`・`deviceQuota.tryConsume`
- Produces: 429レスポンス `{ error: "keepa_busy", message: "混み合っているので時間を空けてお試しください。" }`（iOS側Task 4が依存）。テスト用エクスポート `router.hasByoKeepaKey`

**重要な仕様（設計書§2.2）:**
- キュー許可を得てから無料枠ユニットを消費する順序にする（拒否時にユニットを失わせない）
- BYOキー（`X-Keepa-Key` 非空）はスロットルを通さない
- キャッシュヒットはスロットルを通さない（既存のキャッシュ判定より後に acquire を置く）
- Keepaが `keepa_tokens_exhausted` を返したら `reportExhausted()` して同じ `keepa_busy`(429) を返す

- [ ] **Step 1: 失敗するテストを書く**

`server/test/keepa-throttle-routes.test.js` を新規作成。既存の `keepa.test.js` にあるルートテストの作法（`http.createServer(routes.handler())` を立て、`global.fetch` をモックし、`t.after` で復元）に合わせる。まず既存の作法を確認してから書くこと:

確認コマンド: `grep -n "createServer\|global.fetch\|listen(0" server/test/keepa.test.js | head -20`

テスト内容（作法確認後、以下の4ケースを既存流儀で実装する）:

```js
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const http = require('http');

const routes = require('../src/routes');
const keepaThrottle = require('../src/keepaThrottle');
const deviceQuota = require('../src/deviceQuota');

/** テスト用サーバーを立ててbase URLを返す(既存keepa.test.jsと同じ方式に合わせる)。 */
function startServer(t) {
  const server = http.createServer(routes.handler());
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      t.after(() => server.close());
      resolve(`http://127.0.0.1:${server.address().port}`);
    });
  });
}

/** Keepa APIのfetchをモックする(製品1件・tokensLeft付き)。 */
function mockKeepaFetch(t, { tokensLeft = 100 } = {}) {
  const realFetch = global.fetch;
  global.fetch = async (url) => {
    if (String(url).includes('api.keepa.com/product')) {
      return new Response(
        JSON.stringify({
          tokensLeft,
          products: [{ asin: 'B000TEST01', title: 'テスト商品', csv: [] }],
        }),
        { status: 200 }
      );
    }
    throw new Error(`unexpected fetch: ${url}`);
  };
  t.after(() => { global.fetch = realFetch; });
}

function throttleEnv(t, overrides) {
  const saved = { ...process.env };
  Object.assign(process.env, overrides);
  keepaThrottle._resetForTest();
  t.after(() => {
    process.env = saved;
    keepaThrottle._resetForTest();
  });
}

test('/api/graph-data: スロットル拒否(depth=0,残量0)は429 keepa_busyで、指定文言を返す', async (t) => {
  process.env.KEEPA_API_KEY = 'shared-key';
  t.after(() => delete process.env.KEEPA_API_KEY);
  throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_QUEUE_DEPTH: '0', KEEPA_REFILL_PER_MIN: '1' });
  await keepaThrottle.reportTokensLeft(0); // 枯渇状態を作る

  const base = await startServer(t);
  const res = await fetch(`${base}/api/graph-data?asin=B000THROTTLE1`, {
    headers: { 'X-App-Plan': 'pro', 'X-Device-Id': 'dev-throttle-1' },
  });
  assert.equal(res.status, 429);
  const body = await res.json();
  assert.equal(body.error, 'keepa_busy');
  assert.equal(body.message, '混み合っているので時間を空けてお試しください。');
});

test('/api/search: スロットル拒否時は無料枠ユニットを消費しない', async (t) => {
  process.env.KEEPA_API_KEY = 'shared-key';
  t.after(() => delete process.env.KEEPA_API_KEY);
  throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_QUEUE_DEPTH: '0', KEEPA_REFILL_PER_MIN: '1' });
  await keepaThrottle.reportTokensLeft(0);

  const base = await startServer(t);
  const deviceId = `dev-no-consume-${Date.now()}`;
  const res = await fetch(`${base}/api/search?code=9784873119045`, {
    headers: { 'X-App-Plan': 'free', 'X-Device-Id': deviceId },
  });
  assert.equal(res.status, 429);
  assert.equal((await res.json()).error, 'keepa_busy');

  // 拒否されたのにユニットが減っていないこと(設計書§2.2の受け入れ条件)
  const state = await deviceQuota.getState(deviceId);
  assert.equal(state.unitsUsed, 0);
});

test('/api/search: BYOキー(X-Keepa-Key)はスロットル枯渇中でも素通しされる', async (t) => {
  delete process.env.KEEPA_API_KEY; // 共有キー無し=BYOのみで動くことも同時に確認
  throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_QUEUE_DEPTH: '0', KEEPA_REFILL_PER_MIN: '1' });
  await keepaThrottle.reportTokensLeft(0); // 共有側は枯渇状態
  mockKeepaFetch(t, { tokensLeft: 50 });

  const base = await startServer(t);
  const res = await fetch(`${base}/api/search?code=9784873119045`, {
    headers: { 'X-App-Plan': 'pro', 'X-Device-Id': 'dev-byo-1', 'X-Keepa-Key': 'my-own-key' },
  });
  assert.equal(res.status, 200); // 枯渇の影響を受けない
});

test('/api/graph-data: 成功時はtokensLeftがスロットルへ報告される', async (t) => {
  process.env.KEEPA_API_KEY = 'shared-key';
  t.after(() => delete process.env.KEEPA_API_KEY);
  // 容量10・報告でtokensLeft=0になる → 次のacquireが拒否されることで「報告された」ことを検証
  throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_QUEUE_DEPTH: '0', KEEPA_REFILL_PER_MIN: '1' });
  mockKeepaFetch(t, { tokensLeft: 0 });

  const base = await startServer(t);
  const first = await fetch(`${base}/api/graph-data?asin=B000REPORT01`, {
    headers: { 'X-App-Plan': 'pro', 'X-Device-Id': 'dev-report-1' },
  });
  assert.equal(first.status, 200);

  const second = await fetch(`${base}/api/graph-data?asin=B000REPORT02`, {
    headers: { 'X-App-Plan': 'pro', 'X-Device-Id': 'dev-report-1' },
  });
  assert.equal(second.status, 429);
  assert.equal((await second.json()).error, 'keepa_busy');
});
```

注意: `graphDataCache`/`searchCache` は共有シングルトンのため、テストごとにASIN/コードを変えてキャッシュヒットを避けている。既存テストがキャッシュをクリアするヘルパを持っているならそれに合わせること（確認: `grep -n "graphDataCache\|searchCache" server/test/keepa.test.js | head`）。

- [ ] **Step 2: テストが失敗することを確認**

Run: `cd server && node --test test/keepa-throttle-routes.test.js`
Expected: FAIL（429ではなく200/503が返る）

- [ ] **Step 3: routes.jsへ組み込む**

`server/src/routes.js` の変更点（5箇所）:

(a) 冒頭のrequire群へ追加:

```js
const keepaThrottle = require('./keepaThrottle');
```

(b) `resolveKeepaApiKey` の直後にヘルパを追加:

```js
/** BYO Keepaキー(X-Keepa-Key)が付いたリクエストか。BYOは本人の枠を使うためスロットル対象外。 */
function hasByoKeepaKey(headers) {
  const headerKey = headers && (headers['x-keepa-key'] || headers['X-Keepa-Key']);
  return Boolean(headerKey && String(headerKey).trim());
}

/** キュー拒否・Keepa枯渇時の共通レスポンス(設計書§2.1。文言は正確にこの通りとする)。 */
const KEEPA_BUSY_MESSAGE = '混み合っているので時間を空けてお試しください。';
function sendKeepaBusy(res) {
  return res.status(429).json({ error: 'keepa_busy', message: KEEPA_BUSY_MESSAGE });
}

/**
 * 共有Keepaキーを使う直前の通行許可。BYOキーはスロットル外(即許可)。
 * 待ち行列はkeepaThrottle(DO)側が持ち、この呼び出しは許可が出るか
 * 拒否(深さ超過/タイムアウト)が確定するまで解決しない。
 */
async function acquireKeepaSlot(headers) {
  if (hasByoKeepaKey(headers)) return { allowed: true };
  return keepaThrottle.acquire(isProRequest(headers) ? 'pro' : 'free');
}
```

(c) `/api/search` のKeepa経路: 現在の構造は「`if (!isPro) { cached判定 → willCallKeepa判定 → tryConsume → handleSearchViaKeepa }` / Proは `cached判定 → handleSearchViaKeepa`」。**acquireをtryConsumeより前・cached判定より後**に入れる。具体的には:

無料側（`if (willCallKeepa) {` ブロックの先頭、`tryConsume` の直前）へ挿入:

```js
      if (willCallKeepa) {
        // 共有Keepaキーの通行許可を先に取る。拒否時にユニットを消費しない順序が重要
        // (設計書§2.2: 「エラーになったのに枠だけ減った」を作らない)。
        const slot = await acquireKeepaSlot(req.headers);
        if (!slot.allowed) return sendKeepaBusy(res);

        const consumeResult = await deviceQuota.tryConsume(deviceId, 1);
        // (既存のまま)
```

Pro側（`if (cached) return res.json(cached);` の直後、`return handleSearchViaKeepa(...)` の直前）へ挿入:

```js
    if (cached) return res.json(cached);
    const slot = await acquireKeepaSlot(req.headers);
    if (!slot.allowed) return sendKeepaBusy(res);
    return handleSearchViaKeepa(req, res, code, cacheKey, keepaApiKey);
```

(d) `/api/graph-data`: キャッシュヒット返却の後・`tryConsume` の前へ挿入:

```js
  // 共有Keepaキーの通行許可(キャッシュヒット時は不要なのでこの位置)。
  // 無料枠ユニットの消費より前に取る(拒否時にユニットを失わせないため)。
  const slot = await acquireKeepaSlot(req.headers);
  if (!slot.allowed) return sendKeepaBusy(res);

  if (!isPro) {
    // (既存のtryConsumeブロックはそのまま)
```

(e) tokensLeft報告と枯渇時の応答変更:

`handleSearchViaKeepa` 内の `const { product } = await keepa.getProduct({ code: janOrIsbn, history: 1, apiKey });` を次に変更:

```js
    const { product, tokensLeft } = await keepa.getProduct({ code: janOrIsbn, history: 1, apiKey });
    // 共有キーのときだけ実残量をスロットルへ報告する(BYOキーの残量で共有側の推定を
    // 壊さないようにする)。報告は補正であり本処理の成否に影響させない。
    if (!hasByoKeepaKey(req.headers) && Number.isFinite(tokensLeft)) {
      await keepaThrottle.reportTokensLeft(tokensLeft);
    }
```

同関数のcatch節にある `keepa_tokens_exhausted` 分岐（現在503を返している箇所。確認: `grep -n "keepa_tokens_exhausted" server/src/routes.js`）を次に変更:

```js
    if (err.code === 'keepa_tokens_exhausted') {
      // 推定より実残量が少なかった稀なケース。残量0へ補正し、ユーザーには
      // キュー拒否と同じ文言で返す(体験を1種類に揃える。設計書§2.1)。
      if (!hasByoKeepaKey(req.headers)) await keepaThrottle.reportExhausted();
      return sendKeepaBusy(res);
    }
```

`/api/graph-data` の `keepa.getProduct` 呼び出しとcatch節の `keepa_tokens_exhausted` 分岐にも同じ変更を適用する（graph-data側も `const { product, tokensLeft } = ...` に変え、報告→503を`sendKeepaBusy`へ）。

(f) テスト用エクスポート（ファイル末尾の既存エクスポート群へ追加）:

```js
// テスト用途にBYOキー判定を公開する。
router.hasByoKeepaKey = hasByoKeepaKey;
```

- [ ] **Step 4: テストが通ることを確認**

Run: `cd server && node --test test/keepa-throttle-routes.test.js && npm test`
Expected: 全件PASS。**既存の keepa.test.js に「503 keepa_tokens_exhausted」を期待するテストがあれば429 keepa_busyへ更新する**（確認: `grep -n "keepa_tokens_exhausted" server/test/*.test.js`）

- [ ] **Step 5: コミット**

```bash
git add server/src/routes.js server/test/keepa-throttle-routes.test.js server/test/keepa.test.js
git commit -m "検索・グラフのKeepa経路にスロットルを組み込み、429 keepa_busyで応答

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: iOS — keepa_busyエラーの判別（APIClient）

**Files:**
- Modify: `ios/BarcodeSedori/Sources/API/APIClient.swift`

**Interfaces:**
- Consumes: Task 3のレスポンス（429 + `error: "keepa_busy"` + `message`）
- Produces: `APIClientError.keepaBusy(message: String?)`（Task 5・6が `if case` で判別する）

- [ ] **Step 1: エラーケースを追加**

`APIClientError` enumへ追加（`quotaExceeded` の直後）:

```swift
    /// Keepa混雑(HTTP 429, error=="keepa_busy")。共有Keepaキーのキューがあふれた/待ちがタイムアウトした。
    /// messageはサーバーが返す文言(「混み合っているので時間を空けてお試しください。」)。
    case keepaBusy(message: String?)
```

`errorDescription` のswitchへ追加:

```swift
        case .keepaBusy(let message):
            return message ?? "混み合っているので時間を空けてお試しください。"
```

- [ ] **Step 2: デコード分岐を追加**

`perform` 内の既存429判定（`quotaBody.error == "quota_exceeded"` のifブロック。行番号目安: 173-176）の直後へ追加。ボディの形が同じ（error/message、quotaは無いのでnilになる）ため `QuotaExceededBody` を使い回す:

```swift
            // Keepa混雑(429)。quota_exceededと同じボディ形式(quotaフィールドは無し=nil)のため
            // QuotaExceededBodyを使い回してデコードする。
            if httpResponse.statusCode == 429,
               let busyBody = try? decoder.decode(QuotaExceededBody.self, from: data),
               busyBody.error == "keepa_busy" {
                throw APIClientError.keepaBusy(message: busyBody.message)
            }
```

- [ ] **Step 3: ビルド確認**

「iOSビルド手順」（本文書末尾）どおりにビルド。
Expected: BUILD SUCCEEDED

- [ ] **Step 4: コミット**

```bash
git add ios/BarcodeSedori/Sources/API/APIClient.swift
git commit -m "APIClientにkeepa_busy(429)の判別を追加

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: iOS — 検索の混雑カード（再試行＋誘導）

**Files:**
- Modify: `ios/BarcodeSedori/Sources/Views/SearchTabView.swift`

**Interfaces:**
- Consumes: Task 4の `APIClientError.keepaBusy`、既存の `AppNavigation.shared.selectedTab` / `AppNavigation.settingsTab`（オファーパネルの `handlePanelTap` で使用実績あり）、`SettingsStore.shared.isSpApiLinkUsable` / `isKeepaKeyUsable`、`EntitlementStore.shared.isPro`

- [ ] **Step 1: ViewModelにstateとcatch分岐を追加**

`SearchTabViewModel` に@Publishedを追加（`searchErrorMessage` の直後）:

```swift
    /// Keepa混雑(keepa_busy)時の文言。セット時は専用の混雑カード(再試行+誘導)を出す。
    /// searchErrorMessage(汎用エラー)とは排他(どちらか一方のみセットされる)。
    @Published var keepaBusyMessage: String?
```

`handleScan` のリセット群へ追加:

```swift
        keepaBusyMessage = nil
```

`search(code:)` のcatch節、既存の `if case APIClientError.quotaExceeded` 分岐の**前**へ追加:

```swift
            if case APIClientError.keepaBusy(let message) = error {
                // 混雑は専用カード(再試行+SP-API/Keepaキー誘導)で表示する。
                // searchErrorMessage(赤文字の汎用エラー)には流さない。
                keepaBusyMessage = message ?? "混み合っているので時間を空けてお試しください。"
            } else if case APIClientError.quotaExceeded(let quota, _) = error {
```

（既存の `if case APIClientError.quotaExceeded` を `else if case` に変える）

- [ ] **Step 2: 混雑カードViewを追加**

`latestResultCard` の分岐チェーンに追加。既存の `} else if let errorMessage = viewModel.searchErrorMessage {` の**前**へ:

```swift
        } else if let busyMessage = viewModel.keepaBusyMessage {
            keepaBusyCard(message: busyMessage)
```

`SearchTabView` に新しいprivate関数を追加（`freeAdArea` の近く）:

```swift
    /// Keepa混雑(keepa_busy)時のカード。再試行と、混雑を回避できる連携への誘導を出す
    /// (混雑を連携・課金の入口に変える。設計書§2.3)。
    private func keepaBusyCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.orange)
                Text(message)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }

            Button {
                // 再スキャン不要で同じコードを再検索する。startSearch(カメラ用クールダウン)は
                // 通さない(混雑待ちからの再試行にスキャン間隔の制限を重ねる意味が無いため)。
                if let code = viewModel.latestScannedCode {
                    viewModel.handleScan(code)
                }
            } label: {
                Label("再試行", systemImage: "arrow.clockwise")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)

            // 誘導: 未連携ならSP-API連携、Pro(連携済み)でBYOキー未設定ならKeepaキー設定。
            if !settings.isSpApiLinkUsable {
                Button {
                    AppNavigation.shared.selectedTab = AppNavigation.settingsTab
                } label: {
                    Text("Amazon連携なら自分の枠で待たずに検索できます →")
                        .font(.footnote)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            } else if entitlements.isPro && !settings.isKeepaKeyUsable {
                Button {
                    AppNavigation.shared.selectedTab = AppNavigation.settingsTab
                } label: {
                    Text("Keepa APIキーを設定するとグラフも自分の枠で取得できます →")
                        .font(.footnote)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }
```

- [ ] **Step 3: ビルド確認**

「iOSビルド手順」どおりにビルド。
Expected: BUILD SUCCEEDED

- [ ] **Step 4: シミュレータで表示確認**

一時検証（コミットしない変更）: `latestResultCard` の分岐を一時的に `} else if let busyMessage = viewModel.keepaBusyMessage ?? "混み合っているので時間を空けてお試しください。" {` のように強制するのではなく、`SearchTabViewModel.handleScan` 冒頭に一時行 `keepaBusyMessage = "混み合っているので時間を空けてお試しください。"; return` を入れてビルド→起動（`-debugSearchCode 9784873119045 -debugForcePro YES`）→スクリーンショットでカード（文言・再試行・誘導リンク）を確認→**一時行を削除して再ビルド**。

- [ ] **Step 5: コミット**

```bash
git add ios/BarcodeSedori/Sources/Views/SearchTabView.swift
git commit -m "検索のKeepa混雑時に再試行+連携誘導の専用カードを表示

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: iOS — グラフの混雑文言出し分け

**Files:**
- Modify: `ios/BarcodeSedori/Sources/Views/PriceHistoryChartView.swift`

**Interfaces:**
- Consumes: Task 4の `APIClientError.keepaBusy`。既存の `failureView`（「グラフを一時的に取得できません」＋タップ再読込 `retryToken`）

- [ ] **Step 1: 混雑文言のstateを追加し、load()で捕捉**

`@State private var loadFailed = false` の直後へ追加:

```swift
    /// 失敗理由がKeepa混雑(keepa_busy)のときのサーバー文言。nilなら汎用の失敗文言を出す。
    @State private var busyMessage: String?
```

`load()` 内の状態リセット（`graphData = nil` / `loadFailed = false` の箇所）へ追加:

```swift
        busyMessage = nil
```

`load()` のcatch節（`loadFailed = true` している箇所）を変更:

```swift
        } catch {
            // (既存のquotaExceeded処理はそのまま)
            if case APIClientError.keepaBusy(let message) = error {
                busyMessage = message ?? "混み合っているので時間を空けてお試しください。"
            }
            loadFailed = true
        }
```

- [ ] **Step 2: failureViewの文言を出し分け**

`failureView` の `Text("グラフを一時的に取得できません")` を変更:

```swift
            Text(busyMessage ?? "グラフを一時的に取得できません")
```

（「タップして再読み込み」と `retryToken += 1` の既存動作はそのまま流用）

- [ ] **Step 3: ビルド確認・コミット**

「iOSビルド手順」どおりにビルド → BUILD SUCCEEDED を確認。

```bash
git add ios/BarcodeSedori/Sources/Views/PriceHistoryChartView.swift
git commit -m "グラフ失敗表示にKeepa混雑の文言出し分けを追加

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: デプロイと本番確認

**Files:** なし（運用作業）

- [ ] **Step 1: 全テスト最終確認**

Run: `cd server && npm test`
Expected: 全件PASS

- [ ] **Step 2: デプロイ**

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)/server" && npm run deploy:cf
```

Expected: `Deployed barcode-sedori-api triggers` と新しいVersion ID。migrations v2（KeepaThrottleDO）が適用される。

- [ ] **Step 3: 本番の疎通確認**

```bash
# 正常系: 通常の検索が今までどおり通る(スロットルは残量ありなので素通り)
curl -s -o /dev/null -w "search: %{http_code}\n" "https://api.sellira.jp/api/search?code=9784873119045" -H "X-App-Plan: pro" -H "X-Device-Id: deploy-check"
curl -s -o /dev/null -w "graph: %{http_code}\n" "https://api.sellira.jp/api/graph-data?asin=4873119049" -H "X-App-Plan: pro" -H "X-Device-Id: deploy-check"
```

Expected: どちらも200（デプロイ直後はエッジ伝播で404が出ることがある。1分待って再実行）

注意: 本番でkeepa_busy(429)を意図的に起こす検証は行わない（共有バケットを実際に枯らす必要があり有害）。拒否経路はTask 3のテストで担保済み。

- [ ] **Step 4: 設計書のステータス更新とコミット**

`docs/superpowers/specs/2026-08-02-keepa-token-depletion-design.md` の冒頭ステータスを
`**設計承認済み（実装前）**` → `**Phase 1実装済み（2026-08-02）**` に変更。

```bash
git add docs/superpowers/specs/2026-08-02-keepa-token-depletion-design.md
git commit -m "Keepaスロットル設計書のステータスをPhase 1実装済みへ更新

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 5: ユーザーへの報告事項**

- Phase 0（Keepaプランを20トークン/分へアップグレード）はユーザー作業。完了したら `wrangler.jsonc` の `KEEPA_REFILL_PER_MIN` を `"20"` に変えて再デプロイする
- 現在は5トークン/分のままでも動作する（キューの効きが弱いだけ）

---

## iOSビルド手順（各iOSタスク共通）

```bash
APP="/Users/yuyads/Library/Developer/Xcode/DerivedData/BarcodeSedori-ahciwpatrvclvyehurordjakqhou/Build/Products/Debug-iphonesimulator/BarcodeSedori.app"
rm -rf "$APP"   # 増分ビルドのリンクスキップ・署名壊れを避けるため必ずバンドルごと消す
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)/ios/BarcodeSedori" && xcodebuild -project BarcodeSedori.xcodeproj -scheme BarcodeSedori -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' -configuration Debug build 2>&1 | grep -E "error:|BUILD" | head
# シミュレータへ入れる場合は再署名してからインストールする
for f in "$APP/__preview.dylib" "$APP/BarcodeSedori.debug.dylib" "$APP"; do codesign -f -s - "$f" >/dev/null 2>&1; done
xcrun simctl terminate booted com.example.barcodesedori 2>/dev/null
xcrun simctl install booted "$APP"
xcrun simctl launch booted com.example.barcodesedori -debugForcePro YES -debugSearchCode 9784873119045
```

スクリーンショット確認は `mcp__Claude_Code_iOS_Simulator__control` の screenshot。タップ/スワイプ座標は**ポイント（375x667）**指定（画像は2倍ピクセルなので座標は半分にする）。
