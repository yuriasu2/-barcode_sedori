/**
 * 出品者ID(seller ID)単位のPro無料お試し期間(既定7日間)を保持するDurable Object。
 * Workers専用(Node/Render側では読み込まれない)。
 *
 * インスタンスは出品者IDごとに1つ(呼び出し側sellerTrial.jsがidFromName(sellerId)で割り当てる。
 * deviceQuotaのDOと同じ「宛先ごとに1インスタンス」方式)。
 *
 * ★ipRateLimitDurableObject.jsとは異なり、必ずstate.storageへ永続化する。
 * IpRateLimitDOがstorageへ書かないのは「退避されても実害が小さいレート制限」だからだが、
 * ここで同じ判断をすると、DOが退避されるたびにstartedAtが失われ、次のアクセスで
 * 新規7日間のお試しが再発行されてしまう。これはこの改修で潰そうとしているバグ
 * (再インストールでお試しがリセットされる)を、DOの退避のたびに自ら再現することになる。
 * そのため必ずstate.storageへ書く。
 *
 * 保存する値はstartedAt(epoch ms)のみ。write-once: 既にレコードがあれば絶対に上書きしない
 * (これがこのDOの唯一の防御であり、上書きすると際限なくお試しを延長できてしまう)。
 */

import * as sellerTrialNs from './sellerTrial.js';

// sellerTrial.jsはCommonJS。バンドラのCJS→ESM相互運用のフォールバック
// (worker.js/ipRateLimitDurableObject.js/quotaDurableObject.jsと同じ流儀)。
const sellerTrial = sellerTrialNs.default || sellerTrialNs;

const STORAGE_KEY = 'startedAt'; // DO1個=出品者1人なのでキーは固定でよい

export class SellerTrialDO {
  constructor(state, env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request) {
    const url = new URL(request.url);

    if (request.method === 'POST' && url.pathname === '/get-or-start') {
      return this.handleGetOrStart(url);
    }

    return new Response(JSON.stringify({ error: 'not_found' }), {
      status: 404,
      headers: { 'Content-Type': 'application/json; charset=utf-8' },
    });
  }

  /**
   * DOは同一オブジェクトへのリクエストを直列化するため、get→(無ければ)putを
   * この1回のfetch内で完結させれば追加のロック機構は不要(quotaDurableObject.jsと同じ理由)。
   */
  async handleGetOrStart(url) {
    const nowRaw = parseInt(url.searchParams.get('now'), 10);
    const now = Number.isFinite(nowRaw) ? nowRaw : Date.now();
    const trialDays = sellerTrial.readTrialDays(this.env);

    let startedAt = await this.state.storage.get(STORAGE_KEY);
    if (startedAt === undefined || startedAt === null || !Number.isFinite(startedAt)) {
      // write-once: レコードが無いときだけ、今回のnowを開始日時として新規に書き込む。
      startedAt = now;
      await this.state.storage.put(STORAGE_KEY, startedAt);
    }
    // 既存レコードがある場合はここに到達しても一切書き込まない(上書き禁止)。

    const status = sellerTrial.buildStatus(startedAt, now, trialDays);
    return Response.json(status);
  }
}
