'use strict';

const http = require('http');
const { URL } = require('url');
const { loadEnv } = require('./env');

loadEnv();

const routes = require('./routes');
const { tryServeStatic } = require('./staticServer');

const PORT = process.env.PORT || 3000;

const server = http.createServer((req, res) => {
  // /health は routes.js に依存させず即応させる
  if (req.method === 'GET' && req.url === '/health') {
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.end(JSON.stringify({ status: 'ok' }));
    return;
  }

  // ランディングページ(/)と静的アセット(/assets/*)を配信する。
  // /api/* /oauth/* はここに該当しないため、既存ルーティングへそのままフォールバックする。
  const { pathname } = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  if (tryServeStatic(req, res, pathname)) {
    return;
  }

  routes.handler()(req, res);
});

if (require.main === module) {
  server.listen(PORT, '0.0.0.0', () => {
    console.log(`barcode-sedori server listening on port ${PORT}`);
  });
}

module.exports = server;
