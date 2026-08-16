/**
 * フリーミアムv2「無料枠ユニット」モデルのデバイス単位・日次クォータを保持するDurable Object。
 * Workers専用(Node/Render側では読み込まれない)。
 *
 * なぜDOが必要か:
 * 旧実装(deviceQuota.jsの旧版)はMapによるインメモリ管理だったが、Cloudflare Workersは
 * リクエストごとに別isolateへ振られ得るため、本番検証で「消費した直後に残量を問い合わせても
 * 全く反映されない」ことが判明し機能しなかった。DOは同一名(=deviceId)へのリクエストを
 * 単一のオブジェクトへ直列化するため、真の意味での状態共有・排他制御が実現できる。
 * SQLiteバックエンド(wrangler.jsonc側でnew_sqlite_classesを指定)は無料プランでも
 * 利用できるため採用している。
 *
 * ストレージAPIについて:
 * SQLiteバックエンドでも state.storage.get/put のKVスタイルAPIがそのまま使える。
 * このDOはデバイス1台につきカウンタ1件を持つだけなので、生SQLを書くよりシンプルなKV APIを使う。
 */

import * as quotaMathNs from './quotaMath.js';

// quotaMath.js はCommonJS(module.exports = {...})。バンドラ(wrangler/esbuild)の
// CJS→ESM相互運用により default にexports本体が入る場合と、名前付きで直接見える場合の
// 両方があり得るため、worker.js の routesModule 読み込みと同じ流儀でフォールバックする。
const quotaMath = quotaMathNs.default || quotaMathNs;

const STORAGE_KEY = 'entry'; // DO1個=デバイス1台なのでキーは固定でよい

/** env文字列からlimits({base, perAd, max})を組み立てる。未設定・不正値は既定値にフォールバックする。 */
function readLimits(env) {
  const base = env && parseInt(env.BASE_DAILY_UNITS, 10);
  return {
    // baseのみ0を有効値として扱う(「広告なしでは1回も使えない」設定を許容するため)。
    base: Number.isFinite(base) && base >= 0 ? base : 5,
    perAd: (env && parseInt(env.UNITS_PER_AD, 10)) || 5,
    max: (env && parseInt(env.MAX_DAILY_UNITS, 10)) || 100,
  };
}

/**
 * リクエストのクエリパラメータ(base/perAd/max)からlimitsを読む。
 *
 * なぜDO内でKVを読まずWorkerから受け取るのか(設計判断):
 * 無料枠の3設定はKV(ADS_CONFIG namespace の quota-limits キー)で可変になったが、
 * その解決はWorker側(quotaLimits.js)で行い、結果をこのDOへクエリパラメータとして
 * 渡す。DOも env 経由でKVバインディングを持てるが、DOはデバイスIDごとに1インスタンス
 * 存在するためKVキャッシュがインスタンス数だけ分散し、KV読み取り回数がデバイス数に
 * 比例して増える。さらにDOのconstructorは同期のため、KV読み取りは毎fetchのawaitとなり
 * 全リクエストにKV往復が乗る。解決ロジックを1箇所(Worker側)に集約する方が
 * 読み取り回数・レイテンシ・改修漏れのいずれの面でも有利。
 *
 * 3値すべてが妥当な整数として揃っている場合のみ採用し、1つでも欠け・不正があれば
 * constructorで読んだenv由来のlimitsへ倒す(部分適用で中途半端な設定にしないため。
 * 理由の詳細はquotaLimits.js参照)。これにより、パラメータを渡さない古い呼び出し
 * (およびテスト)でも従来どおり動く。
 *
 * @param {URLSearchParams} searchParams
 * @param {{base:number, perAd:number, max:number}} fallback
 */
function limitsFromParams(searchParams, fallback) {
  const base = parseInt(searchParams.get('base'), 10);
  const perAd = parseInt(searchParams.get('perAd'), 10);
  const max = parseInt(searchParams.get('max'), 10);
  if (!Number.isFinite(base) || base < 0) return fallback;
  if (!Number.isFinite(perAd) || perAd < 1) return fallback;
  if (!Number.isFinite(max) || max < 1 || max < base) return fallback;
  return { base, perAd, max };
}

/**
 * リプレイ対策(transaction_id冪等化)用に保持するseenTxの最大件数。
 * 1日の広告視聴上限が19本(5 + 5*19 = 100でcap到達)のため、直近30件も保持すれば
 * 1日分を確実にカバーできる。配列が際限なく伸びないよう先頭(古い方)から捨てる。
 */
const MAX_SEEN_TX = 30;

/**
 * storageから読んだ生の値を安全に正規化する。
 * - 未保存/非オブジェクト/日付不一致(=日付が変わった)/数値が壊れている場合は
 *   すべて安全側(unitsUsed:0, adGrants:0, seenTx:[])として扱う。
 *   日付が変わったらseenTxも空にリセットされる(=同じtransaction_idが翌日再送されても
 *   別物として扱われるが、そもそもtransaction_idは広告視聴ごとに一意なため実害はない)。
 * - dateは「呼び出し側(routes.js側のtodayString())が渡した値」をそのまま使う。
 *   DO内で new Date() を使うと日付判定ロジックが二重化するため、意図的に呼び出し側へ委ねる。
 * @param {*} stored state.storage.get(STORAGE_KEY) の結果
 * @param {string} date 呼び出し側から渡された当日文字列
 */
function normalizeEntry(stored, date) {
  if (!stored || typeof stored !== 'object' || stored.date !== date) {
    return { date, unitsUsed: 0, adGrants: 0, seenTx: [] };
  }
  const unitsUsed = Number.isFinite(stored.unitsUsed) && stored.unitsUsed >= 0 ? stored.unitsUsed : 0;
  const adGrants = Number.isFinite(stored.adGrants) && stored.adGrants >= 0 ? stored.adGrants : 0;
  const seenTx = Array.isArray(stored.seenTx) ? stored.seenTx.filter((t) => typeof t === 'string') : [];
  return { date, unitsUsed, adGrants, seenTx };
}

export class DeviceQuotaDO {
  constructor(state, env) {
    this.state = state;
    // クエリパラメータでlimitsが渡ってこなかった場合のフォールバック(env由来)。
    this.limits = readLimits(env);
  }

  /**
   * DOは同一オブジェクトへのリクエストを直列化する(1リクエストの処理が完了するまで次を
   * 待たせる)ため、get→判定→putをこの1回のfetch内で完結させれば追加のロック機構は不要。
   * @param {Request} request
   */
  async fetch(request) {
    const url = new URL(request.url);
    const date = url.searchParams.get('date') || '';
    // limitsはリクエストごとに解決する(KVでいつでも変わり得るため、constructor時点の
    // 値に固定してしまうとDOインスタンスが生き続ける限り古い設定を使い続けてしまう)。
    const limits = limitsFromParams(url.searchParams, this.limits);

    if (request.method === 'POST' && url.pathname === '/consume') {
      return this.handleConsume(url, date, limits);
    }
    if (request.method === 'POST' && url.pathname === '/grant-ad') {
      return this.handleGrantAd(date, url.searchParams.get('tx') || null, limits);
    }
    if (request.method === 'GET' && url.pathname === '/peek') {
      return this.handlePeek(date, limits);
    }
    return new Response('not found', { status: 404 });
  }

  async handleConsume(url, date, limits) {
    let units = 1;
    const unitsRaw = url.searchParams.get('units');
    if (unitsRaw !== null && unitsRaw !== '') {
      const parsed = parseInt(unitsRaw, 10);
      if (Number.isFinite(parsed) && parsed > 0) units = parsed;
    }

    const stored = await this.state.storage.get(STORAGE_KEY);
    const current = normalizeEntry(stored, date);
    const allowed = quotaMath.canConsume(current.unitsUsed, current.adGrants, units, limits);

    // seenTxはconsumeでは変化しないが、常に引き継ぐ(落とすとgrant-adのリプレイ対策が
    // consume呼び出しのたびに失われてしまう)。
    const next = allowed
      ? { date, unitsUsed: current.unitsUsed + units, adGrants: current.adGrants, seenTx: current.seenTx }
      : current;
    // 値が変わるときだけ書く。上限に達したユーザーがスキャンを連打すると、
    // 毎回同じ値を書き戻すことになり無料枠の書き込み上限(1日10万行)を無駄に消費するため。
    // 日付が変わった直後だけは、リセット後の状態を残すために書き込む。
    if (allowed || !stored || stored.date !== date) {
      await this.state.storage.put(STORAGE_KEY, next);
    }

    const quota = quotaMath.buildQuota(next.unitsUsed, next.adGrants, limits);
    return Response.json({ allowed, quota });
  }

  /**
   * 広告視聴1本分の付与を記録する。
   * txが指定されていて既にseenTxに含まれる場合は、リプレイ(同じコールバックの再送)と
   * みなして付与せず {granted:false, duplicate:true} を返す(AdMobはコールバック先が
   * 200を返さないと再送してくるため、成功後の再送でも二重付与しないためのガード)。
   * @param {string} date
   * @param {string|null} tx transaction_id(未指定ならリプレイ判定なし=従来どおり)
   * @param {{base:number, perAd:number, max:number}} limits 呼び出し側(Worker)が解決したlimits
   */
  async handleGrantAd(date, tx, limits) {
    const stored = await this.state.storage.get(STORAGE_KEY);
    const current = normalizeEntry(stored, date);

    if (tx && current.seenTx.includes(tx)) {
      const quota = quotaMath.buildQuota(current.unitsUsed, current.adGrants, limits);
      return Response.json({ granted: false, duplicate: true, quota });
    }

    const granted = quotaMath.canGrantAd(current.adGrants, limits);
    const nextAdGrants = granted ? current.adGrants + 1 : current.adGrants;
    // 直近MAX_SEEN_TX件だけ保持する(先頭=古い方から捨てる)。
    const nextSeenTx = tx ? [...current.seenTx, tx].slice(-MAX_SEEN_TX) : current.seenTx;

    const next = { date, unitsUsed: current.unitsUsed, adGrants: nextAdGrants, seenTx: nextSeenTx };
    // handleConsumeと同じ理由(書き込み上限の節約)で、状態が変わるとき
    // (付与された、またはtxを新規記録した)だけ書く。日付が変わった直後も書く。
    if (granted || tx || !stored || stored.date !== date) {
      await this.state.storage.put(STORAGE_KEY, next);
    }

    const quota = quotaMath.buildQuota(next.unitsUsed, next.adGrants, limits);
    return Response.json({ granted, duplicate: false, quota });
  }

  async handlePeek(date, limits) {
    const stored = await this.state.storage.get(STORAGE_KEY);
    const current = normalizeEntry(stored, date);
    const quota = quotaMath.buildQuota(current.unitsUsed, current.adGrants, limits);
    return Response.json(quota);
  }
}
