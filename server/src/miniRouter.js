'use strict';

/**
 * Express相当の最小限の機能(GET/POSTルーティング, クエリパース, JSONボディパース)を
 * 標準 http モジュールだけで実現する超軽量ルーター。
 * 依存ゼロ構成(express未使用)のためのExpress風アダプタ。
 */

const { URL } = require('url');

class MiniRouter {
  constructor() {
    this.routes = []; // { method, pattern, handler }
  }

  get(pathPattern, handler) {
    this.routes.push({ method: 'GET', pathPattern, handler });
  }

  post(pathPattern, handler) {
    this.routes.push({ method: 'POST', pathPattern, handler });
  }

  match(method, pathname) {
    return this.routes.find((r) => r.method === method && r.pathPattern === pathname);
  }

  /**
   * http.createServer 用のリクエストハンドラを返す。
   */
  handler() {
    return async (req, res) => {
      const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
      const route = this.match(req.method, url.pathname);

      const jsonRes = {
        status(code) {
          res.statusCode = code;
          return jsonRes;
        },
        json(body) {
          const payload = JSON.stringify(body);
          res.setHeader('Content-Type', 'application/json; charset=utf-8');
          res.end(payload);
        },
        redirect(location) {
          if (!res.statusCode || res.statusCode === 200) res.statusCode = 302;
          res.setHeader('Location', location);
          res.end();
          return jsonRes;
        },
        html(str) {
          res.setHeader('Content-Type', 'text/html; charset=utf-8');
          res.end(str);
          return jsonRes;
        },
      };

      if (!route) {
        jsonRes.status(404).json({ error: 'not_found' });
        return;
      }

      const query = {};
      for (const [key, value] of url.searchParams.entries()) {
        query[key] = value;
      }

      let body = undefined;
      if (req.method === 'POST') {
        body = await readJsonBody(req).catch(() => ({}));
      }

      const request = { query, body, headers: req.headers, method: req.method, url: req.url };

      try {
        await route.handler(request, jsonRes);
      } catch (err) {
        jsonRes.status(500).json({ error: 'internal_error', message: err.message });
      }
    };
  }
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (chunk) => {
      data += chunk;
      if (data.length > 5 * 1024 * 1024) {
        reject(new Error('payload_too_large'));
        req.destroy();
      }
    });
    req.on('end', () => {
      if (!data) return resolve({});
      try {
        resolve(JSON.parse(data));
      } catch (err) {
        reject(err);
      }
    });
    req.on('error', reject);
  });
}

module.exports = { MiniRouter };
