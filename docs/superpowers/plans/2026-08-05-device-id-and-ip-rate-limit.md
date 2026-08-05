# デバイスID必須化 + Keepa経路のIPレート制限 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `X-Device-Id` ヘッダーを省略するだけで無料枠が無制限になる迂回路を塞ぎ、共有Keepaキーを実際に消費する経路にだけクライアントIP単位のレート制限(30回/分)を掛ける。あわせてBYO Keepaキー利用者の不要な7秒クールダウンを撤廃する。

**Architecture:** サーバー側は (1) 無料枠クォータを適用する経路で `deviceId` が無ければ400で拒否、(2) 全Keepa商品取得の唯一のチョークポイントである `fetchKeepaProductWithDebug()` にIPレート制限を差し込む(キャッシュヒットは到達しないため自動的に対象外)。レート制限の状態はIPごとのDurable Object(固定ウィンドウ・インメモリのみ・storage書き込みなし)で保持する。iOS側は `identifierForVendor` 直接参照をやめ、Keychain永続UUID(`DeviceIdentifier`)へ一本化する。

**Tech Stack:** Cloudflare Workers (Durable Objects, `nodejs_compat`) / CommonJS + ESM混在のサーバーコード / Node.js組み込みテストランナー(`node --test`) / SwiftUI + Keychain Services

## Global Constraints

- サーバーのテストは `cd server && npm test`(= `node --test test/*.test.js`)。**全テストがパスすること**(現状295件)。
- `server/package.json` の `dependencies` は空を維持する。新規npm依存を追加しない。
- サーバーは自動デプロイされない。このタスクでは**デプロイしない**(実装とコミットまで)。
- iOSの検証は**ビルドが通ることの確認のみ**でよい(シミュレータ起動は不要)。
- ビルド確認コマンド: `xcodebuild -project "ios/BarcodeSedori/BarcodeSedori.xcodeproj" -scheme BarcodeSedori -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' -configuration Debug build CODE_SIGNING_ALLOWED=NO`
- 各タスク完了ごとにコミットする(確認不要。プロジェクトの作業ルール)。
- コメントは既存コードと同じ密度・文体(日本語、「なぜそうしたか」を書く)で揃える。
- レート制限の既定値は **30回/分**。環境変数名は `IP_RATE_LIMIT_PER_MIN`。
- BYO Keepaキー(`X-Keepa-Key`)利用者は**レート制限から除外しない**。理由: BYO判定はヘッダー値の有無だけで決まるため、除外するとデタラメな値を付けるだけで迂回できる。
- SP-API連携済み(`X-Spapi-Refresh-Token` あり)は共有Keepaを消費しないため、**構造上**レート制限の対象外になる(そのリクエストは `fetchKeepaProductWithDebug` を通らない)。明示的な除外条件は書かない。

---

### Task 1: iOS — Keychain永続のデバイス識別子へ移行

**Files:**
- Create: `ios/BarcodeSedori/Sources/Store/DeviceIdentifier.swift`
- (プロジェクトファイルの編集は**不要**。下記Step 2参照)
- Modify: `ios/BarcodeSedori/Sources/API/APIClient.swift:53-55, 119-124`
- Modify: `ios/BarcodeSedori/Sources/Ads/RewardedAdManager.swift:44-46, 74-77`

**Interfaces:**
- Consumes: `KeychainStore.get(_ account: String) -> String?` / `KeychainStore.set(_ value: String, for account: String) -> Bool`(既存。`ios/BarcodeSedori/Sources/Store/KeychainStore.swift`)
- Produces: `DeviceIdentifier.current -> String`(非Optional)。Task 5では使わないが、以後のiOS側は端末識別子をここからのみ取得する。

**背景(実装者向け):** 現在 `APIClient` と `RewardedAdManager` がそれぞれ独立に `UIDevice.current.identifierForVendor` を参照している。この2つは必ず同じ値でなければならない(片方が違うと、広告視聴の付与先と検索で消費する枠が別デバイス扱いになり「見たのに増えない」が起きる)。加えてIDFVは (a) nilを返し得る、(b) 同一ベンダーのアプリを全削除するとリセットされる、という2つの問題がある。Task 2でサーバーがdeviceId必須になるため、(a) はその端末が検索不能になることを意味する。

- [ ] **Step 1: `DeviceIdentifier.swift` を作成する**

Create `ios/BarcodeSedori/Sources/Store/DeviceIdentifier.swift`:

```swift
import Foundation
import UIKit

/// サーバーの無料枠クォータ(deviceQuota)が使う端末識別子。
///
/// 以前は `UIDevice.current.identifierForVendor` を各所で直接参照していたが、
/// 次の2つの理由でKeychain永続のUUIDへ移行した。
/// 1. IDFVはnilを返し得る。サーバー側がdeviceId必須(無ければ400)になったため、
///    nilのままだとその端末は検索できなくなる。
/// 2. IDFVは同一ベンダーのアプリを全て削除するとリセットされる。Keychainはアプリ削除後も
///    残るため、無料枠の意図しないリセットが起きにくい。
///
/// 値はランダムUUIDでPIIではない。
///
/// **重要**: APIClient(`X-Device-Id`)とRewardedAdManager(AdMob SSVの
/// `customRewardString`)は必ずこの同じ値を使うこと。異なる値を使うと広告視聴の付与先が
/// 検索で消費する枠と別デバイス扱いになり、視聴しても枠が増えない。
enum DeviceIdentifier {
    /// Keychainのアカウント名。KeychainStoreのservice(バンドルID)配下で一意であればよい。
    private static let keychainAccount = "device.identifier"

    /// 端末識別子。初回はIDFV(取れなければ新規UUID)をKeychainへ保存し、以後はそれを返す。
    ///
    /// `static let` にしているのはプロセス内で一度だけ解決するため。Keychainへの書き込みに
    /// 失敗した場合でもプロセスが生きている間は同じ値を返し続ける(呼び出しのたびに別の
    /// UUIDを生成して送ってしまうと、無料枠を毎回リセットできることになる)。
    static let current: String = resolve()

    private static func resolve() -> String {
        if let stored = KeychainStore.get(keychainAccount), !stored.isEmpty {
            return stored
        }
        // 初回のみ。既存ユーザーの枠を引き継げるようIDFVを優先し、取れない端末だけ新規UUIDにする。
        let generated = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        _ = KeychainStore.set(generated, for: keychainAccount)
        return generated
    }
}
```

- [ ] **Step 2: プロジェクトへの登録は不要であることを確認する**

このプロジェクトのXcodeプロジェクトファイルはXcodeGenで生成され、gitでは追跡していない
(`ios/BarcodeSedori/project.yml` の `sources: - path: Sources` が `Sources/` 配下を
自動で取り込む)。したがって新規Swiftファイルを手動登録する必要はない。

次のコマンドで前提を確認するだけでよい:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && git ls-files ios/BarcodeSedori/BarcodeSedori.xcodeproj/project.pbxproj | wc -l
```

Expected: `0`(非追跡=生成物)。

`xcodegen` が使える環境なら `cd ios/BarcodeSedori && xcodegen generate` を実行して
プロジェクトを再生成しておくと確実。無ければStep 5のビルドが通ることで確認できる。

- [ ] **Step 3: `APIClient` を新しい識別子へ切り替える**

Modify `ios/BarcodeSedori/Sources/API/APIClient.swift`。

置換前(53-55行目付近):

```swift
    /// 端末識別子(identifierForVendor)。サーバー側の無料デバイス日次バックストップに使う。
    /// 端末ごとに安定・アンインストールでリセットされるランダムUUID(PIIではない)。
    private let deviceId: String? = UIDevice.current.identifierForVendor?.uuidString
```

置換後:

```swift
    /// 端末識別子(Keychain永続のランダムUUID。DeviceIdentifier参照)。
    /// サーバー側の無料枠クォータ(deviceQuota)がこの値でユニットを数える。
    /// サーバーはこのヘッダーが無いリクエストを400で拒否するため、必ず送る(非Optional)。
    private let deviceId: String = DeviceIdentifier.current
```

置換前(119-124行目付近):

```swift
    /// 端末識別子ヘッダー(X-Device-Id)を付与する。サーバー側の無料デバイス日次バックストップ用。
    private func addDeviceHeader(to request: inout URLRequest) {
        if let deviceId {
            request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        }
    }
```

置換後:

```swift
    /// 端末識別子ヘッダー(X-Device-Id)を付与する。サーバー側の無料枠クォータ用。
    /// DeviceIdentifierが常に値を返すため条件分岐は不要(以前はIDFVがnilのとき無付与だった)。
    private func addDeviceHeader(to request: inout URLRequest) {
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
    }
```

- [ ] **Step 4: `RewardedAdManager` を同じ識別子へ切り替える**

Modify `ios/BarcodeSedori/Sources/Ads/RewardedAdManager.swift`。

置換前(44-46行目付近):

```swift
    /// SSVの付与先を特定するデバイス識別子。APIClientがサーバーへ送る `X-Device-Id` と
    /// 同じ値(identifierForVendor)でなければ、SSVが届いても別デバイスの枠に加算されてしまう。
    private var deviceId: String? { UIDevice.current.identifierForVendor?.uuidString }
```

置換後:

```swift
    /// SSVの付与先を特定するデバイス識別子。APIClientがサーバーへ送る `X-Device-Id` と
    /// 同じ値でなければ、SSVが届いても別デバイスの枠に加算されてしまうため、
    /// 双方ともDeviceIdentifier(Keychain永続UUID)を唯一の出所とする。
    private var deviceId: String { DeviceIdentifier.current }
```

置換前(74-77行目付近):

```swift
        guard isEnabled, !isPresenting else { return false }
        // identifierForVendorがnilだとSSVの付与先を特定できず、視聴させても枠が増えない。
        // 「見たのに増えない」体験を作らないため、この場合は広告を出さずfalseを返す。
        guard let deviceId else { return false }

```

置換後:

```swift
        guard isEnabled, !isPresenting else { return false }
        // DeviceIdentifierは常に値を返すため、旧来の「識別子がnilなら広告を出さない」ガードは不要。

```

- [ ] **Step 5: ビルドが通ることを確認する**

Run:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && xcodebuild -project "ios/BarcodeSedori/BarcodeSedori.xcodeproj" -scheme BarcodeSedori -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`

失敗する場合、最も可能性が高いのはStep 2のpbxproj編集ミス(「Build input file cannot be found」または `DeviceIdentifier` が未定義)。4箇所すべてに追記できているか確認すること。

- [ ] **Step 6: コミット**

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && git add ios/BarcodeSedori/Sources/Store/DeviceIdentifier.swift ios/BarcodeSedori/BarcodeSedori.xcodeproj/project.pbxproj ios/BarcodeSedori/Sources/API/APIClient.swift ios/BarcodeSedori/Sources/Ads/RewardedAdManager.swift && git commit -m "iOS: 端末識別子をKeychain永続UUIDへ一本化する

identifierForVendorはnilを返し得る上、同一ベンダーのアプリ全削除でリセットされる。
サーバーがdeviceId必須になるため、nilだとその端末が検索不能になる。
APIClientとRewardedAdManagerが別々にIDFVを参照していたのもDeviceIdentifierへ統合し、
広告視聴の付与先と検索で消費する枠が必ず一致することをコード上で保証する。"
```

---

### Task 2: サーバー — 無料枠クォータ経路でdeviceIdを必須にする

**Files:**
- Modify: `server/src/routes.js`(`sendDeviceIdRequired` 追加、3経路にガード追加、テスト用エクスポート追加)
- Modify: `server/src/deviceQuota.js:213-218, 228-229, 263-264`(多層防御)
- Test: `server/test/device-id-required.test.js`(新規)

**Interfaces:**
- Consumes: `deviceIdOf(headers) -> string|null`(既存。`server/src/routes.js:75`)
- Produces: `router.sendDeviceIdRequired`(テスト用エクスポート)。エラーレスポンスの形は `{ error: 'device_id_required', message: string }` / HTTP 400。

**背景(実装者向け):** 現在 `deviceQuota.computeQuota(null)` は `{ unlimited: true }`、`tryConsume(null)` は `{ allowed: true }` を返す。これは「deviceIdを取れないクライアントを誤ってブロックしない安全側」という意図だったが、`X-Device-Id` ヘッダーを付けないだけで無料枠が無制限になる迂回路になっていた。Task 1でアプリが必ず値を送るようになったので必須化する。

**注意:** アプリは未リリースのため、旧バージョンとの互換性は考慮不要。

- [ ] **Step 1: 失敗するテストを書く**

Create `server/test/device-id-required.test.js`:

```javascript
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const routes = require('../src/routes');

function createMockRes() {
  return {
    statusCode: 200,
    body: undefined,
    headers: {},
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(body) {
      this.body = body;
      return this;
    },
  };
}

// --- /api/quota ---

test('/api/quota: X-Device-Idが無い無料リクエストは400 device_id_required', async () => {
  const res = createMockRes();
  const route = routes.match('GET', '/api/quota');
  await route.handler({ query: {}, headers: {} }, res);

  assert.equal(res.statusCode, 400);
  assert.equal(res.body.error, 'device_id_required');
});

test('/api/quota: Proは端末IDが無くてもunlimitedを返す(クォータ対象外のため)', async () => {
  const res = createMockRes();
  const route = routes.match('GET', '/api/quota');
  await route.handler({ query: {}, headers: { 'x-app-plan': 'pro' } }, res);

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.unlimited, true);
});

test('/api/quota: X-Device-Idがあれば従来どおり残量を返す', async () => {
  routes.deviceQuota._reset();
  const res = createMockRes();
  const route = routes.match('GET', '/api/quota');
  await route.handler({ query: {}, headers: { 'x-device-id': 'device-a' } }, res);

  assert.equal(res.statusCode, 200);
  assert.equal(typeof res.body.unitsRemaining, 'number');
});

// --- deviceQuota モジュール(多層防御) ---

test('deviceQuota.tryConsume: deviceIdが無ければ拒否する(以前は許可していた)', async () => {
  const result = await routes.deviceQuota.tryConsume(null, 1);
  assert.equal(result.allowed, false);
});

test('deviceQuota.computeQuota: deviceIdが無ければunlimitedを返さない', async () => {
  const quota = await routes.deviceQuota.computeQuota(null);
  assert.notEqual(quota.unlimited, true);
});
```

- [ ] **Step 2: テストが失敗することを確認する**

Run:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)/server" && node --test test/device-id-required.test.js
```

Expected: FAIL。`/api/quota` は400ではなく200で `{unlimited:true}` を返し、`tryConsume(null)` は `allowed:true` を返すため。

- [ ] **Step 3: `routes.js` にヘルパーとガードを追加する**

Modify `server/src/routes.js`。

(a) `deviceIdOf` 関数(75-78行目付近)の直後に追加:

```javascript
/**
 * デバイスID(X-Device-Id)が必須の経路で、ヘッダーが無いときの応答。
 *
 * 以前はdeviceIdが無い場合を「無制限」として扱っていた(deviceIdを取れないクライアントを
 * 誤ってブロックしないための安全側)。しかしこれは、ヘッダーを付けないだけで無料枠を
 * 無制限に使えるという迂回路そのものだったため必須へ変更した。
 * アプリはKeychain永続のUUID(iOS側DeviceIdentifier)を必ず送るため、
 * 正規クライアントがここで弾かれることはない。
 */
function sendDeviceIdRequired(res) {
  return res.status(400).json({
    error: 'device_id_required',
    message: 'デバイス識別子が取得できませんでした。アプリを再起動してお試しください。',
  });
}
```

(b) `/api/search` の無料Keepa経路。`if (!isPro) {`(834行目付近。直後のコメントが「冒頭では消費せず、Keepa経路(サーバーのAPIキー消費)が確定してから判定する。」の箇所)の**直後の行**に追加:

```javascript
      // 無料枠を数える経路なので端末IDは必須(無ければ枠が無制限になる)。
      if (!deviceId) return sendDeviceIdRequired(res);
```

(c) `/api/graph-data`。`const deviceId = deviceIdOf(req.headers);`(1143行目付近)の**直後の行**に追加:

```javascript

  // 無料枠を数える経路なので端末IDは必須。Proは消費対象外のため要求しない。
  if (!isPro && !deviceId) return sendDeviceIdRequired(res);
```

(d) `/api/quota`。置換前(1269-1275行目付近):

```javascript
router.get('/api/quota', async (req, res) => {
  if (isProRequest(req.headers)) {
    return res.json({ unlimited: true, reason: 'pro' });
  }
  const deviceId = deviceIdOf(req.headers);
  res.json(await deviceQuota.computeQuota(deviceId));
});
```

置換後:

```javascript
router.get('/api/quota', async (req, res) => {
  if (isProRequest(req.headers)) {
    return res.json({ unlimited: true, reason: 'pro' });
  }
  const deviceId = deviceIdOf(req.headers);
  if (!deviceId) return sendDeviceIdRequired(res);
  res.json(await deviceQuota.computeQuota(deviceId));
});
```

(e) テスト用エクスポート。`router.deviceIdOf = deviceIdOf;` の直後の行に追加:

```javascript
// テスト用途にデバイスID必須エラーの応答関数を公開する。
router.sendDeviceIdRequired = sendDeviceIdRequired;
```

- [ ] **Step 4: `deviceQuota.js` を多層防御として修正する**

Modify `server/src/deviceQuota.js`。ルート側のガードが本命だが、モジュール単体で誤用されても無制限にならないようにする。

(a) `computeQuota`(213-218行目付近)を置換。置換前:

```javascript
async function computeQuota(deviceId) {
  if (!deviceId) return { unlimited: true };
  const state = await getState(deviceId);
  if (!state) return { unknown: true };
  return quotaMath.buildQuota(state.unitsUsed, state.adGrants, limits());
}
```

置換後:

```javascript
async function computeQuota(deviceId) {
  // deviceIdが無い場合はかつて { unlimited: true } を返していたが、ヘッダーを省くだけで
  // 無料枠が無制限になる迂回路だったため廃止した。呼び出し側(routes.js)が先に400で
  // 弾くので通常ここには来ない。到達した場合は「残量不明」を返す(クライアントは
  // unknownを見たらローカルの残量を維持し、上書きしない)。
  if (!deviceId) return { unknown: true };
  const state = await getState(deviceId);
  if (!state) return { unknown: true };
  return quotaMath.buildQuota(state.unitsUsed, state.adGrants, limits());
}
```

(b) `tryConsume`(228-229行目付近)の先頭を置換。置換前:

```javascript
async function tryConsume(deviceId, units = 1) {
  if (!deviceId) return { allowed: true, quota: { unlimited: true } };
```

置換後:

```javascript
async function tryConsume(deviceId, units = 1) {
  // computeQuotaと同じ理由で「deviceIdが無ければ許可」を廃止した(多層防御)。
  // routes.js側が先に400で弾くため通常ここには来ない。
  if (!deviceId) return { allowed: false, quota: { unknown: true } };
```

(c) `grantAd`(263-264行目付近)の先頭を置換。置換前:

```javascript
async function grantAd(deviceId, transactionId) {
  if (!deviceId) return { granted: false, quota: { unlimited: true } };
```

置換後:

```javascript
async function grantAd(deviceId, transactionId) {
  // 付与先が特定できないため付与しない(挙動は従来どおり)。quotaだけ
  // computeQuota/tryConsumeと揃えて「無制限」を返さないようにする。
  if (!deviceId) return { granted: false, quota: { unknown: true } };
```

(d) ファイル冒頭のドキュメンテーションコメント。`* DO障害時の方針(重要):` の行の**直前**に以下を挿入:

```javascript
 * deviceIdが無い場合の方針(2026-08-05変更):
 * かつては「無制限扱い(unlimited)」で倒していたが、X-Device-Idヘッダーを付けないだけで
 * 無料枠を無制限に使えるという迂回路になっていたため、拒否(tryConsumeはallowed:false)へ
 * 変更した。本来の防御はroutes.js側が400 device_id_requiredで先に弾くことであり、
 * ここは多層防御の位置づけ。
 *
```

- [ ] **Step 5: テストが通ることを確認する**

Run:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)/server" && node --test test/device-id-required.test.js
```

Expected: PASS(5件)

- [ ] **Step 6: 既存テストが壊れていないことを確認する**

Run:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)/server" && npm test 2>&1 | tail -20
```

Expected: `fail 0`。

既存テストが `deviceId` 無しで `/api/search` や `/api/quota` を叩いて200を期待している場合は落ちる。その場合は**テスト側にダミーの `'x-device-id'` を足して直す**(仕様変更が意図どおりであるため)。ただし「deviceId無しでunlimitedになること」自体を検証しているテストがあれば、そのテストは新しい期待値(拒否)へ書き換えること。

- [ ] **Step 7: コミット**

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && git add server/src/routes.js server/src/deviceQuota.js server/test/device-id-required.test.js && git commit -m "server: 無料枠クォータ経路でX-Device-Idを必須にする

ヘッダーを付けないだけで無料枠が無制限になる迂回路を塞ぐ。
/api/search(無料Keepa経路)・/api/graph-data(非Pro)・/api/quota で
deviceIdが無ければ400 device_id_requiredを返す。
deviceQuota側の「deviceIdが無ければ許可/無制限」も多層防御として拒否へ変更した。"
```

---

### Task 3: サーバー — IPレート制限モジュールとDurable Object

**Files:**
- Create: `server/src/ipRateLimit.js`(CommonJS。ファサード + 固定ウィンドウのコア)
- Create: `server/src/ipRateLimitDurableObject.js`(ESM。DO本体)
- Test: `server/test/ip-rate-limit.test.js`(新規)

**Interfaces:**
- Produces:
  - `ipRateLimit.checkAndCount(ip: string|null) -> Promise<{allowed: boolean, remaining: number, retryAfterSec: number}>`
  - `ipRateLimit.RateLimitCore`(class。`new RateLimitCore(limitPerMin)` / `.check(now?) -> {allowed, remaining, retryAfterSec}`)
  - `ipRateLimit.readLimitPerMin(env) -> number`
  - `ipRateLimit._setDurableBinding(binding)` / `ipRateLimit._reset()`(テスト用)
  - `IpRateLimitDO`(ESM named export)
- Consumes: なし(このタスクは独立。Task 4で `routes.js` から呼ぶ)

**背景(実装者向け):** 既存の `server/src/keepaThrottle.js` + `server/src/keepaThrottleDurableObject.js` が「CommonJSのコア + ESMのDOラッパ + `globalThis` 経由のバインディング受け渡し」というパターンの手本。同じ流儀で書くこと。

**設計判断:** 固定ウィンドウ(60秒)で、状態は**DOのメモリのみ**に持ちstorageへ書かない。理由は `keepaThrottleDurableObject.js` の `'global'` インスタンスと同じで、(1) レート制限は厳密な永続性を必要としない、(2) storage書き込みは無料枠の上限を消費するため。DOが退避(evict)されるとカウンタが0に戻るが、その場合に攻撃者が得るのは「たまに1ウィンドウ分多く通る」程度で許容範囲。

- [ ] **Step 1: 失敗するテストを書く**

Create `server/test/ip-rate-limit.test.js`:

```javascript
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const ipRateLimit = require('../src/ipRateLimit');

test('RateLimitCore: 上限までは許可し、超えたら拒否する', () => {
  const core = new ipRateLimit.RateLimitCore(3);
  const now = 1_000_000;

  assert.equal(core.check(now).allowed, true);
  assert.equal(core.check(now).allowed, true);
  assert.equal(core.check(now).allowed, true);
  assert.equal(core.check(now).allowed, false);
});

test('RateLimitCore: 残り回数(remaining)を返す', () => {
  const core = new ipRateLimit.RateLimitCore(3);
  const now = 1_000_000;

  assert.equal(core.check(now).remaining, 2);
  assert.equal(core.check(now).remaining, 1);
  assert.equal(core.check(now).remaining, 0);
});

test('RateLimitCore: ウィンドウ(60秒)が明けたらカウンタがリセットされる', () => {
  const core = new ipRateLimit.RateLimitCore(2);
  const now = 1_000_000;

  assert.equal(core.check(now).allowed, true);
  assert.equal(core.check(now).allowed, true);
  assert.equal(core.check(now).allowed, false);

  // 59秒後はまだ同じウィンドウ
  assert.equal(core.check(now + 59_000).allowed, false);
  // 60秒後は新しいウィンドウ
  assert.equal(core.check(now + 60_000).allowed, true);
});

test('RateLimitCore: 拒否時のretryAfterSecはウィンドウの残り秒数(1以上)', () => {
  const core = new ipRateLimit.RateLimitCore(1);
  const now = 1_000_000;

  core.check(now);
  const denied = core.check(now + 20_000);
  assert.equal(denied.allowed, false);
  assert.equal(denied.retryAfterSec, 40);
});

test('checkAndCount: ipがnull(Workers以外の環境)なら素通しする', async () => {
  ipRateLimit._reset();
  const result = await ipRateLimit.checkAndCount(null);
  assert.equal(result.allowed, true);
});

test('checkAndCount: インメモリ経路でIPごとに独立して数える', async () => {
  ipRateLimit._reset();
  ipRateLimit._setDurableBinding(null); // インメモリ経路を強制

  // 既定30回/分。同一IPで31回目が拒否される。
  for (let i = 0; i < 30; i += 1) {
    const ok = await ipRateLimit.checkAndCount('1.2.3.4');
    assert.equal(ok.allowed, true, `${i + 1}回目は許可されるはず`);
  }
  const denied = await ipRateLimit.checkAndCount('1.2.3.4');
  assert.equal(denied.allowed, false);

  // 別IPは影響を受けない
  const other = await ipRateLimit.checkAndCount('5.6.7.8');
  assert.equal(other.allowed, true);

  ipRateLimit._setDurableBinding(undefined);
});

test('checkAndCount: DO障害時は許可で倒す(可用性優先)', async () => {
  ipRateLimit._reset();
  ipRateLimit._setDurableBinding({
    idFromName() { return 'id'; },
    get() {
      return { fetch() { throw new Error('DO down'); } };
    },
  });

  const result = await ipRateLimit.checkAndCount('1.2.3.4');
  assert.equal(result.allowed, true);

  ipRateLimit._setDurableBinding(undefined);
});

test('readLimitPerMin: envの値を読み、無効なら既定30', () => {
  assert.equal(ipRateLimit.readLimitPerMin({ IP_RATE_LIMIT_PER_MIN: '10' }), 10);
  assert.equal(ipRateLimit.readLimitPerMin({}), 30);
  assert.equal(ipRateLimit.readLimitPerMin({ IP_RATE_LIMIT_PER_MIN: 'abc' }), 30);
  assert.equal(ipRateLimit.readLimitPerMin({ IP_RATE_LIMIT_PER_MIN: '0' }), 30);
});
```

- [ ] **Step 2: テストが失敗することを確認する**

Run:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)/server" && node --test test/ip-rate-limit.test.js
```

Expected: FAIL(`Cannot find module '../src/ipRateLimit'`)

- [ ] **Step 3: `ipRateLimit.js` を実装する**

Create `server/src/ipRateLimit.js`:

```javascript
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
```

- [ ] **Step 4: `ipRateLimitDurableObject.js` を実装する**

Create `server/src/ipRateLimitDurableObject.js`:

```javascript
/**
 * クライアントIP単位のレート制限カウンタを保持するDurable Object。
 * Workers専用(Node/Render側では読み込まれない)。
 *
 * インスタンスはIPごとに1つ(呼び出し側ipRateLimit.jsがidFromName(ip)で割り当てる)。
 * deviceQuotaのDOと同じ「宛先ごとに1インスタンス」方式で、KeepaThrottleDOのような
 * グローバル1個ではない。
 *
 * storageへは一切書かない。理由はipRateLimit.jsのファイル先頭コメント参照
 * (レート制限に厳密な永続性は不要で、無料枠の書き込み上限も消費したくない)。
 * そのため退避されるとカウンタは0から再開する。
 */

import * as rateLimitNs from './ipRateLimit.js';

// ipRateLimit.jsはCommonJS。バンドラのCJS→ESM相互運用のフォールバック
// (worker.js/keepaThrottleDurableObject.jsと同じ流儀)。
const rateLimit = rateLimitNs.default || rateLimitNs;

export class IpRateLimitDO {
  constructor(state, env) {
    this.state = state;
    this.core = new rateLimit.RateLimitCore(rateLimit.readLimitPerMin(env));
  }

  async fetch(request) {
    const url = new URL(request.url);

    if (url.pathname === '/check') {
      const result = this.core.check();
      return new Response(JSON.stringify(result), {
        status: 200,
        headers: { 'Content-Type': 'application/json; charset=utf-8' },
      });
    }

    return new Response(JSON.stringify({ error: 'not_found' }), {
      status: 404,
      headers: { 'Content-Type': 'application/json; charset=utf-8' },
    });
  }
}
```

- [ ] **Step 5: テストが通ることを確認する**

Run:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)/server" && node --test test/ip-rate-limit.test.js
```

Expected: PASS(8件)

- [ ] **Step 6: コミット**

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && git add server/src/ipRateLimit.js server/src/ipRateLimitDurableObject.js server/test/ip-rate-limit.test.js && git commit -m "server: クライアントIP単位のレート制限モジュールとDOを追加する

固定ウィンドウ(60秒)でIPごとに数える。既定30回/分(IP_RATE_LIMIT_PER_MIN)。
状態はDOのメモリのみでstorageへ書かない(無料枠の書き込み上限を消費しないため)。
DO障害時はdeviceQuotaと同じく許可で倒す。
この時点ではまだどこからも呼ばれていない(配線は次のコミット)。"
```

---

### Task 4: サーバー — Keepa呼び出しへレート制限を配線する

**Files:**
- Modify: `server/src/routes.js`(`clientIpOf` / `sendRateLimited` 追加、`fetchKeepaProductWithDebug` に組み込み、catch 3箇所)
- Modify: `server/src/worker.js`(DO再エクスポート + `globalThis` 橋渡し)
- Modify: `server/wrangler.jsonc`(バインディング・マイグレーション・環境変数)
- Test: `server/test/ip-rate-limit-routes.test.js`(新規)

**Interfaces:**
- Consumes: `ipRateLimit.checkAndCount(ip)`(Task 3)
- Produces: HTTP 429 `{ error: 'rate_limited', message: string, retryAfterSec: number }`。Task 5のiOS側がこの `error` 値を見る。

**背景(実装者向け):** `fetchKeepaProductWithDebug()`(`server/src/routes.js:386`)は `/api/search` の無料経路・Pro経路と `/api/graph-data` の3箇所すべてから呼ばれる、Keepa商品取得の唯一のチョークポイント。ここに入れればキャッシュヒット(関数に到達しない)とSP-API経路(そもそも呼ばない)が自動的に対象外になる。呼び出し元へは既存の `keepa_busy` と同じく `err.code` 付きの例外で伝える(3箇所のcatchが既にこの形を扱っている)。

**スコープ外(既知の穴):** `/api/graph`(Keepaグラフ画像のプロキシ)は `keepa.getGraphImage` を直接呼んでおり、このチョークポイントを通らない。加えてスロットル自体も通っていない。ただしiOSアプリはこのエンドポイントを使っていない(グラフは `/api/graph-data` + Swift Charts へ移行済み)ため、今回は触らない。別途対応する。

- [ ] **Step 1: 失敗するテストを書く**

Create `server/test/ip-rate-limit-routes.test.js`:

```javascript
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const routes = require('../src/routes');
const ipRateLimit = require('../src/ipRateLimit');

test('clientIpOf: CF-Connecting-IPを読む。無ければnull', () => {
  assert.equal(routes.clientIpOf({ 'cf-connecting-ip': '203.0.113.9' }), '203.0.113.9');
  assert.equal(routes.clientIpOf({}), null);
  assert.equal(routes.clientIpOf(null), null);
});

test('/api/search: 同一IPが上限を超えると429 rate_limited(Keepa経路)', async () => {
  routes.searchCache.clear();
  routes.deviceQuota._reset();
  ipRateLimit._reset();
  ipRateLimit._setDurableBinding(null); // インメモリ経路を強制

  const headers = {
    'cf-connecting-ip': '198.51.100.7',
    'x-device-id': 'device-rate-limit',
    'x-keepa-key': 'dummy-byo-key', // BYOでも除外されないことの確認を兼ねる
  };

  // 上限(既定30)まで先に消費しておく。
  for (let i = 0; i < 30; i += 1) {
    await ipRateLimit.checkAndCount('198.51.100.7');
  }

  const res = {
    statusCode: 200,
    body: undefined,
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
  };
  const route = routes.match('GET', '/api/search');
  await route.handler({ query: { code: '9784560017838' }, headers }, res);

  assert.equal(res.statusCode, 429);
  assert.equal(res.body.error, 'rate_limited');

  ipRateLimit._setDurableBinding(undefined);
});

test('/api/search: キャッシュヒットはレート制限を消費しない', async () => {
  routes.searchCache.clear();
  routes.deviceQuota._reset();
  ipRateLimit._reset();
  ipRateLimit._setDurableBinding(null);

  // キャッシュへ直接仕込む(Keepaを呼ばずにヒットさせる)。
  routes.searchCache.set('keepa:9784560017838', { asin: 'B00CACHED', source: 'keepa' });

  const headers = {
    'cf-connecting-ip': '198.51.100.8',
    'x-device-id': 'device-cache-hit',
  };
  const res = {
    statusCode: 200,
    body: undefined,
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
  };
  const route = routes.match('GET', '/api/search');
  await route.handler({ query: { code: '9784560017838' }, headers }, res);

  assert.equal(res.statusCode, 200);
  // キャッシュヒットではカウンタが動いていないため、次の1回目が必ず許可される。
  const after = await ipRateLimit.checkAndCount('198.51.100.8');
  assert.equal(after.remaining, ipRateLimit.DEFAULT_LIMIT_PER_MIN - 1);

  ipRateLimit._setDurableBinding(undefined);
});
```

- [ ] **Step 2: テストが失敗することを確認する**

Run:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)/server" && node --test test/ip-rate-limit-routes.test.js
```

Expected: FAIL(`routes.clientIpOf` が未定義)

- [ ] **Step 3: `routes.js` にヘルパーを追加する**

Modify `server/src/routes.js`。

(a) ファイル冒頭の `require` 群(`const quotaMath = require('./quotaMath');` などが並ぶ箇所)に追加:

```javascript
const ipRateLimit = require('./ipRateLimit');
```

(b) Task 2で追加した `sendDeviceIdRequired` 関数の直後に追加:

```javascript
/**
 * クライアントIPを取り出す。CloudflareがCF-Connecting-IPを必ず付与する。
 * Node/Render経由やテストでは存在しないためnullになり、その場合レート制限は素通しする
 * (Workers本番以外は攻撃対象ではないため)。
 */
function clientIpOf(headers) {
  const ip = headers && (headers['cf-connecting-ip'] || headers['CF-Connecting-IP']);
  return ip ? String(ip) : null;
}

/** IPレート制限に掛かったときの応答(429)。 */
function sendRateLimited(res, retryAfterSec) {
  return res.status(429).json({
    error: 'rate_limited',
    message: 'アクセスが集中しています。しばらく時間を空けてお試しください。',
    retryAfterSec: retryAfterSec || 60,
  });
}
```

(c) テスト用エクスポート。Task 2で追加した `router.sendDeviceIdRequired = sendDeviceIdRequired;` の直後に追加:

```javascript
// テスト用途にクライアントIP抽出関数を公開する。
router.clientIpOf = clientIpOf;
```

- [ ] **Step 4: `fetchKeepaProductWithDebug` にレート制限を組み込む**

Modify `server/src/routes.js`。`async function fetchKeepaProductWithDebug(headers, { coalesceKey, fetchParams, priority }) {`(386行目付近)の**直後の行**(`const isByo = ...` の直前)に挿入:

```javascript
  // IPレート制限。実際にKeepaを呼ぶ経路だけを対象にするため、この関数の入口で判定する
  // (キャッシュヒットはそもそもここへ到達せず、SP-API経路はこの関数を呼ばない)。
  // BYOキー利用者も対象に含める: BYO判定はヘッダー値の有無だけで決まるため、除外すると
  // デタラメなX-Keepa-Keyを付けるだけで制限を迂回できてしまう。
  // 呼び出し元へはkeepa_busyと同じくerr.code付きの例外で伝える(3箇所のcatchが既にこの形)。
  const rateLimitResult = await ipRateLimit.checkAndCount(clientIpOf(headers));
  if (!rateLimitResult.allowed) {
    const err = new Error('ip rate limited');
    err.code = 'rate_limited';
    err.retryAfterSec = rateLimitResult.retryAfterSec;
    throw err;
  }

```

- [ ] **Step 5: 3箇所のcatchでrate_limitedを処理する**

Modify `server/src/routes.js`。既存の `if (err.code === 'keepa_busy') return sendKeepaBusy(res);` が3箇所ある。**それぞれの直前の行**に以下を挿入する(合計3箇所)。

対象箇所の見分け方:
1. `/api/search` の無料Keepa経路(`console.error(\`[search:keepa] code=${code} failed:\`, ...)` を含むcatch。873行目付近)
2. `/api/search` のPro Keepa経路(同じく `[search:keepa]` を含むcatch。923行目付近)
3. `/api/graph-data`(`console.error(\`[graph-data] asin=${asin} failed:\`, ...)` を含むcatch。1177行目付近)

挿入する行(3箇所とも同一):

```javascript
      if (err.code === 'rate_limited') return sendRateLimited(res, err.retryAfterSec);
```

**注意:** 3箇所でインデントが異なる。1と2は `/api/search` 内でネストが深く、3は `/api/graph-data` 内。**各箇所の既存の `if (err.code === 'keepa_busy')` 行と同じインデント**に合わせること。

- [ ] **Step 6: `worker.js` にDOを配線する**

Modify `server/src/worker.js`。

(a) `export { KeepaThrottleDO } from './keepaThrottleDurableObject.js';` の直後に追加:

```javascript
// クライアントIP単位のレート制限のDO。IPごとに1インスタンス。
export { IpRateLimitDO } from './ipRateLimitDurableObject.js';
```

(b) `globalThis.__keepaThrottleDO = env.KEEPA_THROTTLE || null;` の直後に追加:

```javascript

    // IPレート制限のバインディング。ipRateLimit.js側がglobalThis経由で参照する
    // (__quotaDO/__keepaThrottleDOと同じ簡易な受け渡し方式)。
    globalThis.__ipRateLimitDO = env.IP_RATE_LIMIT || null;
```

- [ ] **Step 7: `wrangler.jsonc` を更新する**

Modify `server/wrangler.jsonc`。

(a) `vars` の `"KEEPA_REFILL_PER_MIN": "5"` の直後に追加(その行の末尾にカンマを足すこと):

```jsonc
    // 共有Keepaキーを消費するリクエストの、クライアントIP単位のレート制限(回/分)。
    // アプリ側の検索クールダウンはクライアント実装のためcurlには効かない。
    // 未連携ユーザーの実効上限は7秒間隔=毎分8〜9件のため、CGNATで複数人が
    // 同一IPを共有しても30なら巻き込まない。
    "IP_RATE_LIMIT_PER_MIN": "30"
```

(b) `durable_objects.bindings` に追加:

```jsonc
      { "name": "IP_RATE_LIMIT", "class_name": "IpRateLimitDO" }
```

(`{ "name": "KEEPA_THROTTLE", "class_name": "KeepaThrottleDO" }` の末尾にカンマを足して追加する)

(c) `migrations` に追加:

```jsonc
    { "tag": "v3", "new_sqlite_classes": ["IpRateLimitDO"] }
```

(`{ "tag": "v2", ... }` の末尾にカンマを足して追加する)

- [ ] **Step 8: テストが通ることを確認する**

Run:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)/server" && node --test test/ip-rate-limit-routes.test.js
```

Expected: PASS(3件)

- [ ] **Step 9: 全テストが通ることを確認する**

Run:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)/server" && npm test 2>&1 | tail -20
```

Expected: `fail 0`

既存テストが落ちる場合、原因はほぼ「テストが `cf-connecting-ip` を送っていないので素通しになる」ではなく、**インメモリのカウンタが他テストとの間で共有されている**こと。その場合は落ちたテストの冒頭で `require('../src/ipRateLimit')._reset()` を呼ぶこと。

- [ ] **Step 10: `wrangler.jsonc` の構文を検証する**

Run:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)/server" && npx wrangler deploy --dry-run 2>&1 | tail -20
```

Expected: エラーなく完了し、出力に `IpRateLimitDO` が含まれる。**`--dry-run` なので実際のデプロイは行われない。**

このコマンドがネットワーク/認証で失敗する場合は、代わりにJSONとして構文が妥当かだけ確認する:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)/server" && node -e "const s=require('fs').readFileSync('wrangler.jsonc','utf8').replace(/^\s*\/\/.*$/gm,''); JSON.parse(s); console.log('wrangler.jsonc: OK')"
```

Expected: `wrangler.jsonc: OK`

- [ ] **Step 11: コミット**

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && git add server/src/routes.js server/src/worker.js server/wrangler.jsonc server/test/ip-rate-limit-routes.test.js && git commit -m "server: Keepa呼び出し経路にIPレート制限(30回/分)を掛ける

全Keepa商品取得の唯一のチョークポイントであるfetchKeepaProductWithDebugへ差し込む。
キャッシュヒットは関数に到達せず、SP-API連携済みはそもそも呼ばないため、
どちらも自動的に対象外になる。BYOキー利用者は除外しない(ヘッダー値の有無だけで
判定されるため、除外すると偽の値で迂回できてしまう)。
超過時はkeepa_busyと同じ流儀でerr.code付き例外を投げ、429 rate_limitedを返す。"
```

---

### Task 5: iOS — BYOクールダウン撤廃とレート制限エラーの表示

**Files:**
- Modify: `ios/BarcodeSedori/Sources/Views/SearchTabView.swift:446-448`
- Modify: `ios/BarcodeSedori/Sources/API/APIClient.swift`(`APIClientError` に1ケース追加、`perform` に429分岐追加)

**Interfaces:**
- Consumes: HTTP 429 `{ error: 'rate_limited', message: string }`(Task 4)
- Consumes: `EntitlementStore.isPro`(既存) / `SettingsStore.isKeepaKeyUsable`(既存。`ios/BarcodeSedori/Sources/Store/SettingsStore.swift:493`)

**背景(実装者向け):** 現在のクールダウンは `settings.isSpApiLinkUsable ? 1.0 : 7.0` で、BYO Keepaキーの有無を見ていない。7秒という長さの根拠はコメントどおり「検索1回ごとに共有Keepaトークンを1個消費するため」だが、BYOキー利用者は自分の枠を使うので共有トークンを消費しない。したがって7秒待たせる根拠がない。

**重要:** 判定条件は `APIClient.addKeepaKeyHeaderIfNeeded`(`ios/BarcodeSedori/Sources/API/APIClient.swift:158-164`)と一致させること。同メソッドは **Proかつキーが非空** のときだけ `X-Keepa-Key` を送る。つまりProでないユーザーはキーを設定していても共有トークンを消費するので、7秒のままでなければならない。

- [ ] **Step 1: クールダウン判定を修正する**

Modify `ios/BarcodeSedori/Sources/Views/SearchTabView.swift`。

置換前(446-448行目付近):

```swift
    /// スキャン・手入力で共通のクールダウン秒数。未連携は検索1回ごとにKeepaトークンを
    /// 1個消費するため長め(7秒)、連携済み(SP-API経路=消費ゼロ)は重複読み取り防止程度(1秒)。
    private var searchCooldown: TimeInterval { settings.isSpApiLinkUsable ? 1.0 : 7.0 }
```

置換後:

```swift
    /// スキャン・手入力で共通のクールダウン秒数。
    /// 長め(7秒)にするのは「共有Keepaキーのトークンを1回の検索ごとに1個消費する」場合だけ。
    /// SP-API連携済み(Keepa経路を通らない)と、自前Keepaキー利用者(自分の枠を消費する)は
    /// 共有トークンを消費しないため、重複読み取り防止程度(1秒)でよい。
    private var searchCooldown: TimeInterval { consumesSharedKeepaToken ? 7.0 : 1.0 }

    /// この端末の検索が共有Keepaキーのトークンを消費するか。
    /// 自前キーの条件はAPIClient.addKeepaKeyHeaderIfNeededと一致させること
    /// (Proかつキーが非空のときだけX-Keepa-Keyを送るため、無料プランではキーを
    /// 設定していても共有トークンを消費する)。
    private var consumesSharedKeepaToken: Bool {
        if settings.isSpApiLinkUsable { return false }
        if entitlements.isPro && settings.isKeepaKeyUsable { return false }
        return true
    }
```

- [ ] **Step 2: `APIClientError` に `rateLimited` を追加する**

Modify `ios/BarcodeSedori/Sources/API/APIClient.swift`。

(a) `case keepaBusy(message: String?)`(15行目付近)の直後に追加:

```swift
    /// IPレート制限(HTTP 429, error=="rate_limited")。共有Keepaキーを消費する検索が
    /// 短時間に集中したときにサーバーが返す。正規の利用では通常到達しない。
    case rateLimited(message: String?)
```

(b) `errorDescription` の `case .keepaBusy(let message):` ブロック(31-32行目付近)の直後に追加:

```swift
        case .rateLimited(let message):
            return message ?? "アクセスが集中しています。しばらく時間を空けてお試しください。"
```

- [ ] **Step 3: `perform` で429 rate_limitedを変換する**

Modify `ios/BarcodeSedori/Sources/API/APIClient.swift`。

`perform` メソッド内、`keepa_busy` を扱う既存ブロック(208-212行目付近)の**直後**、`let body = String(data: data, encoding: .utf8) ?? ""` の**直前**に挿入:

```swift
            // IPレート制限(429)。keepa_busyと同じボディ形式のためQuotaExceededBodyを使い回す。
            if httpResponse.statusCode == 429,
               let limitedBody = try? decoder.decode(QuotaExceededBody.self, from: data),
               limitedBody.error == "rate_limited" {
                throw APIClientError.rateLimited(message: limitedBody.message)
            }
```

- [ ] **Step 4: ビルドが通ることを確認する**

Run:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && xcodebuild -project "ios/BarcodeSedori/BarcodeSedori.xcodeproj" -scheme BarcodeSedori -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`

`entitlements` が `SearchTabView` のスコープに無いというエラーが出た場合は、同ファイル内の既存の `entitlements` 参照(例: 377行目 `private var isSearchUnlimited: Bool { entitlements.isPro || settings.isSpApiLinkUsable }`)を確認し、同じプロパティ名を使うこと。

- [ ] **Step 5: コミット**

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && git add ios/BarcodeSedori/Sources/Views/SearchTabView.swift ios/BarcodeSedori/Sources/API/APIClient.swift && git commit -m "iOS: 自前Keepaキー利用者の7秒クールダウンを外し、429 rate_limitedを表示する

7秒待たせる根拠は「共有Keepaトークンを1検索ごとに消費するため」であり、
自前キー利用者は自分の枠を使うので該当しない。判定条件はAPIClientが
X-Keepa-Keyを送る条件(Proかつキー非空)と一致させている。
あわせてサーバーのIPレート制限(429 rate_limited)を専用エラーへ変換し、
生のJSONではなく日本語の文言が出るようにした。"
```

---

## 実装後の確認事項(全タスク完了後)

- [ ] `cd server && npm test` が `fail 0` であること
- [ ] iOSビルドが `** BUILD SUCCEEDED **` であること
- [ ] `git status` がクリーンであること
- [ ] **デプロイはしないこと**。サーバーは手動デプロイ(`cd server && npx wrangler deploy`)であり、DOマイグレーション(v3)を伴うため、ユーザーの明示的な指示を待つ

## 既知の未対応事項(このタスクのスコープ外)

- `/api/graph`(Keepaグラフ画像プロキシ)は `fetchKeepaProductWithDebug` を通らないためレート制限もスロットルも掛からない。`X-App-Plan: pro` の自己申告だけでゲートされている。iOSアプリは使っていない(グラフは `/api/graph-data` へ移行済み)ため今回は触らない。
- `X-App-Plan` のサーバー側検証(App Store Server API)は未実装。`pro` を自称するだけで無料枠の判定自体を迂回できる状態は残る。
- デバイスIDはアプリを削除してKeychainごと消えた場合(または端末初期化)にリセットされる。これはApp AttestでもDeviceCheckでしか塞げない別課題。
