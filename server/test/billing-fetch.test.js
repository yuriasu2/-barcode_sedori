'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

test('Workers billing transport preserves OCSP bytes, headers and HTTP failures', async () => {
  const { default: send, Headers } = require('../src/billing/workers-fetch');
  const original = globalThis.fetch;
  try {
    const bytes = Buffer.from([0, 128, 255, 48, 2]);
    globalThis.fetch = async (url, options) => {
      assert.equal(url, 'http://ocsp.test/');
      assert.equal(options.method, 'POST');
      assert.equal(options.headers.get('content-type'), 'application/ocsp-request');
      assert.deepEqual(options.body, bytes);
      assert.equal(options.timeout, undefined);
      assert.ok(options.signal instanceof AbortSignal);
      return new Response(bytes, { status: 503 });
    };
    const response = await send('http://ocsp.test/', { method: 'POST', headers: new Headers({ 'Content-Type': 'application/ocsp-request' }), body: bytes, timeout: 30000 });
    assert.equal(response.status, 503);
    assert.equal(response.ok, false, 'OCSP HTTP failures must not become success');
    assert.deepEqual(await response.buffer(), bytes);
  } finally { globalThis.fetch = original; }
});

test('Workers billing transport keeps cancellation and bounds a stalled response', async () => {
  const { default: send } = require('../src/billing/workers-fetch');
  const original = globalThis.fetch;
  const keepAlive = setInterval(() => {}, 1000);
  try {
    globalThis.fetch = async (_url, { signal }) => new Promise((resolve, reject) => {
      if (signal.aborted) return reject(signal.reason);
      signal.addEventListener('abort', () => reject(signal.reason), { once: true });
    });
    await assert.rejects(send('http://ocsp.test/', { timeout: 10 }), { name: 'TimeoutError' });
    await assert.rejects(send('http://ocsp.test/', { timeout: 30000, signal: AbortSignal.abort() }), { name: 'AbortError' });
  } finally { clearInterval(keepAlive); globalThis.fetch = original; }
});

test('all Worker builds alias the Apple library transport', () => {
  for (const name of ['wrangler.jsonc', 'wrangler.staging.jsonc', 'test/worker/wrangler.json']) {
    const config = fs.readFileSync(path.join(__dirname, '..', name), 'utf8');
    assert.match(config, /"node-fetch"\s*:\s*"[^\"]*billing\/workers-fetch\.js"/);
  }
});
