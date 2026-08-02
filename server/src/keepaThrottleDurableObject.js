/**
 * 共有Keepaキーのスロットル状態(トークン残量推定+優先度付きキュー)を一元管理するDurable Object。
 * Workers専用(Node/Render側では読み込まれない)。
 *
 * deviceQuotaのDOと違い、全ユーザー共通の状態なのでインスタンスはグローバルに1つ
 * (呼び出し側keepaThrottle.jsがidFromName('global')で固定)。
 *
 * 'global'インスタンス(本番の共有スロットル)は永続化しない:
 * - 残量はあくまで「推定」で、Keepaレスポンスのtokens Leftで毎回補正される。
 *   DOが退避(evict)されて満タン仮定から再開しても、数リクエストで実値へ収束する。
 * - キューは保留中のHTTPリクエスト(Promise)そのものなので、そもそも永続化できない
 *   (リクエスト保持中はDOが生き続けるため、実害もない)。
 * - storageを使わないことで、無料枠の書き込み上限も消費しない。
 *
 * ただし'demo'インスタンス(デモモード用。keepaThrottle.js参照)だけは例外で、
 * seedした値をstorageへ書く。理由はrestoreDemoSeedIfNeededのコメントを参照。
 */

import * as throttleNs from './keepaThrottle.js';

// keepaThrottle.jsはCommonJS。バンドラのCJS→ESM相互運用のフォールバック
// (worker.js/quotaDurableObject.jsと同じ流儀)。
const throttle = throttleNs.default || throttleNs;

export class KeepaThrottleDO {
  constructor(state, env) {
    this.state = state;
    this.core = new throttle.ThrottleCore(throttle.readThrottleConfig(env));
    // 'demo'インスタンスにseedした値だけはstorageへ書く(下記restoreDemoSeedIfNeeded参照)。
    // 復元はconstructorではなく最初のfetch内で行う(storage読み出しは非同期でconstructorは
    // 非同期にできないため)。
    this.demoSeedRestored = false;
  }

  /**
   * 'demo'インスタンスのDOが非活動状態でCloudflareにメモリから退避され、次のリクエストで
   * constructorから作り直された場合、通常のThrottleCoreは満タン仮定(tokens=capacity,
   * consumeRatePerMin=0)で再開する。'global'インスタンスはKeepaレスポンスのtokensLeftで
   * 毎回自己補正されるため実害が無いが、'demo'はデモの間ずっとreportTokensLeft/
   * reportExhaustedを意図的にスキップする設計(利用者がseedした値を上書きしないため)
   * なので、この自己補正が働かず退避のたびにseedした値が消えてしまう。
   * そのため'demo'に限り、seed時にstorageへ書いておき、fetchの最初に一度だけ復元する。
   * 'global'インスタンスのstorageには'demoSeed'キーが書かれることが無いので、
   * このDOクラスが'global'/'demo'どちらのIDで呼ばれても同じロジックのままでよい。
   */
  async restoreDemoSeedIfNeeded() {
    if (this.demoSeedRestored) return;
    this.demoSeedRestored = true;
    const seed = await this.state.storage.get('demoSeed');
    if (seed) this.core.seedDemoState(seed);
  }

  async fetch(request) {
    await this.restoreDemoSeedIfNeeded();
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
    if (request.method === 'POST' && url.pathname === '/debug') {
      return Response.json(this.core.debugSnapshot());
    }
    if (request.method === 'POST' && url.pathname === '/seed-demo') {
      // デモ専用: このDOインスタンス自体が呼び出し元(keepaThrottle.js)から
      // idFromName('demo')で振り分けられた別オブジェクトなので、ここでは
      // 素直にthis.coreへ注入するだけでよい('global'に影響しない保証は
      // 呼び出し側のインスタンス分離で担保されている)。
      const tokensRaw = url.searchParams.get('tokens');
      const rateRaw = url.searchParams.get('ratePerMin');
      const refillRaw = url.searchParams.get('refillPerMin');
      const tokens = tokensRaw !== null && tokensRaw !== '' ? parseFloat(tokensRaw) : undefined;
      const ratePerMin = rateRaw !== null && rateRaw !== '' ? parseFloat(rateRaw) : undefined;
      const refillPerMin = refillRaw !== null && refillRaw !== '' ? parseFloat(refillRaw) : undefined;
      this.core.seedDemoState({ tokens, ratePerMin, refillPerMin });
      // DOがこの後メモリから退避されても復元できるよう、seedした値そのもの
      // ({tokens, ratePerMin, refillPerMin})を保存しておく(restoreDemoSeedIfNeeded参照)。
      // 'global'インスタンスはこのルートを呼ばれないため、このstorage書き込みも発生しない。
      await this.state.storage.put('demoSeed', { tokens, ratePerMin, refillPerMin });
      return Response.json(this.core.debugSnapshot());
    }
    return new Response('not found', { status: 404 });
  }
}
