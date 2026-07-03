'use strict';

/**
 * ランディングページ(server/public/index.html)と画像アセット(server/public/assets/)を
 * 配信するための最小限の静的ファイルサーバー。
 * 既存の /api/*, /oauth/*, /health ルーティングには一切影響しない
 * (index.js側でこれらのパスに該当しない場合のみ呼び出す想定)。
 */

const fs = require('fs');
const path = require('path');

const PUBLIC_DIR = path.join(__dirname, '..', 'public');
const ASSETS_DIR = path.join(PUBLIC_DIR, 'assets');
const INDEX_FILE = path.join(PUBLIC_DIR, 'index.html');

// 許可する拡張子とContent-Typeの対応表(画像系のみ)
const ALLOWED_ASSET_TYPES = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

/**
 * res(素のhttp.ServerResponse)にファイル内容を書き込む。
 */
function sendFile(res, filePath, contentType) {
  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.statusCode = 404;
      res.setHeader('Content-Type', 'text/plain; charset=utf-8');
      res.end('Not Found');
      return;
    }
    res.statusCode = 200;
    res.setHeader('Content-Type', contentType);
    res.end(data);
  });
}

function sendNotFound(res) {
  res.statusCode = 404;
  res.setHeader('Content-Type', 'text/plain; charset=utf-8');
  res.end('Not Found');
}

/**
 * GET / を処理する。index.htmlが存在すればHTMLを返し、無ければ404。
 */
function serveIndex(req, res) {
  sendFile(res, INDEX_FILE, 'text/html; charset=utf-8');
}

/**
 * GET /assets/:filename を処理する。
 * - ファイル名に '/' や '..' を含む場合は404(パストラバーサル対策)
 * - 許可された拡張子(png/jpg/jpeg/svg/ico)以外は404
 * - assetsディレクトリの直下のファイルのみ許可(サブディレクトリ不可)
 */
function serveAsset(req, res, rawFilename) {
  const filename = decodeURIComponent(rawFilename || '');

  if (!filename || filename.includes('/') || filename.includes('\\') || filename.includes('..')) {
    return sendNotFound(res);
  }

  const ext = path.extname(filename).toLowerCase();
  const contentType = ALLOWED_ASSET_TYPES[ext];
  if (!contentType) {
    return sendNotFound(res);
  }

  const resolved = path.join(ASSETS_DIR, filename);

  // 念のため、解決後のパスがassetsディレクトリ配下であることを再検証する
  const relative = path.relative(ASSETS_DIR, resolved);
  if (relative.startsWith('..') || path.isAbsolute(relative)) {
    return sendNotFound(res);
  }

  sendFile(res, resolved, contentType);
}

/**
 * リクエストが静的配信の対象かどうかを判定し、対象であればtrueを返しつつ処理する。
 * 対象でなければfalseを返す(呼び出し側は次のルーティングへフォールバックする)。
 */
function tryServeStatic(req, res, pathname) {
  if (req.method !== 'GET') return false;

  if (pathname === '/') {
    serveIndex(req, res);
    return true;
  }

  if (pathname.startsWith('/assets/')) {
    const rawFilename = pathname.slice('/assets/'.length);
    serveAsset(req, res, rawFilename);
    return true;
  }

  return false;
}

module.exports = { tryServeStatic, PUBLIC_DIR, ASSETS_DIR };
