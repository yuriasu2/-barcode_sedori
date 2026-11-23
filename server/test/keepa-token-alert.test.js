'use strict';

const test = require('node:test');
const assert = require('node:assert');

const keepaThrottle = require('../src/keepaThrottle');
const { maybeAlertLowTokens } = require('../src/keepaTokenAlert');

/** fetchをモックし、Slack Webhook・環境変数・時刻を各テスト後に復元する。 */
function setup(t, { webhook = 'https://hooks.slack.test/secret', fetchImpl } = {}) {
  const saved = {
    url: process.env.SLACK_WEBHOOK_URL,
    th: process.env.KEEPA_ALERT_THRESHOLD,
    fetch: globalThis.fetch,
    now: Date.now,
  };
  if (webhook) process.env.SLACK_WEBHOOK_URL = webhook;
  else delete process.env.SLACK_WEBHOOK_URL;
  delete process.env.KEEPA_ALERT_THRESHOLD;
  keepaThrottle._setDurableBinding(null);
  keepaThrottle._resetForTest();
  const calls = [];
  globalThis.fetch = fetchImpl || (async (url, opts) => {
    calls.push({ url, body: JSON.parse(opts.body) });
    return { ok: true, status: 200 };
  });
  t.after(() => {
    for (const [k, v] of [['SLACK_WEBHOOK_URL', saved.url], ['KEEPA_ALERT_THRESHOLD', saved.th]]) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
    globalThis.fetch = saved.fetch;
    Date.now = saved.now;
    keepaThrottle._setDurableBinding(undefined);
    keepaThrottle._resetForTest();
  });
  return calls;
}

test('しきい値未満なら1回送る(負数=枯渇も対象)', async (t) => {
  const calls = setup(t);
  await maybeAlertLowTokens(59);
  assert.equal(calls.length, 1);
  assert.match(calls[0].body.text, /残り 59 トークン/);
  assert.match(calls[0].body.text, /JST/);
  keepaThrottle._resetForTest();
  await maybeAlertLowTokens(-3);
  assert.equal(calls.length, 2);
});

test('1時間以内の2回目は送らず、1時間後は再び送る', async (t) => {
  const calls = setup(t);
  let now = 1_000_000_000_000;
  Date.now = () => now;
  await maybeAlertLowTokens(10);
  now += 59 * 60 * 1000;
  await maybeAlertLowTokens(5);
  assert.equal(calls.length, 1);
  now += 2 * 60 * 1000;
  await maybeAlertLowTokens(5);
  assert.equal(calls.length, 2);
});

test('しきい値以上・非数値では送らず、ゲート枠も消費しない', async (t) => {
  const calls = setup(t);
  await maybeAlertLowTokens(60);
  await maybeAlertLowTokens(500);
  await maybeAlertLowTokens(undefined);
  await maybeAlertLowTokens(NaN);
  assert.equal(calls.length, 0);
  await maybeAlertLowTokens(59);
  assert.equal(calls.length, 1);
});

test('KEEPA_ALERT_THRESHOLDで上書きできる', async (t) => {
  const calls = setup(t);
  process.env.KEEPA_ALERT_THRESHOLD = '100';
  await maybeAlertLowTokens(80);
  assert.equal(calls.length, 1);
});

test('SLACK_WEBHOOK_URL未設定なら何もしない', async (t) => {
  const calls = setup(t, { webhook: null });
  await maybeAlertLowTokens(1);
  assert.equal(calls.length, 0);
});

test('fetchが失敗しても例外を投げず、URLをログに出さない', async (t) => {
  const warns = [];
  const origWarn = console.warn;
  console.warn = (...a) => warns.push(a.join(' '));
  t.after(() => { console.warn = origWarn; });
  setup(t, { fetchImpl: async () => { throw new Error('network down'); } });
  await assert.doesNotReject(() => maybeAlertLowTokens(1));
  assert.ok(warns.length >= 1);
  assert.ok(!warns.join('\n').includes('hooks.slack.test'));
});

test('DO経路: alert-gateの判定結果に従う', async (t) => {
  const calls = setup(t);
  const gateCalls = [];
  let send = true;
  keepaThrottle._setDurableBinding({
    idFromName: (n) => ({ n }),
    get: () => ({
      fetch: async (url) => {
        gateCalls.push(url);
        return new Response(JSON.stringify({ send }), { status: 200 });
      },
    }),
  });
  await maybeAlertLowTokens(1);
  send = false;
  await maybeAlertLowTokens(1);
  assert.equal(calls.length, 1);
  assert.ok(gateCalls[0].includes('/alert-gate'));
});

test('DO障害時は送らず例外も出さない', async (t) => {
  const calls = setup(t);
  keepaThrottle._setDurableBinding({
    idFromName: (n) => ({ n }),
    get: () => ({ fetch: async () => { throw new Error('DO down'); } }),
  });
  await assert.doesNotReject(() => maybeAlertLowTokens(1));
  assert.equal(calls.length, 0);
});
