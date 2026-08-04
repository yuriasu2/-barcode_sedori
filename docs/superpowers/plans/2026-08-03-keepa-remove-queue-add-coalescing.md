# Keepaスロットル: 枯渇時キューの撤去とリクエスト・コアレッシング導入 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 枯渇時にリクエストを最大6秒待たせる優先度付きキュー機構を撤去し、代わりに同一商品への同時リクエストをまとめる「リクエスト・コアレッシング」を導入する。適応ブレーキとPro優先度・load shedding(即時拒否)は維持する。

**Architecture:** `ThrottleCore`(`server/src/keepaThrottle.js`)からキュー(`proQueue`/`freeQueue`/`scheduleGrant`/`grantTick`)を削除し、`acquire()`を「即時許可 or 即時拒否」の2択に単純化する。適応ブレーキの上限をキュー待ち予算(`KEEPA_QUEUE_TIMEOUT_MS`)から独立した固定値に付け替える。新規モジュール`server/src/keepaCoalesce.js`がWorker isolate内でのkey単位のin-flight Promise共有(single-flight)を提供し、`routes.js`の`/api/search`・`/api/graph-data`のKeepa共有キー呼び出し(スロットル許可+実際のKeepa API呼び出し)をこれで束ねる。同時に届いた同一商品への複数リクエストは、実際には1回だけKeepaを呼び、結果を全員で共有する。

**Tech Stack:** Node.js(`node --test`)、Cloudflare Workers/Durable Objects、Swift/SwiftUI(iOS)。

## Global Constraints

- 拒否時のユーザー向け文言は変更しない: `混み合っているので時間を空けてお試しください。`(429 `keepa_busy`)。
- BYO Keepaキー(`X-Keepa-Key`)はスロットル対象外のまま(変更しない)。
- デモインスタンス(`'demo'`)と本番共有インスタンス(`'global'`)の隔離は絶対に崩さない(コアレッシングのキーにも`instance`を含めること)。
- iOSの通信タイムアウトは`APIClient.swift`の`timeoutInterval = 10`秒のまま(変更しない)。サーバー側の追加待ち時間(適応ブレーキ)はこれより十分短く保つこと。
- 既存の無料枠ユニット消費順序の原則(「拒否された処理にユニットを消費させない」)を維持する。
  加えて、コアレッシング導入で「Keepa呼び出し」がユニット消費より前に来るため、**非Proは
  Keepa呼び出しの前に残ユニットの事前チェック(`deviceQuota.computeQuota`、消費はしない)を行い、
  残0なら`quota_exceeded`で早期リターンする**こと。これが無いと「枠切れユーザーのリクエストで
  Keepaトークンだけ消費される」経路が生まれる(実消費は従来どおり成功後の`tryConsume`で行う)。
- 各タスックのステップ完了ごとに`cd server && npm test`(または該当ファイルのみ)を実行し、既存テストを壊していないことを確認してからコミットする。

---

## 背景(実装者向け補足)

現行の`server/src/keepaThrottle.js`の`ThrottleCore.acquire()`は、残量(トークン)が無いとき最大`KEEPA_QUEUE_TIMEOUT_MS`(既定6,000ms)だけ`proQueue`/`freeQueue`で待たせ、`KEEPA_QUEUE_DEPTH`(既定10)を超えたら即座に拒否する、という優先度付き待ち行列だった。

本番検証の結果、以下2つの理由でこのキュー機構を廃止することが決まった(ユーザーとの会話で合意済み。設計相談はこの計画のTask 8で設計書に追記する):

1. 現行の契約プラン(5トークン/分=12秒に1個)では、6秒のキュー待ちでトークンが補充される見込みが薄く、「6秒待たされた末に同じ拒否」になりがちでUX上ほぼ無意味。
2. 本番検証で、キューを補充ペースに合わせて自動的に流す`scheduleGrant`/`grantTick`の自己タイマーが、実際のCloudflare Durable Objects環境で信頼できるタイミングで発火しないことが判明した(新しい別リクエストが来た時にだけ間接的に流れる)。

キュー撤去の代わりに、多人数同時アクセス対策として「リクエスト・コアレッシング」(同一商品への同時リクエストを1回のKeepa呼び出しにまとめる)を新規導入する。これは旧企画書`KEEPA-TOKEN-PLAN.md`のPhase2-7で「不採用」とされていたが、キュー撤去に伴い採用へ変更する。

適応ブレーキ(消費速度に応じた予防的な遅延。`computeBrakeMs`)と、Pro優先(ブレーキの安全圏がPro=2分/free=10分で異なる)、load shedding(残量が無ければ即座に拒否)は**維持する**。

---

## Task 1: ThrottleCoreからキューを撤去し、適応ブレーキの上限を独立させる

**Files:**
- Modify: `server/src/keepaThrottle.js`
- Test: `server/test/keepa-throttle.test.js`

**Interfaces:**
- Produces: `ThrottleCore.acquire(priority)` は `{allowed: true}` または `{allowed: false, reason: 'exhausted'}` のみを返す(`'depth'`/`'timeout'`は廃止)。
- Produces: `readThrottleConfig(env)` は `{refillPerMin, capacity}` のみを返す(`depth`/`timeoutMs`を削除)。
- Produces: `ThrottleCore.debugSnapshot(now)` は `{tokensEstimate, capacity, consumeRatePerMin, refillPerMin}` のみを返す(`queueLength`/`depth`を削除)。
- Consumes: 既存の `computeBrakeMs`/`sleepForBrake`/`refill`/`peekTokens`/`recordGrant`/`pruneGrantTimestamps`/`consumeRatePerMin`/`seedDemoState`/`restoreRawState` はロジック変更なし(そのまま残す)。

- [ ] **Step 1: 失敗するテストを書く(キュー撤去後の期待動作)**

`server/test/keepa-throttle.test.js` の36-74行目(`'keepaThrottle: 枯渇するとキューに入り、補充で順に許可される'`から`'keepaThrottle: 待ちがtimeoutMsを超えると reason=timeout で拒否'`まで4テスト)を、丸ごと以下へ置き換える:

```js
test('keepaThrottle: 枯渇していれば即座に reason=exhausted で拒否される(キューに入らない)', async (t) => {
  configure(t, { capacity: 1, refillPerMin: 1 }); // 補充は1分後(間に合わない)
  assert.deepEqual(await keepaThrottle.acquire('free'), { allowed: true });
  const started = Date.now();
  const result = await keepaThrottle.acquire('free');
  assert.deepEqual(result, { allowed: false, reason: 'exhausted' });
  assert.ok(Date.now() - started < 200, `即座に拒否されていない(${Date.now() - started}ms待った)`);
});

test('keepaThrottle: 枯渇時はPro/freeどちらも同じく即座に拒否される(キューが無いので優先度は関係ない)', async (t) => {
  configure(t, { capacity: 1, refillPerMin: 1 });
  await keepaThrottle.acquire('free'); // 枯渇させる
  const [freeResult, proResult] = await Promise.all([
    keepaThrottle.acquire('free'),
    keepaThrottle.acquire('pro'),
  ]);
  assert.deepEqual(freeResult, { allowed: false, reason: 'exhausted' });
  assert.deepEqual(proResult, { allowed: false, reason: 'exhausted' });
});
```

`configure`ヘルパー(9-28行目)を、`depth`/`timeoutMs`を扱わない形へ変更する:

```js
function configure(t, { refillPerMin, capacity }) {
  const saved = {
    KEEPA_REFILL_PER_MIN: process.env.KEEPA_REFILL_PER_MIN,
    KEEPA_BUCKET_CAPACITY: process.env.KEEPA_BUCKET_CAPACITY,
  };
  if (refillPerMin !== undefined) process.env.KEEPA_REFILL_PER_MIN = String(refillPerMin);
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
```

呼び出し側の`configure(t, {...})`から`depth`/`timeoutMs`キーを全て取り除く(ファイル内の他の`configure(t, { capacity: ..., refillPerMin: ..., depth: ..., timeoutMs: ... })`呼び出し全て。30-34行目、76-87行目、117行目付近、145-152行目、154-218行目)。`new ThrottleCore({ refillPerMin: ..., capacity: ..., depth: ..., timeoutMs: ... })`という直接インスタンス化(202行目・226行目・236行目・246行目・254行目・267行目・278行目・288行目・298行目・326行目)も`{ refillPerMin: ..., capacity: ... }`のみへ変更する。

76-87行目(`reportTokensLeft`/`reportExhausted`のテスト)を以下へ置き換える(`depth: 0`前提の「キューに入れず即拒否」という説明文が変わるため):

```js
test('keepaThrottle: reportTokensLeftで推定残量が補正される', async (t) => {
  configure(t, { capacity: 10, refillPerMin: 1 });
  await keepaThrottle.reportTokensLeft(0); // 実残量0と報告
  assert.deepEqual(await keepaThrottle.acquire('free'), { allowed: false, reason: 'exhausted' });
});

test('keepaThrottle: reportExhaustedで残量0になる', async (t) => {
  configure(t, { capacity: 10, refillPerMin: 1 });
  await keepaThrottle.reportExhausted();
  assert.deepEqual(await keepaThrottle.acquire('free'), { allowed: false, reason: 'exhausted' });
});
```

121-139行目(`'keepaThrottle: reportTokensLeftの上方補正で古いgrantTimerに引きずられず即座にキューが流れる'`)は、キュー(`grantTimer`)が無くなったことで前提ごと成立しなくなるため、テストごと削除する。

191-218行目(`'keepaThrottle: 適応ブレーキ - 既定値5/分ではfloorMs(12000ms)がtimeoutMs-1秒でクランプされる'`)を、`timeoutMs`ではなく固定の`BRAKE_CAP_MS`でクランプされることを確認するテストへ置き換える:

```js
test('keepaThrottle: 適応ブレーキ - 既定値5/分ではfloorMs(12000ms)がBRAKE_CAP_MSでクランプされる', async (t) => {
  // refillPerMin=5だと素のfloorMs(60000/5=12000ms)はBRAKE_CAP_MS(4000ms)を大きく超える。
  // cap=min(floorMs, BRAKE_CAP_MS)によってブレーキが最大でも4000ms近辺でクランプされることを確認する。
  const { ThrottleCore } = keepaThrottle;
  const core = new ThrottleCore({ refillPerMin: 5, capacity: 100 });
  t.after(() => core.destroy());

  const now = Date.now();
  core.tokens = 5;
  core.lastRefillAt = now;
  for (let i = 0; i < 55; i += 1) core.grantTimestamps.push(now); // 高消費状態を再現(rate=55, net=50, tte=0.1分)

  const started = Date.now();
  const result = await core.acquire('free');
  const elapsed = Date.now() - started;

  assert.deepEqual(result, { allowed: true });
  assert.ok(elapsed >= 3000, `クランプが効きすぎて即時許可された(${elapsed}ms)`);
  assert.ok(elapsed < 4500, `BRAKE_CAP_MS(4000ms)を大きく超えて待たされた(${elapsed}ms)`);
});
```

312-319行目(`'keepaThrottle: acquire(priority, "demo")はacquire(priority)(=global省略時)と別状態'`)の`reason: 'depth'`を`reason: 'exhausted'`へ変更する:

```js
test('keepaThrottle: acquire(priority, "demo")はacquire(priority)(=global省略時)と別状態', async (t) => {
  configure(t, { capacity: 1, refillPerMin: 60 });
  assert.deepEqual(await keepaThrottle.acquire('free', 'demo'), { allowed: true });
  assert.deepEqual(await keepaThrottle.acquire('free', 'demo'), { allowed: false, reason: 'exhausted' });
  assert.deepEqual(await keepaThrottle.acquire('free'), { allowed: true });
});
```

321-343行目(`'keepaThrottle: 残量補正直後の新参acquireは、キュー内の待機者を追い越して即時許可されない'`)は、キュー(`core.queueLength()`)が無くなったことで前提ごと成立しなくなるため、テストごと削除する。

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `cd server && node --test test/keepa-throttle.test.js`
Expected: FAIL(`queueLength is not a function`、または`reason`の不一致など。まだ実装を変更していないため)

- [ ] **Step 3: ThrottleCoreを実装する**

`server/src/keepaThrottle.js`を以下のとおり変更する。

`readThrottleConfig`(27-39行目)を置き換える:

```js
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
  };
}
```

`BRAKE_SAFE_TTE_MIN_FREE`/`BRAKE_SAFE_TTE_MIN_PRO`/`BRAKE_WINDOW_MS`の定数群(41-47行目)の直後に、新しい定数を追加する:

```js
// 適応ブレーキの遅延上限(ms)。キュー撤去に伴い、KEEPA_QUEUE_TIMEOUT_MS(廃止)から独立させた
// 固定値。iOSの通信タイムアウト(APIClient.swiftのtimeoutInterval=10秒)に対し、実際のKeepa
// API呼び出し(数百ms〜1-2秒程度)+DNS/TLS/Cloudflareルーティングのオーバーヘッド分の余裕を
// 十分残す必要がある。4000msなら残り6秒の余裕があり、キュー撤去前(6000msの待ち"の後に"
// Keepa呼び出しが乗っていた)より総待ち時間は短くなる。コード内定数とする(環境変数化しない。YAGNI)。
const BRAKE_CAP_MS = 4000;
```

`ThrottleCore`のコンストラクタ(57-75行目)から`proQueue`/`freeQueue`/`grantTimer`を削除する:

```js
class ThrottleCore {
  constructor(config) {
    this.config = config;
    this.tokens = config.capacity; // 起動直後は満タンと仮定(最初のreportで補正される)
    this.lastRefillAt = Date.now();
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
```

`freshStats()`(77-90行目)を置き換える:

```js
  freshStats() {
    return {
      date: new Date().toISOString().slice(0, 10),
      granted: 0,
      shedExhausted: 0,
      braked: 0,
      lastTokensLeft: null,
      // 直近のconsumeRatePerMin(設計書§2.6)。logShed時に計算した値を格納するのみ
      // (判定には使わない。ログ・観測用)。
      consumeRatePerMin: 0,
    };
  }
```

`queueLength()`(119-121行目)を削除する。

`computeBrakeMs`(143-169行目)の`floorMs`/`cap`計算部分(160-168行目)を置き換える:

```js
    // floorMs=補充間隔(補充と同速まで遅延させれば、そこで消費≦補充となり均衡する)。
    // capはBRAKE_CAP_MSで頭打ちにする(キュー撤去によりKEEPA_QUEUE_TIMEOUT_MSへの依存が
    // 無くなったため、固定の安全上限を使う)。
    const floorMs = 60000 / this.config.refillPerMin;
    const cap = Math.min(floorMs, BRAKE_CAP_MS);
    return Math.round(Math.min(cap, cap * (1 - tteMin / safeMin)));
  }
```

`acquire(priority)`(189-258行目)を丸ごと置き換える:

```js
  /**
   * トークン1個の通行許可を求める。キューは無い: 即時許可 or 即時拒否のみ。
   * @param {'pro'|'free'} priority
   * @returns {Promise<{allowed: boolean, reason?: 'exhausted'}>}
   */
  async acquire(priority) {
    this.rollStatsDate();
    let now = Date.now();
    this.refill(now);

    // 適応ブレーキ(設計書§2.6): 即時許可できる状況でも、消費速度が枯渇へ向かっている
    // 場合は補充間隔を上限に遅延を入れる。1回のacquireにつき最大1回だけ適用する。
    if (this.tokens >= 1) {
      const brakeMs = this.computeBrakeMs(priority, now);
      if (brakeMs > 0) {
        this.stats.braked += 1;
        const completedNormally = await this.sleepForBrake(brakeMs);
        if (!completedNormally) {
          // destroy()による強制解除。テストがぶら下がらないよう即座に拒否で返す。
          return { allowed: false, reason: 'exhausted' };
        }
        now = Date.now();
        this.refill(now);
      }
    }

    if (this.tokens >= 1) {
      this.tokens -= 1;
      this.recordGrant(now);
      this.stats.granted += 1;
      return { allowed: true };
    }

    this.stats.shedExhausted += 1;
    this.logShed();
    return { allowed: false, reason: 'exhausted' };
  }
```

`removeWaiter`/`scheduleGrant`/`grantTick`(260-294行目)を丸ごと削除する。

`reportTokensLeft`/`reportExhausted`/`reflowQueueAfterCorrection`(296-326行目)を置き換える(`reflowQueueAfterCorrection`は削除し、呼び出しも削る):

```js
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
```

`debugSnapshot`(328-342行目)を置き換える:

```js
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
    };
  }
```

`logShed(kind)`(344-351行目)を置き換える(引数を削り、キュー関連の出力を削る):

```js
  /** shedding発生時の構造化ログ(wrangler tailで確認する。設計書§2.4)。直近消費レートも出す(§2.6)。 */
  logShed() {
    const rate = this.consumeRatePerMin(Date.now());
    this.stats.consumeRatePerMin = rate;
    console.log(`[keepaThrottle] shed reason=exhausted rate=${rate} stats=${JSON.stringify(this.stats)}`);
  }
```

`destroy()`(404-420行目)を置き換える(キューの解放処理を削る):

```js
  /** テスト用: 保留中のタイマーを全て破棄し、ブレーキ待ちはallowed:falseで解決する。 */
  destroy() {
    // ブレーキ待ち(sleep)中のacquireも、destroy中に取り残されないよう強制解除する。
    for (const entry of this.brakeWaiters) {
      clearTimeout(entry.timer);
      entry.resolve();
    }
    this.brakeWaiters.clear();
  }
```

- [ ] **Step 4: テストを実行して成功を確認する**

Run: `cd server && node --test test/keepa-throttle.test.js`
Expected: PASS(全テスト)

- [ ] **Step 5: サーバー全体のテストを実行し、他ファイルの破壊が無いことを確認する**

Run: `cd server && npm test`
Expected: `keepa-throttle-do.test.js`と`keepa-throttle-routes.test.js`は次のTaskで直すため、この時点ではFAILしてよい(Task 1の対象は`keepa-throttle.test.js`のみ)。`keepa.test.js`など無関係なファイルはPASSすることを確認する。

- [ ] **Step 6: コミット**

```bash
cd server && git add src/keepaThrottle.js test/keepa-throttle.test.js
git commit -m "Keepaスロットルのキュー機構を撤去し、適応ブレーキの上限を独立させる

枯渇時は即座にreason=exhaustedで拒否する(キューに入れて最大6秒待たせない)。
理由: 現行5トークン/分だと6秒の待ちでは補充が間に合わずUX上ほぼ無意味なうえ、
本番検証でキューの自己タイマー(scheduleGrant/grantTick)がCloudflare Durable
Objects環境で信頼できるタイミングで発火しないことが判明したため。適応ブレーキ・
Pro優先(ブレーキの安全圏の違い)・load sheddingは維持する。"
```

---

## Task 2: wrangler.jsonc からキュー関連の環境変数を削除する

**Files:**
- Modify: `server/wrangler.jsonc`

**Interfaces:**
- Consumes: なし(Task 1で`readThrottleConfig`が`KEEPA_QUEUE_DEPTH`/`KEEPA_QUEUE_TIMEOUT_MS`を読まなくなったことを前提に、値そのものを削除する)。

- [ ] **Step 1: 環境変数を削除する**

`server/wrangler.jsonc`の16-38行目を以下へ置き換える:

```jsonc
  "vars": {
    // 秘密ではない公開識別子。コード側にも同じ既定値があるが意図を明示するため置く。
    "MARKETPLACE_ID": "A1VC38T7YXB528",
    "SPAPI_ENDPOINT": "https://sellingpartnerapi-fe.amazon.com",
    // 無料枠ユニットモデル(deviceQuota.js)。
    // 基本の1日あたりユニット数 / 広告視聴1本あたりの付与ユニット数 / 1日の上限(cap)。
    "BASE_DAILY_UNITS": "5",
    "UNITS_PER_AD": "5",
    "MAX_DAILY_UNITS": "100",
    // Keepaスロットル(keepaThrottle.js)。契約プランの毎分トークン数。
    // 枯渇時に待たせるキューは撤去済み(2026-08-03)なので、キュー深さ/タイムアウトの
    // 環境変数は無い。適応ブレーキの上限はコード内定数(BRAKE_CAP_MS)。
    // プランを20トークン/分へ上げたらここだけ更新してデプロイする。
    "KEEPA_REFILL_PER_MIN": "5"
  },
```

- [ ] **Step 2: 変更を確認する**

Run: `cd server && cat wrangler.jsonc | head -40`
Expected: `KEEPA_QUEUE_DEPTH`/`KEEPA_QUEUE_TIMEOUT_MS`が出力に含まれない

- [ ] **Step 3: コミット**

```bash
cd server && git add wrangler.jsonc
git commit -m "wrangler.jsoncからキュー関連の環境変数(KEEPA_QUEUE_DEPTH/KEEPA_QUEUE_TIMEOUT_MS)を削除"
```

---

## Task 3: keepa-throttle-do.test.js の reason 期待値を更新する

**Files:**
- Modify: `server/test/keepa-throttle-do.test.js`

**Interfaces:**
- Consumes: Task 1で変更した`ThrottleCore.acquire`の戻り値(`reason: 'exhausted'`)。

- [ ] **Step 1: reason期待値を書き換える**

`server/test/keepa-throttle-do.test.js`の45行目・56行目・77行目・101行目にある`{ allowed: false, reason: 'depth' }`を、すべて`{ allowed: false, reason: 'exhausted' }`へ変更する。

- [ ] **Step 2: テストを実行して成功を確認する**

Run: `cd server && node --test test/keepa-throttle-do.test.js`
Expected: PASS(全7テスト)

- [ ] **Step 3: コミット**

```bash
cd server && git add test/keepa-throttle-do.test.js
git commit -m "DOテストの拒否理由(reason)期待値をdepth→exhaustedへ更新(キュー撤去に追随)"
```

---

## Task 4: リクエスト・コアレッシング用モジュールを新規作成する

**Files:**
- Create: `server/src/keepaCoalesce.js`
- Test: `server/test/keepa-coalesce.test.js`

**Interfaces:**
- Produces: `coalesce(key, fn)` — `key`に対応する呼び出しが進行中ならその結果を共有するPromiseを返す。無ければ`fn()`を呼んで登録する。
- Produces: `_resetForTest()` — テスト用、in-flight登録を全クリアする。
- Produces: `_inFlightCountForTest()` — テスト用、現在in-flightのkey数を返す。

- [ ] **Step 1: 失敗するテストを書く**

`server/test/keepa-coalesce.test.js`を新規作成する:

```js
'use strict';

const test = require('node:test');
const assert = require('node:assert');

const keepaCoalesce = require('../src/keepaCoalesce');

test.beforeEach(() => keepaCoalesce._resetForTest());

test('coalesce: 同じkeyへの同時呼び出しはfnを1回しか実行しない', async () => {
  let callCount = 0;
  const fn = async () => {
    callCount += 1;
    await new Promise((r) => setTimeout(r, 20));
    return 'result';
  };

  const [a, b, c] = await Promise.all([
    keepaCoalesce.coalesce('key-1', fn),
    keepaCoalesce.coalesce('key-1', fn),
    keepaCoalesce.coalesce('key-1', fn),
  ]);

  assert.equal(callCount, 1, 'fnは1回だけ呼ばれるべき');
  assert.equal(a, 'result');
  assert.equal(b, 'result');
  assert.equal(c, 'result');
});

test('coalesce: 異なるkeyは束ねられず、それぞれfnが呼ばれる', async () => {
  let callCount = 0;
  const fn = async () => {
    callCount += 1;
    return callCount;
  };

  const [a, b] = await Promise.all([
    keepaCoalesce.coalesce('key-a', fn),
    keepaCoalesce.coalesce('key-b', fn),
  ]);

  assert.equal(callCount, 2);
  assert.notEqual(a, b);
});

test('coalesce: fnが失敗したら、束ねられた全員に同じエラーが伝播する', async () => {
  const fn = async () => {
    await new Promise((r) => setTimeout(r, 10));
    throw new Error('boom');
  };

  const results = await Promise.allSettled([
    keepaCoalesce.coalesce('key-err', fn),
    keepaCoalesce.coalesce('key-err', fn),
  ]);

  assert.equal(results[0].status, 'rejected');
  assert.equal(results[1].status, 'rejected');
  assert.equal(results[0].reason.message, 'boom');
  assert.equal(results[1].reason.message, 'boom');
});

test('coalesce: 完了後は同じkeyでも新規にfnが呼ばれる(in-flight解除)', async () => {
  let callCount = 0;
  const fn = async () => {
    callCount += 1;
    return callCount;
  };

  const first = await keepaCoalesce.coalesce('key-seq', fn);
  const second = await keepaCoalesce.coalesce('key-seq', fn);

  assert.equal(first, 1);
  assert.equal(second, 2);
  assert.equal(callCount, 2);
});

test('coalesce: 実行中は_inFlightCountForTestが増え、完了後は0に戻る', async () => {
  let resolveFn;
  const fn = () => new Promise((r) => { resolveFn = r; });

  const promise = keepaCoalesce.coalesce('key-inflight', fn);
  assert.equal(keepaCoalesce._inFlightCountForTest(), 1);

  resolveFn('done');
  await promise;
  assert.equal(keepaCoalesce._inFlightCountForTest(), 0);
});
```

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `cd server && node --test test/keepa-coalesce.test.js`
Expected: FAIL(`Cannot find module '../src/keepaCoalesce'`)

- [ ] **Step 3: keepaCoalesce.jsを実装する**

`server/src/keepaCoalesce.js`を新規作成する:

```js
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

  const promise = Promise.resolve().then(fn);
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
```

- [ ] **Step 4: テストを実行して成功を確認する**

Run: `cd server && node --test test/keepa-coalesce.test.js`
Expected: PASS(全5テスト)

- [ ] **Step 5: コミット**

```bash
cd server && git add src/keepaCoalesce.js test/keepa-coalesce.test.js
git commit -m "リクエスト・コアレッシング用モジュール(keepaCoalesce.js)を新規追加"
```

---

## Task 5: routes.js のKeepa共有キー呼び出しをコアレッシング経由にする

**Files:**
- Modify: `server/src/routes.js`

**Interfaces:**
- Consumes: `keepaCoalesce.coalesce(key, fn)`(Task 4)。`keepaThrottle.acquire(priority, instance)`/`reportTokensLeft(tokensLeft, instance)`/`reportExhausted(instance)`/`debugSnapshot(instance)`(既存、Task 1で戻り値の`reason`が変わったのみ)。
- Produces: `fetchKeepaProductWithDebug(headers, {coalesceKey, fetchParams, priority})` — 新規ヘルパー。`{product: {product, tokensLeft}, debug: object|null}` を返すか、`err.code === 'keepa_busy'` の例外を投げる。
- Produces: `respondKeepaSearchResult(res, converted, isbn13, product, cacheKey, keepaDebug)` — 新規ヘルパー(`handleSearchViaKeepa`を置き換える)。

この変更は、既存の`acquireKeepaSlot`/`acquireKeepaSlotWithDebug`/`handleSearchViaKeepa`を削除し、`fetchKeepaProductWithDebug`+`respondKeepaSearchResult`へ置き換える。`/api/search`の2箇所(free/pro分岐)と`/api/graph-data`が呼び出し元になる。

- [ ] **Step 1: 失敗するテストを書く(コアレッシングの統合テスト)**

`server/test/keepa-throttle-routes.test.js`の末尾(ファイル最終行の直前)に追記する:

```js
test('/api/search: 同一コードへの同時リクエストはKeepaを1回しか呼ばない(コアレッシング)', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: 'shared-key' }, async () => {
    const routes = freshRoutes();
    const keepa = require('../src/keepa/client');
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });

    let callCount = 0;
    keepa.getProduct = async () => {
      callCount += 1;
      await new Promise((r) => setTimeout(r, 30));
      return {
        product: { asin: 'B000COALESCE1', title: 'コアレッシングテスト', csv: [] },
        tokensLeft: 9,
      };
    };

    const makeReq = (deviceId) => ({
      query: { code: '9784873119045' },
      headers: { 'x-app-plan': 'pro', 'x-device-id': deviceId },
    });

    const responses = await Promise.all(
      ['dev-a', 'dev-b', 'dev-c'].map(async (deviceId) => {
        const req = makeReq(deviceId);
        const res = createMockRes();
        await routes.match('GET', '/api/search').handler(req, res);
        return res;
      })
    );

    assert.equal(callCount, 1, 'Keepaへの実呼び出しは1回だけのはず');
    for (const res of responses) {
      assert.equal(res.statusCode, 200);
      assert.equal(res.body.asin, 'B000COALESCE1');
    }
  });
});

test('/api/search: コアレッシングされたリクエストがスロットル拒否されたら、束ねられた全員がkeepa_busyになる', async (t) => {
  await withEnv({ ...NO_SPAPI, KEEPA_API_KEY: 'shared-key' }, async () => {
    const routes = freshRoutes();
    throttleEnv(t, { KEEPA_BUCKET_CAPACITY: '10', KEEPA_REFILL_PER_MIN: '5' });
    await keepaThrottle.reportTokensLeft(0); // 枯渇状態を作る

    const makeReq = (deviceId) => ({
      query: { code: '9784873119045' },
      headers: { 'x-app-plan': 'pro', 'x-device-id': deviceId },
    });

    const responses = await Promise.all(
      ['dev-a', 'dev-b'].map(async (deviceId) => {
        const req = makeReq(deviceId);
        const res = createMockRes();
        await routes.match('GET', '/api/search').handler(req, res);
        return res;
      })
    );

    for (const res of responses) {
      assert.equal(res.statusCode, 429);
      assert.equal(res.body.error, 'keepa_busy');
    }
  });
});
```

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `cd server && node --test test/keepa-throttle-routes.test.js`
Expected: FAIL(既存の`'depth'`関連の期待値、および新規コアレッシングテスト)

- [ ] **Step 3: routes.js を変更する**

`server/src/routes.js`冒頭のrequire群に`keepaCoalesce`を追加する(既存の`const keepaThrottle = require('./keepaThrottle');`相当の行の直後に追加。実際の行番号はファイル冒頭を確認して合わせること):

```js
const keepaCoalesce = require('./keepaCoalesce');
```

275-356行目の`KEEPA_BUSY_MESSAGE`〜`acquireKeepaSlotWithDebug`のブロックのうち、`acquireKeepaSlot`(306-309行目)と`acquireKeepaSlotWithDebug`(330-356行目)を削除し、代わりに以下を追加する(`hasKeepaDemoHeader`/`keepaThrottleInstanceFor`/`hasKeepaDebugHeader`/`cacheBypassKeepaDebug`/`attachKeepaDebug`はそのまま残す):

```js
/**
 * 共有Keepaキーのスロットル許可+Keepa本体呼び出しを1つの単位として扱い、
 * 同一商品への同時リクエストをコアレッシングでまとめる(設計書2026-08-03改訂)。
 * BYOキーはスロットルを経由しない(束ねる意味はあるので、コアレッシング自体は行う)。
 * @param {{instance: string, coalesceKey: string, fetchParams: object,
 *   priority: 'pro'|'free', isByo: boolean, isDemo: boolean}} params
 * @returns {Promise<{product: object, tokensLeft: number|undefined}>}
 */
async function fetchKeepaProductCoalesced({ instance, coalesceKey, fetchParams, priority, isByo, isDemo }) {
  return keepaCoalesce.coalesce(coalesceKey, async () => {
    if (!isByo) {
      const acquired = await keepaThrottle.acquire(priority, instance);
      if (!acquired.allowed) {
        const err = new Error('keepa throttle busy');
        err.code = 'keepa_busy';
        throw err;
      }
    }
    try {
      const result = await keepa.getProduct(fetchParams);
      // 共有キーのときだけ実残量をスロットルへ報告する(BYOキーの残量で共有側の推定を
      // 壊さないようにする)。デモモードのときも報告しない(seedした値を維持するため)。
      if (!isByo && !isDemo && Number.isFinite(result.tokensLeft)) {
        await keepaThrottle.reportTokensLeft(result.tokensLeft, instance);
      }
      return result;
    } catch (err) {
      if (err.code === 'keepa_tokens_exhausted') {
        // 推定より実残量が少なかった稀なケース。残量0へ補正し、キュー拒否と同じ
        // 文言で返す(体験を1種類に揃える。設計書§2.1)。
        if (!isByo && !isDemo) await keepaThrottle.reportExhausted(instance);
        const busyErr = new Error('keepa throttle busy');
        busyErr.code = 'keepa_busy';
        throw busyErr;
      }
      throw err;
    }
  });
}

/**
 * ヘッダーからBYO/デバッグ/デモの各判定を行い、fetchKeepaProductCoalescedを呼ぶ。
 * X-Keepa-Debug有効時のみ実測(waitedMs)とスナップショットを添えたdebug情報を返す。
 * デモモード(instance='demo')・BYOのコアレッシングkeyはinstance/'byo'を必ず含め、
 * 本番共有('global')と絶対に混ざらないようにする(隔離の安全設計。設計書§2.1)。
 * @param {object} headers
 * @param {{coalesceKey: string, fetchParams: object, priority: 'pro'|'free'}} params
 * @returns {Promise<{product: {product: object, tokensLeft: number|undefined}, debug: object|null}>}
 */
async function fetchKeepaProductWithDebug(headers, { coalesceKey, fetchParams, priority }) {
  const isByo = hasByoKeepaKey(headers);
  const isDemo = hasKeepaDemoHeader(headers);
  const instance = keepaThrottleInstanceFor(headers);
  const debugEnabled = hasKeepaDebugHeader(headers);

  if (isByo) {
    const product = await fetchKeepaProductCoalesced({
      instance, coalesceKey: `byo:${coalesceKey}`, fetchParams, priority, isByo: true, isDemo,
    });
    return {
      product,
      debug: debugEnabled ? { bypass: 'byo', waitedMs: 0, allowed: true, reason: null, snapshot: null } : null,
    };
  }

  if (!debugEnabled) {
    const product = await fetchKeepaProductCoalesced({
      instance, coalesceKey: `${instance}:${coalesceKey}`, fetchParams, priority, isByo: false, isDemo,
    });
    return { product, debug: null };
  }

  // 判定直前のスナップショットを取ってから実測する(束ねられて待つ時間も含めて計測する)。
  const snapshot = await keepaThrottle.debugSnapshot(instance);
  const startedAt = Date.now();
  const product = await fetchKeepaProductCoalesced({
    instance, coalesceKey: `${instance}:${coalesceKey}`, fetchParams, priority, isByo: false, isDemo,
  });
  const waitedMs = Date.now() - startedAt;
  return { product, debug: { bypass: null, waitedMs, allowed: true, reason: null, snapshot } };
}
```

次に、現在の`handleSearchViaKeepa`(現行行番号634-753行目付近。冒頭を`async function handleSearchViaKeepa(req, res, code, cacheKey, apiKey, keepaDebug) {`で検索して特定する)を丸ごと削除し、代わりに以下の`respondKeepaSearchResult`を追加する(catchブロックの`keepa_tokens_exhausted`処理は`fetchKeepaProductCoalesced`側へ移動済みなので、ここでは扱わない):

```js
/**
 * 取得済みのKeepa product(または未取得=convertCode段階での早期リターン)から
 * レスポンスを組み立てて送信する。handleSearchViaKeepaの後継(2026-08-03、
 * コアレッシング導入に伴い「Keepa呼び出し」と「レスポンス構築」を分離した)。
 * @param {import('express').Response} res
 * @param {{codeType: string, isbn13?: string|null, jan?: string|null, reason?: string}} converted convertCodeの戻り値
 * @param {string|null} isbn13
 * @param {object|null} product willCallKeepaがfalseの場合はnull(unresolved/no_identifierを返す)
 * @param {string} cacheKey
 * @param {object|null} keepaDebug
 */
function respondKeepaSearchResult(res, converted, isbn13, product, cacheKey, keepaDebug) {
  if (converted.codeType === CODE_TYPES.UNRESOLVED) {
    return res.json(attachKeepaDebug({
      codeType: CODE_TYPES.UNRESOLVED,
      asin: null,
      title: null,
      isbn13: null,
      imageUrl: null,
      salesRank: null,
      releaseDate: null,
      modelNumber: null,
      prices: null,
      profitInputs: null,
      reason: converted.reason || 'unresolved',
      source: 'keepa',
    }, keepaDebug));
  }

  const janOrIsbn = converted.isbn13 || converted.jan;
  if (!janOrIsbn) {
    return res.json(attachKeepaDebug({
      codeType: CODE_TYPES.UNRESOLVED,
      asin: null,
      title: null,
      isbn13,
      imageUrl: null,
      salesRank: null,
      releaseDate: null,
      modelNumber: null,
      prices: null,
      profitInputs: null,
      reason: 'no_identifier',
      source: 'keepa',
    }, keepaDebug));
  }

  const mapped = keepa.mapProductToSearchResult(product);
  if (!mapped) {
    return res.json(attachKeepaDebug({
      codeType: converted.codeType,
      asin: null,
      title: null,
      isbn13,
      imageUrl: null,
      salesRank: null,
      releaseDate: null,
      modelNumber: null,
      prices: null,
      profitInputs: null,
      reason: 'catalog_not_found',
      source: 'keepa',
    }, keepaDebug));
  }

  if (mapped.asin) {
    graphDataCache.set(graphDataCacheKey(mapped.asin), { series: keepa.extractGraphSeries(product) });
  }

  const profitInputs = {
    listPrice: mapped.listPrice,
    sellerCounts: mapped.sellerCounts,
    breakEven: {
      new: mapped.prices.new != null ? computeKeepaBreakEven(product, mapped.prices.new) : null,
      used: mapped.prices.used != null ? computeKeepaBreakEven(product, mapped.prices.used) : null,
    },
  };

  const responseBody = {
    codeType: converted.codeType,
    asin: mapped.asin,
    title: mapped.title,
    isbn13,
    imageUrl: mapped.imageUrl,
    salesRank: mapped.salesRank,
    releaseDate: mapped.releaseDate,
    modelNumber: null,
    prices: mapped.prices,
    profitInputs,
    source: 'keepa',
  };

  searchCache.set(cacheKey, responseBody, KEEPA_CACHE_TTL_MS);
  res.json(attachKeepaDebug(responseBody, keepaDebug));
}
```

次に`/api/search`ルート(`router.get('/api/search', ...)`。現行756-840行目付近)の中身を書き換える。無料(非Pro)分岐(現行788-826行目、`if (!isPro) { ... } return handleSearchViaKeepa(...); }`のブロック)を以下へ置き換える:

```js
    if (!isPro) {
      // 冒頭では消費せず、Keepa経路(サーバーのAPIキー消費)が確定してから判定する。
      if (cached) {
        attachQuota(res, await deviceQuota.computeQuota(deviceId));
        return res.json(
          hasKeepaDebugHeader(req.headers) ? attachKeepaDebug(cached, cacheBypassKeepaDebug()) : cached
        );
      }
      const converted = convertCode(code);
      const isbn13 = converted.isbn13 || null;
      const janOrIsbn = converted.isbn13 || converted.jan;
      const willCallKeepa = converted.codeType !== CODE_TYPES.UNRESOLVED && Boolean(janOrIsbn);

      if (!willCallKeepa) {
        attachQuota(res, await deviceQuota.computeQuota(deviceId));
        return respondKeepaSearchResult(res, converted, isbn13, null, cacheKey, null);
      }

      // 残ユニットの事前チェック(消費はしない)。コアレッシング導入でKeepa呼び出しが
      // tryConsumeより前に来るため、これが無いと枠切れユーザーのリクエストでKeepaトークン
      // だけが消費される。実際の消費は従来どおり成功後のtryConsumeで行う(拒否された処理に
      // ユニットを消費させない原則は維持)。
      const preCheckQuota = await deviceQuota.computeQuota(deviceId);
      if (preCheckQuota && preCheckQuota.unitsRemaining !== undefined && preCheckQuota.unitsRemaining <= 0) {
        return res.status(429).json({
          error: 'quota_exceeded',
          message: '本日の無料スキャン上限に達しました。',
          quota: preCheckQuota,
        });
      }

      let fetched;
      try {
        fetched = await fetchKeepaProductWithDebug(req.headers, {
          coalesceKey: cacheKey,
          fetchParams: { code: janOrIsbn, history: 1, apiKey: keepaApiKey },
          priority: 'free',
        });
      } catch (err) {
        if (err.code === 'keepa_busy') return sendKeepaBusy(res);
        console.error(`[search:keepa] code=${code} failed:`, err.message);
        return res.status(502).json({ error: 'search_failed', message: err.message });
      }

      const consumeResult = await deviceQuota.tryConsume(deviceId, 1);
      if (!consumeResult.allowed) {
        return res.status(429).json({
          error: 'quota_exceeded',
          message: '本日の無料スキャン上限に達しました。',
          quota: consumeResult.quota,
        });
      }
      attachQuota(res, consumeResult.quota);
      return respondKeepaSearchResult(res, converted, isbn13, fetched.product.product, cacheKey, fetched.debug);
    }
```

続けてPro分岐(現行829-836行目、`if (cached) {...} const acquired = ...; return handleSearchViaKeepa(...);`)を以下へ置き換える:

```js
    if (cached) {
      return res.json(
        hasKeepaDebugHeader(req.headers) ? attachKeepaDebug(cached, cacheBypassKeepaDebug()) : cached
      );
    }
    const converted = convertCode(code);
    const isbn13 = converted.isbn13 || null;
    const janOrIsbn = converted.isbn13 || converted.jan;
    if (converted.codeType === CODE_TYPES.UNRESOLVED || !janOrIsbn) {
      return respondKeepaSearchResult(res, converted, isbn13, null, cacheKey, null);
    }

    let fetched;
    try {
      fetched = await fetchKeepaProductWithDebug(req.headers, {
        coalesceKey: cacheKey,
        fetchParams: { code: janOrIsbn, history: 1, apiKey: keepaApiKey },
        priority: 'pro',
      });
    } catch (err) {
      if (err.code === 'keepa_busy') return sendKeepaBusy(res);
      console.error(`[search:keepa] code=${code} failed:`, err.message);
      return res.status(502).json({ error: 'search_failed', message: err.message });
    }
    return respondKeepaSearchResult(res, converted, isbn13, fetched.product.product, cacheKey, fetched.debug);
```

最後に`/api/graph-data`ルート(現行1034-1108行目付近)を書き換える。`acquireKeepaSlotWithDebug`呼び出し(現行1062-1107行目、`const acquired = ...` から関数末尾の`});`直前まで)を以下へ置き換える:

```js
  // 残ユニットの事前チェック(消費はしない)。理由は/api/searchの同等処理と同じ。
  if (!isPro) {
    const preCheckQuota = await deviceQuota.computeQuota(deviceId);
    if (preCheckQuota && preCheckQuota.unitsRemaining !== undefined && preCheckQuota.unitsRemaining <= 0) {
      return res.status(429).json({
        error: 'quota_exceeded',
        message: '本日の無料スキャン上限に達しました。',
        quota: preCheckQuota,
      });
    }
  }

  let fetched;
  try {
    fetched = await fetchKeepaProductWithDebug(req.headers, {
      coalesceKey: cacheKey,
      fetchParams: { asin, history: 1, apiKey: keepaApiKey },
      priority: isPro ? 'pro' : 'free',
    });
  } catch (err) {
    if (err.code === 'keepa_busy') return sendKeepaBusy(res);
    console.error(`[graph-data] asin=${asin} failed:`, err.message);
    return res.status(502).json({ error: 'graph_data_failed', message: err.message });
  }
  const keepaDebug = fetched.debug;

  if (!isPro) {
    const consumeResult = await deviceQuota.tryConsume(deviceId, 1);
    if (!consumeResult.allowed) {
      return res.status(429).json({
        error: 'quota_exceeded',
        message: '本日の無料スキャン上限に達しました。',
        quota: consumeResult.quota,
      });
    }
    attachQuota(res, consumeResult.quota);
  }

  const responseBody = { series: keepa.extractGraphSeries(fetched.product.product) };
  graphDataCache.set(cacheKey, responseBody);
  res.json(attachKeepaDebug(responseBody, keepaDebug));
});
```

- [ ] **Step 4: 既存テストの`reason: 'depth'`期待値を更新する**

`server/test/keepa-throttle-routes.test.js`の646行目・648行目の`assert.equal(results[2/3].reason, 'depth')`を`'exhausted'`へ変更する。

- [ ] **Step 5: throttleEnvからKEEPA_QUEUE_DEPTHを取り除く**

`server/test/keepa-throttle-routes.test.js`内の全ての`throttleEnv(t, { ... KEEPA_QUEUE_DEPTH: '...', ... })`呼び出しから`KEEPA_QUEUE_DEPTH: '...', `の部分を取り除く。次のコマンドで一括置換できる:

```bash
cd server && sed -i '' "s/KEEPA_QUEUE_DEPTH: '[0-9]*', //g" test/keepa-throttle-routes.test.js
```

置換後、`grep -n "KEEPA_QUEUE_DEPTH" test/keepa-throttle-routes.test.js`が何も出力しないことを確認する。

- [ ] **Step 6: テストを実行して成功を確認する**

Run: `cd server && node --test test/keepa-throttle-routes.test.js`
Expected: PASS(全テスト。Step 1で追加した2件のコアレッシングテストを含む)

- [ ] **Step 7: サーバー全体のテストを実行する**

Run: `cd server && npm test`
Expected: PASS(全ファイル)

- [ ] **Step 8: コミット**

```bash
cd server && git add src/routes.js test/keepa-throttle-routes.test.js
git commit -m "Keepa共有キー呼び出しをコアレッシング経由にし、キュー撤去後のスロットル呼び出しへ統合

同一商品への同時リクエストは、実際にKeepaを呼ぶのを1回にまとめて結果を共有する。
acquireKeepaSlot/handleSearchViaKeepaを廃し、fetchKeepaProductWithDebug+
respondKeepaSearchResultへ統合した(/api/search・/api/graph-data共通)。"
```

---

## Task 6: iOS — キュー可視化UIの撤去とSnapshot構造体の更新

**Files:**
- Modify: `ios/BarcodeSedori/Sources/Models/SearchModels.swift`
- Modify: `ios/BarcodeSedori/Sources/Views/SettingsView.swift`

**Interfaces:**
- Consumes: サーバーの`debugSnapshot`/`/probe`レスポンスから`queueLength`/`depth`フィールドが消える(Task 1・5)。

- [ ] **Step 1: Snapshot構造体からqueueLength/depthを削除する**

`ios/BarcodeSedori/Sources/Models/SearchModels.swift`の99-106行目を以下へ置き換える:

```swift
    struct Snapshot: Codable, Equatable {
        let tokensEstimate: Double
        let capacity: Int
        let consumeRatePerMin: Int
        let refillPerMin: Int
    }
```

95行目のコメント`/// 拒否理由("depth"|"timeout")。許可時・BYO・キャッシュ時はnil。`を以下へ変更する:

```swift
    /// 拒否理由("exhausted")。許可時・BYO・キャッシュ時はnil。
```

116-119行目のコメント(`KeepaThrottleProbeResult`の説明。「キューの挙動...を確認するために使う」の部分)を以下へ変更する:

```swift
/// POST /api/keepa-throttle-demo/probe の応答(開発者向けデモモード)。
/// 実際のKeepa呼び出しを一切行わず、'demo'インスタンスのスロットル判定(acquire)だけを
/// 実行した結果。適応ブレーキによる遅延(waitedMs)や、残量枯渇時の即時拒否を確認するために使う。
```

125行目のコメント`/// 拒否理由("depth"|"timeout")。許可時はnil。`を`/// 拒否理由("exhausted")。許可時はnil。`へ変更する。

- [ ] **Step 2: キュー可視化(同時リクエストテスト)UIを削除する**

`ios/BarcodeSedori/Sources/Views/SettingsView.swift`の174-225行目(`ProbeResultRow`構造体から`runConcurrentKeepaThrottleProbe()`関数末尾の`}`まで、`SettingsViewModel`クラスを閉じる直前)を丸ごと削除する。

164-165行目(`demoSeedResultText`の組み立て。`snapshot.queueLength`/`snapshot.depth`を参照している箇所)を以下へ置き換える:

```swift
            if let snapshot = result.snapshot {
                demoSeedResultText = "適用しました: 残量\(snapshot.tokensEstimate)/\(snapshot.capacity)"
                    + " 消費レート\(snapshot.consumeRatePerMin)/分 補充\(snapshot.refillPerMin)/分"
            } else {
                demoSeedResultText = "適用しました(スナップショットは取得できませんでした)"
            }
```

354-375行目(「同時リクエストをテスト」ボタン・結果表示・説明文)を丸ごと削除する。

350行目の説明文から「キュー」への言及を削る:

```swift
                    Text("デモ専用の隔離されたインスタンスに値を注入します。本番の共有Keepaキーを使う他の利用者には一切影響しません。注入した値やブレーキの挙動を確認するには、上の「デバッグ表示」も合わせてONにしてください。補充レートを指定すると、時間経過で残量が実際に回復していく様子を観察できます(未指定時は従来通り固定されたままです)。")
```

- [ ] **Step 3: ビルドして確認する**

Run: `cd ios/BarcodeSedori && xcodebuild -scheme BarcodeSedori -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -40`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: シミュレータで設定画面を確認する**

`mcp__Claude_Code_iOS_Simulator__control`の`attach`→`launch`で起動し、設定タブ→「開発者向け」セクションを開いて、「同時リクエストをテスト」ボタンが表示されないこと、「デモ状態を適用」ボタンと単発のprobe結果表示は引き続き動作することをスクリーンショットで確認する。

- [ ] **Step 5: コミット**

```bash
cd ios && git add BarcodeSedori/Sources/Models/SearchModels.swift BarcodeSedori/Sources/Views/SettingsView.swift
git commit -m "iOS: キュー撤去に伴い、Snapshotからqueue Length/depthを削除し同時リクエストテストUIを撤去

キュー機構自体が無くなったため、それを可視化する目的だった「同時リクエストを
テスト」機能は意味を失う。単発のseed+probeデモ(残量/消費レート/補充レートの
注入と、適応ブレーキ・即時拒否の確認)は引き続き残す。"
```

---

## Task 7: 設計書・旧企画書を更新する

**Files:**
- Modify: `docs/superpowers/specs/2026-08-02-keepa-token-depletion-design.md`
- Modify: `KEEPA-TOKEN-PLAN.md`

- [ ] **Step 1: 設計書に2026-08-03改訂の節を追記する**

`docs/superpowers/specs/2026-08-02-keepa-token-depletion-design.md`の末尾(202行目、旧企画書との対応表の後)に以下を追記する:

```markdown

## 8. 2026-08-03改訂: 枯渇時キューの撤去とリクエスト・コアレッシング導入

本番運用と実機検証を踏まえ、2.1節で決めた「枯渇時に優先度付きキューで待たせる」方式を撤去し、
「リクエスト・コアレッシング」(同一商品への同時リクエストをまとめる)へ置き換えた。

**撤去の理由:**
1. 現行契約プラン(5トークン/分=12秒に1個)では、KEEPA_QUEUE_TIMEOUT_MS(6,000ms)の待ちで
   トークンが補充される見込みが薄く、「6秒待たされた末に同じ拒否」になりがちでUX上ほぼ無意味
   だった。20トークン/分(Phase 0)へ上げれば意味は出るが、それでも「エラーではなく数秒待つ」
   価値は限定的と判断した。
2. 本番検証で、キューを補充ペースに合わせて自動的に流す自己タイマー
   (scheduleGrant→setTimeout→grantTick)が、Cloudflare Durable Objectsの実行環境では
   信頼できるタイミングで発火しないことが判明した(新しい別リクエストが到着した際に、
   その到着リクエストのacquire()冒頭にある「先にキューを流す」処理を経由してのみ間接的に
   流れる。単独のリクエストがキューに1件だけ並んでいる状況では、補充が進んでも
   タイムアウトまで解放されないままだった)。

**新しい`acquire(priority)`の挙動:**
1. 推定残量 ≥ 1 → 適応ブレーキ(§2.6、维持)を適用した上で許可
2. 残量 0 → 即座に拒否(`{allowed: false, reason: 'exhausted'}`)。キューには入れない

`KEEPA_QUEUE_DEPTH`・`KEEPA_QUEUE_TIMEOUT_MS`は廃止した。適応ブレーキの遅延上限は、
廃止した`KEEPA_QUEUE_TIMEOUT_MS`への依存を切り離し、コード内定数`BRAKE_CAP_MS`(4,000ms)
とした(`server/src/keepaThrottle.js`)。

**多人数同時アクセス対策として新規追加: リクエスト・コアレッシング**

トークンが十分にある状態でも、同一商品(同一JAN/ISBN・同一ASIN)への大量の同時リクエストが
届くと、瞬間的にKeepaへの同時アウトバウンドが増えすぎる懸念がある(トークンバケットは
平均レートを制御するが瞬間同時実行数は制御しない)。この懸念への対策として、
`server/src/keepaCoalesce.js`(single-flight方式)を新規導入し、`/api/search`・
`/api/graph-data`のKeepa共有キー呼び出し(スロットル許可+実際のKeepa API呼び出し)を、
同一商品コード・同一インスタンス('global'/'demo'を厳密に分離)単位でまとめた。
同時に届いた同一商品への複数リクエストは、実際には1回だけKeepaを呼び、結果を全員で共有する
(スロットルの許可判定も1回だけ行われる。先着(リーダー)の優先度がフォロワーにも適用される
点は許容する既知の挙動)。

コアレッシングはWorkerのisolate内メモリのみで完結し、Durable Objectのような全isolate
横断の一元化はしない(ベストエフォートの負荷削減であり、正確性はスロットル側が引き続き
担保するため。詳細は`keepaCoalesce.js`冒頭コメント参照)。

**旧KEEPA-TOKEN-PLAN.mdとの対応の更新:** Phase2-7(リクエスト・コアレッシング)は
「不採用」から「採用(2026-08-03)」へ変更した。

**iOS側の変更:** キュー機構の可視化を目的としていたデモモードの「同時リクエストをテスト」
機能(5件同時発火してPro優先・補充による順次解放を観察するUI)は、可視化対象の機構自体が
無くなったため撤去した。単発のseed+probe(残量・消費レート・補充レートの注入と、適応ブレーキ・
即時拒否の確認)は残している。
```

- [ ] **Step 2: 旧企画書の対応表を更新する**

`KEEPA-TOKEN-PLAN.md`の該当行(「Phase 2-7 リクエスト・コアレッシング」の記載を探し、もし対応表があれば「不採用」等の記載を「採用(2026-08-03、設計書2026-08-02-keepa-token-depletion-design.md §8参照)」へ更新する。対応表が無ければこのステップはスキップしてよい(旧企画書はv1のまま歴史的記録として残す方針のため、無理に手を入れない)。

- [ ] **Step 3: コミット**

```bash
git add docs/superpowers/specs/2026-08-02-keepa-token-depletion-design.md KEEPA-TOKEN-PLAN.md
git commit -m "設計書に2026-08-03改訂(キュー撤去・コアレッシング導入)を追記"
```

---

## Task 8: 最終確認とデプロイ

**Files:** なし(検証のみ)

- [ ] **Step 1: サーバー全テストを実行する**

Run: `cd server && npm test`
Expected: PASS(全ファイル、Task 1-5で更新した全テストを含む)

- [ ] **Step 2: iOSビルドを最終確認する**

Run: `cd ios/BarcodeSedori && xcodebuild -scheme BarcodeSedori -destination 'platform=iOS Simulator,name=iPhone 16' clean build 2>&1 | tail -40`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: デプロイ前に差分を確認する**

Run: `git diff --stat main`
Expected: `server/src/keepaThrottle.js`・`server/src/keepaCoalesce.js`(新規)・`server/src/routes.js`・`server/wrangler.jsonc`・iOS 2ファイル・テスト各種・ドキュメント2ファイルが含まれることを目視確認する。

- [ ] **Step 4: 本番へデプロイする(ユーザーの明示的な承認を得てから実行すること)**

Run: `cd server && npm run deploy:cf`
Expected: `Uploaded`/`Deployed`/`Version ID`が出力される

- [ ] **Step 5: 本番で動作確認する**

`wrangler tail --format pretty`で実リクエストを監視しながら、以下を確認する:
- 枯渇していない通常の検索/グラフ取得が引き続き成功すること
- (可能であれば)同一商品への複数同時検索で、サーバーログ上Keepaへの呼び出しが1回にまとまっていること
- 意図的に枯渇させた場合、即座に(6秒待たされずに)`混み合っているので時間を空けてお試しください。`が返ること
