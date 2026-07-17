'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { MiniRouter } = require('../src/miniRouter');

test('fetchHandler: GETルートが一致した場合、jsonレスポンスを返す', async () => {
  const router = new MiniRouter();
  router.get('/ok', (req, res) => res.json({ ok: 1 }));

  const res = await router.fetchHandler()(new Request('http://localhost/ok'));

  assert.equal(res.status, 200);
  assert.equal(res.headers.get('Content-Type'), 'application/json; charset=utf-8');
  assert.deepEqual(await res.json(), { ok: 1 });
});

test('fetchHandler: 不一致パスは404 not_foundになる', async () => {
  const router = new MiniRouter();

  const res = await router.fetchHandler()(new Request('http://localhost/nope'));

  assert.equal(res.status, 404);
  assert.deepEqual(await res.json(), { error: 'not_found' });
});

test('fetchHandler: ヘッダーは小文字キーに正規化される', async () => {
  const router = new MiniRouter();
  let captured;
  router.get('/headers', (req, res) => {
    captured = req.headers['x-app-plan'];
    res.json({ plan: captured });
  });

  const res = await router.fetchHandler()(
    new Request('http://localhost/headers', { headers: { 'X-App-Plan': 'pro' } })
  );

  assert.equal(captured, 'pro');
  assert.deepEqual(await res.json(), { plan: 'pro' });
});

test('fetchHandler: クエリパラメータが正しくパースされる', async () => {
  const router = new MiniRouter();
  let captured;
  router.get('/search', (req, res) => {
    captured = req.query;
    res.json(req.query);
  });

  await router.fetchHandler()(new Request('http://localhost/search?code=123&source=keepa'));

  assert.equal(captured.code, '123');
  assert.equal(captured.source, 'keepa');
});

test('fetchHandler: binaryレスポンスがContent-Type付きバイト列になる', async () => {
  const router = new MiniRouter();
  const bytes = Buffer.from([1, 2, 3]);
  router.get('/image', (req, res) => res.binary(bytes, 'image/png'));

  const res = await router.fetchHandler()(new Request('http://localhost/image'));

  assert.equal(res.headers.get('Content-Type'), 'image/png');
  const buf = Buffer.from(await res.arrayBuffer());
  assert.deepEqual([...buf], [1, 2, 3]);
});

test('fetchHandler: redirectが302 + Locationヘッダーになる', async () => {
  const router = new MiniRouter();
  router.get('/go', (req, res) => res.redirect('https://example.com/x'));

  const res = await router.fetchHandler()(new Request('http://localhost/go'));

  assert.equal(res.status, 302);
  assert.equal(res.headers.get('Location'), 'https://example.com/x');
});

test('fetchHandler: ハンドラ内の例外は500 internal_errorになる', async () => {
  const router = new MiniRouter();
  router.get('/boom', () => {
    throw new Error('kaboom');
  });

  const res = await router.fetchHandler()(new Request('http://localhost/boom'));

  assert.equal(res.status, 500);
  const body = await res.json();
  assert.equal(body.error, 'internal_error');
});
