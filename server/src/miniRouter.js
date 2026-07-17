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
        binary(buf, contentType) {
          res.setHeader('Content-Type', contentType || 'application/octet-stream');
          res.end(buf);
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

  /**
   * Cloudflare Workers 等、Web標準 Request/Response を使う実行環境向けのハンドラを返す。
   * (request: Request) => Promise<Response> という関数。
   * 既存の handler()(Node req/res用)はそのまま残し、これは並行で追加するアダプタ。
   */
  fetchHandler() {
    return async (request) => {
      const url = new URL(request.url);
      const route = this.match(request.method, url.pathname);

      let status = 200;
      let body;
      let headers = {};

      const resCollector = {
        status(code) {
          status = code;
          return resCollector;
        },
        json(payload) {
          headers['Content-Type'] = 'application/json; charset=utf-8';
          body = JSON.stringify(payload);
          return resCollector;
        },
        redirect(location) {
          if (!status || status === 200) status = 302;
          headers['Location'] = location;
          body = undefined;
          return resCollector;
        },
        html(str) {
          headers['Content-Type'] = 'text/html; charset=utf-8';
          body = str;
          return resCollector;
        },
        binary(buf, contentType) {
          headers['Content-Type'] = contentType || 'application/octet-stream';
          body = buf;
          return resCollector;
        },
      };

      if (!route) {
        resCollector.status(404).json({ error: 'not_found' });
        return new Response(body, { status, headers });
      }

      const query = Object.fromEntries(url.searchParams);

      const reqHeaders = {};
      for (const [key, value] of request.headers) {
        reqHeaders[key.toLowerCase()] = value;
      }

      let reqBody = undefined;
      if (request.method === 'POST') {
        reqBody = await request.json().catch(() => ({}));
      }

      const req = {
        method: request.method,
        url: request.url,
        query,
        body: reqBody,
        headers: reqHeaders,
      };

      try {
        await route.handler(req, resCollector);
      } catch (err) {
        resCollector.status(500).json({ error: 'internal_error', message: err.message });
      }

      return new Response(body, { status, headers });
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
