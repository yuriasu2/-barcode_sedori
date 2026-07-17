'use strict';

/**
 * Cloudflare Workers 用エントリポイント。
 * Render用の src/index.js とは独立して並行稼働する(Render動作は無改修)。
 *
 * 静的アセット(/, /assets/*)は wrangler.jsonc の assets 設定(run_worker_first)により
 * Worker手前で Cloudflare が直接配信するため、ここでの分岐は不要。
 */

let routesPromise = null;

function loadRoutes() {
  if (!routesPromise) {
    // routes.js はモジュール読込時に process.env.FREE_DEVICE_DAILY_LIMIT を読むため、
    // env→process.env コピーの後まで読込を遅延させる(初回リクエスト時のみimport)。
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
