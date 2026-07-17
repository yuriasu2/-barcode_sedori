# Cloudflare Workers 移行計画書（Render → Cloudflare 無料枠）

作成: 2026-07-15 / ステータス: **計画確定・Phase A 実装待ち**

## 1. 目的

- サーバー運用費を月額ゼロに（Workers 無料枠: 10万req/日）しつつ、**スリープ/コールドスタートを解消**する（Render無料の弱点）。
- Render は当面残し、**同一コードベースを両対応**にして DNS/URL 切替だけで行き来できるようにする（ロールバック容易性を最優先）。

## 2. 事前調査の結論（2026-07-15 コード棚卸し）

外部API呼び出し（SP-API / Keepa / LWA OAuth）は**既に全て `fetch`** で実装済み → Workersでそのまま動く。Node固有依存は以下のみ:

| 箇所 | 内容 | 対応 |
|---|---|---|
| `src/index.js` | `http.createServer` / listen | Workers用エントリ `src/worker.js` を**新規追加**（index.jsは残す=Render用） |
| `src/miniRouter.js` | `handler()` が Node req/res 前提 | **`fetchHandler()` を追加**（Request→`{method,query,headers}`、jsonRes互換コレクタ→Response）。既存 `handler()` は残す |
| `src/staticServer.js` | `fs` で public/ 配信 | Workers **Static Assets**（`assets.directory=public`）に委譲。staticServer.jsは残す(Render用) |
| `src/env.js` | `fs` で .env 読込 | Workersは entry で **envバインディング→`process.env` へコピー**（nodejs_compatでprocessが存在）。env.jsは残す(Render用) |
| `crypto`（routes/oauth/spapi/auth） | `createHash`/`randomBytes` | **`nodejs_compat` フラグ**で `require('crypto')` がそのまま動く（書き換え不要） |
| `src/spapi/client.js` | `https.Agent`（keep-alive） | Node環境のみ生成する条件分岐に（Workersでは不要/不可） |
| `require('url')` の `URL` | ─ | URLはWeb標準グローバル。nodejs_compatで現状のままでも可 |

インメモリ状態（`cache.js` / `deviceRateLimit.js`）は Workers でも isolate 単位で動くが、**isolateは随時リサイクルされるため効果が弱まる**（キャッシュヒット率低下・レート制限カウントの揮発）。→ Phase A では許容し（バックストップ用途のため）、Phase C で Durable Objects / Cache API に置換。

## 3. アーキテクチャ（Phase A 完了時）

```
[iOSアプリ] --HTTPS--> [Cloudflare Workers]
                          ├─ /health, /api/*, /oauth/* → MiniRouter.fetchHandler() → 既存 routes.js (無改修)
                          ├─ /, /assets/* → Static Assets (public/)
                          └─ Secrets: LWA_CLIENT_ID/SECRET, KEEPA_API_KEY, SPAPI_APP_ID ほか
[Render] ← 同一コードで並行稼働(ロールバック先)。src/index.js 経由
```

- ルーティング規則: `run_worker_first` で Worker が先に受け、`/health` `/api/*` `/oauth/*` 以外は `env.ASSETS.fetch()` にフォールバック（現行 index.js と同じ構造）。

## 4. 改修対象ファイル一覧

### 新規
| ファイル | 内容 |
|---|---|
| `server/src/worker.js` | Workersエントリ。`export default { fetch(request, env, ctx) }`。envバインディング→process.envコピー（初回のみ）、/health即応、静的フォールバック、`routes.fetchHandler()` 呼び出し |
| `server/wrangler.jsonc` | `main=src/worker.js` / `compatibility_date`（最新） / `compatibility_flags=["nodejs_compat"]` / `assets={directory:"public", binding:"ASSETS", run_worker_first:true相当の設定}` / `vars`（非秘密のみ） |
| `server/test/worker-adapter.test.js` | fetchHandler のユニットテスト（Node 18+ のグローバル Request/Response で実行可能） |

### 変更（最小差分・Render互換を維持）
| ファイル | 変更 |
|---|---|
| `server/src/miniRouter.js` | `fetchHandler()` 追加（json/status/redirect/html/binary を Response に変換。headersは小文字キーのプレーンオブジェクト化） |
| `server/src/spapi/client.js` | `https.Agent` を Node 環境判定付きに（Workersではundefined） |
| `server/package.json` | `devDependencies: wrangler`、`scripts: dev:cf / deploy:cf` 追加（依存ゼロ方針は**本番コード**について維持。wranglerは開発ツール） |

### 無改修（そのまま動く）
`routes.js` / `keepa/client.js` / `spapi/auth.js` / `spapi/pricing.js` / `oauth.js` / `instore/convert.js` / `cache.js` / `deviceRateLimit.js` / 既存テスト全部

## 5. 手順

### Phase A: コード実装＋ローカル検証（Claude/Sonnet が実施）
1. `miniRouter.fetchHandler()` 実装（+ ユニットテスト）
2. `worker.js` / `wrangler.jsonc` 作成
3. `https.Agent` の条件分岐
4. `node --test` 全緑を確認（既存82+新規）
5. `npx wrangler dev` でローカル起動し、`/health` `/api/search`(unresolvedコード) `/`(静的) をcurlでスモークテスト
   - サンドボックスでwrangler取得不可の場合は手順書化してユーザーに依頼

### Phase B: アカウント・デプロイ（ユーザー実施。手順はこちらで案内）
6. Cloudflareアカウント作成（無料）→ `npx wrangler login`
7. Secrets登録: `wrangler secret put LWA_CLIENT_ID / LWA_CLIENT_SECRET / KEEPA_API_KEY / SPAPI_APP_ID`（**LWA_REFRESH_TOKENは登録しない**=BYO前提）。非秘密（`SELLER_CENTRAL_URL`, `FREE_DEVICE_DAILY_LIMIT`等）は wrangler.jsonc の vars
8. `npx wrangler deploy` → `https://<name>.workers.dev` で動作確認（iOSの設定画面のサーバーURLを一時的に向けて実機テスト）
9. **Amazon Developer Console の OAuth Redirect URI に Workers のURLを追加**（Render分は残す=並行稼働）
10. 独自ドメイン（推奨）: Cloudflareにドメインを置き、Workersのカスタムドメインに割当。アプリ既定URLをそのドメインへ

### Phase C: 切替後の強化（別途）
11. `deviceRateLimit` → Durable Objects（正確な日次カウント）
12. Keepaキャッシュ → Cache API（isolate揮発の解消）＋ KEEPA-TOKEN-PLAN の Phase 2（キューはDOで実装）
13. Phase 3 レシート検証のDBは D1 を採用

## 6. テスト方針

- **既存 `node --test`（82件）を無改修で維持**＝ビジネスロジックの回帰ゼロを担保。
- 新規 `worker-adapter.test.js`: fetchHandler が (a) ルート一致→JSON応答 (b) 404 (c) ヘッダー小文字化（`X-App-Plan`→`x-app-plan`） (d) binary（Content-Type付きバイト列） (e) redirect（302+Location） を正しく Response 化することを検証。
- `wrangler dev` スモーク: `/health`=200 / `/api/search?code=123`=unresolved JSON / `/`=index.html / `/api/graph`(ヘッダー無し)=403。
- 本番デプロイ後: iOS実機を workers.dev URL に向け、検索(SP-API/Keepa両経路)・グラフ(Pro)・OAuth連携の通しを確認。

## 7. ロールバック手順

前提: **Renderは削除せず並行稼働**。同一コードのため双方常に最新。

| 状況 | 手順 |
|---|---|
| Phase A/B 中の問題 | 何もしない（RenderのURLのまま。Workersは未参照） |
| 切替後に Workers で障害 | アプリのサーバーURL（または独自ドメインのDNS）を **RenderのURLへ戻すだけ**（コード変更なし・数分） |
| OAuthだけ問題 | Redirect URIはRender分を残してあるため、URLを戻せばOAuthも即復旧 |
| 完全撤退 | wrangler.jsonc等はRender動作に無影響のため、コードはそのままでよい |

## 8. リスクと対応

| リスク | 対応 |
|---|---|
| nodejs_compat の crypto 互換差（createHash/randomBytes） | 使用箇所は基本APIのみで対応済み範囲。Phase Aのwrangler devで実証 |
| 無料枠 CPU 10ms/リクエスト | 本アプリはI/O待ち中心（外部API待ちはCPU時間外）。超過時は該当リクエストのみエラー→ログで監視 |
| isolate揮発でキャッシュ効率低下→Keepaトークン消費増 | Phase Cで Cache API 化。それまでtokensLeft監視（KEEPA-TOKEN-PLAN） |
| デバイス日次バックストップの揮発 | クライアント側100件/日が主制御のため許容。Phase CでDO化 |
| OAuthコールバックURL切替漏れ | Redirect URIは新旧併記で移行。チェックリスト化(§5-9) |
| 無料枠10万req/日超過 | 現実的に遠い(100人×100スキャン=1〜3万/日)。超えたらWorkers Paid($5/月)へ |

## 9. 決定事項・前提

- Renderは**当面残す**（並行稼働・ロールバック先）。完全移行後も停止は任意。
- 本番コードの**依存ゼロ方針は維持**（wranglerはdevDependencyのみ）。
- `LWA_REFRESH_TOKEN` はどの環境にも置かない（BYO）。
- 独自ドメインは強く推奨（アプリのURL固定化の解消）。取得はユーザー判断。
