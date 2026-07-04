'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const { tryServeStatic, ASSETS_DIR } = require('../src/staticServer');

function createMockRes() {
  const chunks = [];
  const res = {
    statusCode: 200,
    headers: {},
    ended: false,
    setHeader(key, value) {
      this.headers[key] = value;
    },
    end(data) {
      if (data) chunks.push(data);
      this.ended = true;
      this.body = Buffer.concat(chunks.map((c) => (Buffer.isBuffer(c) ? c : Buffer.from(c))));
    },
  };
  return res;
}

function waitEnded(res) {
  return new Promise((resolve) => {
    const check = () => {
      if (res.ended) return resolve();
      setImmediate(check);
    };
    check();
  });
}

test('tryServeStatic: GET / はindex.htmlをtext/htmlで返す', async () => {
  const req = { method: 'GET' };
  const res = createMockRes();
  const handled = tryServeStatic(req, res, '/');
  assert.equal(handled, true);
  await waitEnded(res);
  assert.equal(res.statusCode, 200);
  assert.match(res.headers['Content-Type'], /text\/html/);
  assert.match(res.body.toString("utf8"), /バーコードせどり/);
});

test('tryServeStatic: GET /other は静的配信対象外でfalseを返す(既存ルーティングへフォールバック)', () => {
  const req = { method: 'GET' };
  const res = createMockRes();
  const handled = tryServeStatic(req, res, '/api/search');
  assert.equal(handled, false);
});

test('tryServeStatic: GET /oauth/login は静的配信対象外でfalseを返す', () => {
  const req = { method: 'GET' };
  const res = createMockRes();
  const handled = tryServeStatic(req, res, '/oauth/login');
  assert.equal(handled, false);
});

test('tryServeStatic: GET /health は静的配信対象外でfalseを返す', () => {
  const req = { method: 'GET' };
  const res = createMockRes();
  const handled = tryServeStatic(req, res, '/health');
  assert.equal(handled, false);
});

test('tryServeStatic: 存在しないassetは404', async () => {
  const req = { method: 'GET' };
  const res = createMockRes();
  const handled = tryServeStatic(req, res, '/assets/does-not-exist.png');
  assert.equal(handled, true);
  await waitEnded(res);
  assert.equal(res.statusCode, 404);
});

test('tryServeStatic: パストラバーサル(../)を含むファイル名は404', async () => {
  const req = { method: 'GET' };
  const res = createMockRes();
  const handled = tryServeStatic(req, res, '/assets/..%2Fsecret');
  assert.equal(handled, true);
  await waitEnded(res);
  assert.equal(res.statusCode, 404);
});

test('tryServeStatic: 素の "/assets/../secret" 相当のパスも404', async () => {
  const req = { method: 'GET' };
  const res = createMockRes();
  // path.normalizeされる前提でstaticServerに渡ってくる想定だが、
  // 直接 ../secret 形式のfilenameが渡ってきても拒否されることを確認
  const handled = tryServeStatic(req, res, '/assets/../secret');
  assert.equal(handled, true);
  await waitEnded(res);
  assert.equal(res.statusCode, 404);
});

test('tryServeStatic: 許可されていない拡張子(.js等)は404', async () => {
  const req = { method: 'GET' };
  const res = createMockRes();
  const handled = tryServeStatic(req, res, '/assets/evil.js');
  assert.equal(handled, true);
  await waitEnded(res);
  assert.equal(res.statusCode, 404);
});

test('tryServeStatic: 拡張子なしファイル名は404', async () => {
  const req = { method: 'GET' };
  const res = createMockRes();
  const handled = tryServeStatic(req, res, '/assets/noext');
  assert.equal(handled, true);
  await waitEnded(res);
  assert.equal(res.statusCode, 404);
});

test('tryServeStatic: 実在するpngアセットはimage/pngで返す', async () => {
  const tmpFile = path.join(ASSETS_DIR, '__test_temp__.png');
  fs.writeFileSync(tmpFile, Buffer.from([0x89, 0x50, 0x4e, 0x47]));

  try {
    const req = { method: 'GET' };
    const res = createMockRes();
    const handled = tryServeStatic(req, res, '/assets/__test_temp__.png');
    assert.equal(handled, true);
    await waitEnded(res);
    assert.equal(res.statusCode, 200);
    assert.match(res.headers['Content-Type'], /image\/png/);
  } finally {
    fs.unlinkSync(tmpFile);
  }
});

test('tryServeStatic: POST /assets/foo.png はfalse(GET以外は静的配信の対象外)', () => {
  const req = { method: 'POST' };
  const res = createMockRes();
  const handled = tryServeStatic(req, res, '/assets/foo.png');
  assert.equal(handled, false);
});
