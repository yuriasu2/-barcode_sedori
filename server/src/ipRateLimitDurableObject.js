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
