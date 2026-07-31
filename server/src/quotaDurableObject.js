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
  return {
    base: (env && parseInt(env.BASE_DAILY_UNITS, 10)) || 5,
    perAd: (env && parseInt(env.UNITS_PER_AD, 10)) || 5,
    max: (env && parseInt(env.MAX_DAILY_UNITS, 10)) || 100,
  };
}

/**
 * storageから読んだ生の値を安全に正規化する。
 * - 未保存/非オブジェクト/日付不一致(=日付が変わった)/数値が壊れている場合は
 *   すべて安全側(unitsUsed:0, adGrants:0)として扱う。
 * - dateは「呼び出し側(routes.js側のtodayString())が渡した値」をそのまま使う。
 *   DO内で new Date() を使うと日付判定ロジックが二重化するため、意図的に呼び出し側へ委ねる。
 * @param {*} stored state.storage.get(STORAGE_KEY) の結果
 * @param {string} date 呼び出し側から渡された当日文字列
 */
function normalizeEntry(stored, date) {
  if (!stored || typeof stored !== 'object' || stored.date !== date) {
    return { date, unitsUsed: 0, adGrants: 0 };
  }
  const unitsUsed = Number.isFinite(stored.unitsUsed) && stored.unitsUsed >= 0 ? stored.unitsUsed : 0;
  const adGrants = Number.isFinite(stored.adGrants) && stored.adGrants >= 0 ? stored.adGrants : 0;
  return { date, unitsUsed, adGrants };
}

export class DeviceQuotaDO {
  constructor(state, env) {
    this.state = state;
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

    if (request.method === 'POST' && url.pathname === '/consume') {
      return this.handleConsume(url, date);
    }
    if (request.method === 'POST' && url.pathname === '/grant-ad') {
      return this.handleGrantAd(date);
    }
    if (request.method === 'GET' && url.pathname === '/peek') {
      return this.handlePeek(date);
    }
    return new Response('not found', { status: 404 });
  }

  async handleConsume(url, date) {
    let units = 1;
    const unitsRaw = url.searchParams.get('units');
    if (unitsRaw !== null && unitsRaw !== '') {
      const parsed = parseInt(unitsRaw, 10);
      if (Number.isFinite(parsed) && parsed > 0) units = parsed;
    }

    const stored = await this.state.storage.get(STORAGE_KEY);
    const current = normalizeEntry(stored, date);
    const allowed = quotaMath.canConsume(current.unitsUsed, current.adGrants, units, this.limits);

    const next = allowed
      ? { date, unitsUsed: current.unitsUsed + units, adGrants: current.adGrants }
      : current;
    // 値が変わるときだけ書く。上限に達したユーザーがスキャンを連打すると、
    // 毎回同じ値を書き戻すことになり無料枠の書き込み上限(1日10万行)を無駄に消費するため。
    // 日付が変わった直後だけは、リセット後の状態を残すために書き込む。
    if (allowed || !stored || stored.date !== date) {
      await this.state.storage.put(STORAGE_KEY, next);
    }

    const quota = quotaMath.buildQuota(next.unitsUsed, next.adGrants, this.limits);
    return Response.json({ allowed, quota });
  }

  async handleGrantAd(date) {
    const stored = await this.state.storage.get(STORAGE_KEY);
    const current = normalizeEntry(stored, date);
    const granted = quotaMath.canGrantAd(current.adGrants, this.limits);

    const next = granted
      ? { date, unitsUsed: current.unitsUsed, adGrants: current.adGrants + 1 }
      : current;
    // handleConsumeと同じ理由で、値が変わるときだけ書く。
    if (granted || !stored || stored.date !== date) {
      await this.state.storage.put(STORAGE_KEY, next);
    }

    const quota = quotaMath.buildQuota(next.unitsUsed, next.adGrants, this.limits);
    return Response.json({ granted, quota });
  }

  async handlePeek(date) {
    const stored = await this.state.storage.get(STORAGE_KEY);
    const current = normalizeEntry(stored, date);
    const quota = quotaMath.buildQuota(current.unitsUsed, current.adGrants, this.limits);
    return Response.json(quota);
  }
}
