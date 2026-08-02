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
      const tokens = tokensRaw !== null && tokensRaw !== '' ? parseFloat(tokensRaw) : undefined;
      const ratePerMin = rateRaw !== null && rateRaw !== '' ? parseFloat(rateRaw) : undefined;
      this.core.seedDemoState({ tokens, ratePerMin });
      return Response.json(this.core.debugSnapshot());
    }
    return new Response('not found', { status: 404 });
  }
}
