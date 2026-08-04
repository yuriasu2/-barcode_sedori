'use strict';

/**
 * Cloudflare Workers 用エントリポイント。
 * Render用の src/index.js とは独立して並行稼働する(Render動作は無改修)。
 *
 * 静的アセット(/, /assets/*)は wrangler.jsonc の assets 設定(run_worker_first)により
 * Worker手前で Cloudflare が直接配信するため、ここでの分岐は不要。
 */

// Durable Object本体を再エクスポートする(Workersランタイムがクラスを見つけるために必須。
// wrangler.jsonc の durable_objects.bindings[].class_name と一致させている)。
export { DeviceQuotaDO } from './quotaDurableObject.js';
// Keepaスロットル(共有キーのトークン推定+適応ブレーキ)のDO。グローバルに1つ。
export { KeepaThrottleDO } from './keepaThrottleDurableObject.js';

let routesPromise = null;

function loadRoutes() {
  if (!routesPromise) {
    // routes.js(が読み込むdeviceQuota.js)はモジュール読込時にprocess.env.BASE_DAILY_UNITS等を
    // 読むため、env→process.env コピーの後まで読込を遅延させる(初回リクエスト時のみimport)。
    routesPromise = import('./routes.js');
  }
  return routesPromise;
}

export default {
  async fetch(request, env, ctx) {
    // 初回リクエスト時に一度だけ、envバインディングの文字列値を process.env にコピーする。
    // nodejs_compat フラグにより process が存在するため、routes.js 等の process.env 参照がそのまま動く。
    for (const [k, v] of Object.entries(env)) {
      if (typeof v === 'string') process.env[k] = v;
    }

    // KVバインディング(オブジェクト)はprocess.envへコピーできない(文字列専用)ため、
    // globalThisへ橋渡しする。routes.js側は globalThis.__adsKv を直接参照する
    // (envをroutes.jsまで引き回す既存の仕組みが無いための簡易な受け渡し)。
    globalThis.__adsKv = env.ADS_CONFIG || null;

    // 無料枠ユニットのDurable Objectバインディング。deviceQuota.js側は
    // globalThis.__quotaDO を直接参照する(__adsKvと同じ簡易な受け渡し方式)。
    globalThis.__quotaDO = env.DEVICE_QUOTA || null;

    // Keepaスロットルのバインディング。keepaThrottle.js側がglobalThis経由で参照する
    // (__quotaDOと同じ簡易な受け渡し方式)。
    globalThis.__keepaThrottleDO = env.KEEPA_THROTTLE || null;

    const url = new URL(request.url);

    // /health は routes.js に依存させず即応させる(index.jsと同じ挙動)
    if (request.method === 'GET' && url.pathname === '/health') {
      return new Response(JSON.stringify({ status: 'ok' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json; charset=utf-8' },
      });
    }

    // routes.js は CommonJS(module.exports = router)。バンドラのESM相互運用により
    // 名前空間の default に本体が入る場合と、プロパティが直接コピーされる場合の両方に対応する。
    const routesModule = await loadRoutes();
    const router = routesModule.default || routesModule;
    return router.fetchHandler()(request);
  },
};
