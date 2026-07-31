'use strict';

/**
 * AdMob SSV(サーバーサイド検証)のテスト。
 *
 * 実際のGoogle検証鍵は使えないため、テスト内でP-256鍵ペアを生成し、
 * admobSsv._setKeysForTest() でその公開鍵を検証鍵一覧としてモジュールへ注入する。
 * crypto.subtle.sign が返すECDSA署名はraw形式(r||sの64バイト)なので、テスト側で
 * DER形式へ変換してからbase64url化する(admobSsv.derToRawSignatureの逆変換)。
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const { webcrypto } = require('node:crypto');

const admobSsv = require('../src/admobSsv');

const subtle = webcrypto.subtle;

// ---------------------------------------------------------------------------
// テスト用の鍵ペア・署名ヘルパー
// ---------------------------------------------------------------------------

const TEST_KEY_ID = 12345;

let keyPairPromise = null;
function getKeyPair() {
  if (!keyPairPromise) {
    keyPairPromise = subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  }
  return keyPairPromise;
}

async function getTestKeyEntry() {
  const { publicKey } = await getKeyPair();
  const spki = await subtle.exportKey('spki', publicKey);
  return { keyId: TEST_KEY_ID, base64: Buffer.from(spki).toString('base64') };
}

/** DERのINTEGER1個分の中身を、符号ビット衝突を避けつつ組み立てる(先頭が0x80以上なら0x00を付与)。 */
function encodeDerInteger(bytes) {
  let b = Buffer.from(bytes);
  let i = 0;
  while (i < b.length - 1 && b[i] === 0) i += 1;
  b = b.slice(i);
  if (b[0] & 0x80) {
    b = Buffer.concat([Buffer.from([0x00]), b]);
  }
  return b;
}

function encodeDerLength(len) {
  if (len < 0x80) return Buffer.from([len]);
  if (len < 0x100) return Buffer.from([0x81, len]);
  return Buffer.from([0x82, (len >> 8) & 0xff, len & 0xff]);
}

/** raw形式(r||sの64バイト)のECDSA署名をDER形式へ変換する(admobSsv.derToRawSignatureの逆)。 */
function rawToDer(rawSig) {
  const r = rawSig.slice(0, 32);
  const s = rawSig.slice(32, 64);
  const rInt = encodeDerInteger(r);
  const sInt = encodeDerInteger(s);
  const rField = Buffer.concat([Buffer.from([0x02]), encodeDerLength(rInt.length), rInt]);
  const sField = Buffer.concat([Buffer.from([0x02]), encodeDerLength(sInt.length), sInt]);
  const body = Buffer.concat([rField, sField]);
  return Buffer.concat([Buffer.from([0x30]), encodeDerLength(body.length), body]);
}

function toBase64Url(buf) {
  return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function buildParams({ deviceId = 'DEVICE-1', transactionId = 'tx-1', timestamp = Date.now() } = {}) {
  return [
    ['ad_network', '5450213213286189855'],
    ['ad_unit', 'ca-app-pub-3940256099942544/5224354917'],
    ['custom_data', deviceId],
    ['reward_amount', '5'],
    ['reward_item', 'coins'],
    ['timestamp', String(timestamp)],
    ['transaction_id', transactionId],
  ];
}

function toUnsignedQuery(params) {
  return params.map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join('&');
}

/**
 * 実際のAdMob SSVコールバックと同じ形(パラメータはアルファベット順、末尾が
 * signature, key_idの順)の生クエリ文字列を、テスト用の秘密鍵で署名して組み立てる。
 * @param {object} [overrides] deviceId/transactionId/timestamp/keyId を上書きできる
 */
async function buildSignedQuery(overrides = {}) {
  const { privateKey } = await getKeyPair();
  const params = buildParams(overrides);
  const unsigned = toUnsignedQuery(params);
  const sigBuf = await subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, privateKey, new TextEncoder().encode(unsigned));
  const der = rawToDer(new Uint8Array(sigBuf));
  const sigB64Url = toBase64Url(der);
  const keyId = overrides.keyId !== undefined ? overrides.keyId : TEST_KEY_ID;
  return `${unsigned}&signature=${sigB64Url}&key_id=${keyId}`;
}

// ---------------------------------------------------------------------------
// derToRawSignature: DER→raw変換の単体テスト
// ---------------------------------------------------------------------------

test('derToRawSignature: r/sが1バイトでも64バイトの左詰めゼロ埋めになる', () => {
  // 0x30 0x06 | 0x02 0x01 0x01 (r=1) | 0x02 0x01 0x02 (s=2)
  const der = Buffer.from([0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02]);
  const raw = admobSsv.derToRawSignature(der);
  assert.equal(raw.length, 64);
  assert.equal(raw[31], 1);
  assert.equal(raw[63], 2);
  assert.ok(raw.slice(0, 31).every((b) => b === 0));
  assert.ok(raw.slice(32, 63).every((b) => b === 0));
});

test('derToRawSignature: 先頭0x00パディング付き33バイト整数も正しく32バイトになる', () => {
  const rBytes = Buffer.concat([Buffer.from([0x00]), Buffer.alloc(31, 0), Buffer.from([0xff])]); // 33バイト
  const sBytes = Buffer.concat([Buffer.from([0x00]), Buffer.alloc(31, 0), Buffer.from([0xaa])]); // 33バイト
  const body = Buffer.concat([
    Buffer.from([0x02, rBytes.length]), rBytes,
    Buffer.from([0x02, sBytes.length]), sBytes,
  ]);
  const der = Buffer.concat([Buffer.from([0x30, body.length]), body]);
  const raw = admobSsv.derToRawSignature(der);
  assert.equal(raw.length, 64);
  assert.equal(raw[31], 0xff);
  assert.equal(raw[63], 0xaa);
});

test('derToRawSignature: SEQUENCEの長さが長形式(0x81)でも解析できる', () => {
  const rBytes = Buffer.from([0x01]);
  const sBytes = Buffer.from([0x02]);
  const body = Buffer.concat([
    Buffer.from([0x02, rBytes.length]), rBytes,
    Buffer.from([0x02, sBytes.length]), sBytes,
  ]);
  const der = Buffer.concat([Buffer.from([0x30, 0x81, body.length]), body]);
  const raw = admobSsv.derToRawSignature(der);
  assert.equal(raw.length, 64);
  assert.equal(raw[31], 1);
  assert.equal(raw[63], 2);
});

test('derToRawSignature: SEQUENCEタグが無いと例外を投げる', () => {
  assert.throws(() => admobSsv.derToRawSignature(Buffer.from([0x00, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02])));
});

// ---------------------------------------------------------------------------
// verifySsv: 署名検証の単体テスト
// ---------------------------------------------------------------------------

test('verifySsv: 正しい署名はvalid:true', async (t) => {
  admobSsv._setKeysForTest([await getTestKeyEntry()]);
  t.after(() => admobSsv._setKeysForTest(null));

  const rawQuery = await buildSignedQuery();
  const result = await admobSsv.verifySsv(rawQuery);
  assert.equal(result.valid, true);
});

test('verifySsv: signed contentを1文字改ざんするとvalid:false', async (t) => {
  admobSsv._setKeysForTest([await getTestKeyEntry()]);
  t.after(() => admobSsv._setKeysForTest(null));

  const rawQuery = await buildSignedQuery();
  const tampered = rawQuery.replace('reward_amount=5', 'reward_amount=6');
  assert.notEqual(tampered, rawQuery);

  const result = await admobSsv.verifySsv(tampered);
  assert.equal(result.valid, false);
});

test('verifySsv: 未知のkey_idはvalid:false', async (t) => {
  admobSsv._setKeysForTest([await getTestKeyEntry()]);
  t.after(() => admobSsv._setKeysForTest(null));

  const rawQuery = await buildSignedQuery({ keyId: 99999 });
  const result = await admobSsv.verifySsv(rawQuery);
  assert.equal(result.valid, false);
  assert.equal(result.reason, 'unknown_key_id');
});

test('verifySsv: signatureパラメータが無いとvalid:false', async () => {
  const rawQuery = 'ad_network=1&ad_unit=x&custom_data=dev&reward_amount=5&reward_item=coins&timestamp=123&transaction_id=tx-1';
  const result = await admobSsv.verifySsv(rawQuery);
  assert.equal(result.valid, false);
  assert.equal(result.reason, 'signature_param_not_found');
});

test('verifySsv: 空文字列はvalid:false', async () => {
  const result = await admobSsv.verifySsv('');
  assert.equal(result.valid, false);
});

// ---------------------------------------------------------------------------
// base64UrlToBytes
// ---------------------------------------------------------------------------

test('base64UrlToBytes: web-safe文字(-, _)を正しくデコードする', () => {
  // 標準base64で "+/" を含む適当なバイト列を作り、base64url表現(-_、パディング無し)から
  // 正しく元のバイト列へ戻ることを確認する。
  const original = Buffer.from([0xfb, 0xff, 0xfe, 0x00, 0x01]);
  const std = original.toString('base64'); // '+/8=' 相当を含み得る
  const urlSafe = std.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const decoded = Buffer.from(admobSsv.base64UrlToBytes(urlSafe));
  assert.ok(decoded.equals(original));
});

// ---------------------------------------------------------------------------
// ルート結合テスト: GET /api/admob/ssv
// ---------------------------------------------------------------------------

const routes = require('../src/routes');

function createMockRes() {
  return {
    statusCode: 200,
    body: undefined,
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(body) {
      this.body = body;
      return this;
    },
  };
}

function reqFromRawQuery(rawQuery) {
  return {
    query: Object.fromEntries(new URLSearchParams(rawQuery)),
    headers: {},
    url: `/api/admob/ssv?${rawQuery}`,
  };
}

test('ルート GET /api/admob/ssv: 正しい署名で200・granted:true・quotaが+5される', async (t) => {
  routes.deviceQuota._reset();
  routes.admobSsv._setKeysForTest([await getTestKeyEntry()]);
  t.after(() => {
    routes.admobSsv._setKeysForTest(null);
    routes.deviceQuota._reset();
  });

  const deviceId = 'DEV-SSV-1';
  const rawQuery = await buildSignedQuery({ deviceId, transactionId: 'tx-100' });
  const route = routes.match('GET', '/api/admob/ssv');
  const res = createMockRes();
  await route.handler(reqFromRawQuery(rawQuery), res);

  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, { ok: true, granted: true, duplicate: false });

  const quota = await routes.deviceQuota.computeQuota(deviceId);
  assert.equal(quota.adGrantsToday, 1);
  assert.equal(quota.limit, 10); // base(5) + perAd(5) * 1
});

test('ルート GET /api/admob/ssv: 同じtransaction_idの2回目はduplicate:true・quotaは増えない', async (t) => {
  routes.deviceQuota._reset();
  routes.admobSsv._setKeysForTest([await getTestKeyEntry()]);
  t.after(() => {
    routes.admobSsv._setKeysForTest(null);
    routes.deviceQuota._reset();
  });

  const deviceId = 'DEV-SSV-2';
  const route = routes.match('GET', '/api/admob/ssv');
  const rawQuery = await buildSignedQuery({ deviceId, transactionId: 'tx-dup' });
  const req = reqFromRawQuery(rawQuery);

  const res1 = createMockRes();
  await route.handler(req, res1);
  assert.equal(res1.body.granted, true);
  assert.equal(res1.body.duplicate, false);

  // 同一コールバック(同じtransaction_id)がGoogleから再送されたケースを模す。
  const res2 = createMockRes();
  await route.handler(req, res2);
  assert.equal(res2.statusCode, 200); // 重複でも200(Googleにリトライさせないため)
  assert.equal(res2.body.granted, false);
  assert.equal(res2.body.duplicate, true);

  const quota = await routes.deviceQuota.computeQuota(deviceId);
  assert.equal(quota.adGrantsToday, 1); // 増えていない
});

test('ルート GET /api/admob/ssv: 署名が不正なら400', async (t) => {
  routes.admobSsv._setKeysForTest([await getTestKeyEntry()]);
  t.after(() => routes.admobSsv._setKeysForTest(null));

  const signed = await buildSignedQuery({ deviceId: 'DEV-SSV-3' });
  const tampered = signed.replace('reward_amount=5', 'reward_amount=999');
  const route = routes.match('GET', '/api/admob/ssv');
  const res = createMockRes();
  await route.handler(reqFromRawQuery(tampered), res);

  assert.equal(res.statusCode, 400);
  assert.equal(res.body.error, 'invalid_signature');
});

test('ルート GET /api/admob/ssv: 古いtimestampは400(署名自体は正しくても)', async (t) => {
  routes.admobSsv._setKeysForTest([await getTestKeyEntry()]);
  t.after(() => routes.admobSsv._setKeysForTest(null));

  const staleTimestamp = Date.now() - 2 * 60 * 60 * 1000; // 2時間前
  const rawQuery = await buildSignedQuery({ deviceId: 'DEV-SSV-4', timestamp: staleTimestamp });
  const route = routes.match('GET', '/api/admob/ssv');
  const res = createMockRes();
  await route.handler(reqFromRawQuery(rawQuery), res);

  assert.equal(res.statusCode, 400);
  assert.equal(res.body.error, 'stale_timestamp');
});

test('ルート GET /api/admob/ssv: クエリ文字列が無いと400(missing_query)', async () => {
  const route = routes.match('GET', '/api/admob/ssv');
  const res = createMockRes();
  await route.handler({ query: {}, headers: {}, url: '/api/admob/ssv' }, res);
  assert.equal(res.statusCode, 400);
  assert.equal(res.body.error, 'missing_query');
});

test('ルート GET /api/admob/ssv: custom_data(deviceId)が空なら400(missing_device)', async (t) => {
  routes.admobSsv._setKeysForTest([await getTestKeyEntry()]);
  t.after(() => routes.admobSsv._setKeysForTest(null));

  const rawQuery = await buildSignedQuery({ deviceId: '' });
  const route = routes.match('GET', '/api/admob/ssv');
  const res = createMockRes();
  await route.handler(reqFromRawQuery(rawQuery), res);

  assert.equal(res.statusCode, 400);
  assert.equal(res.body.error, 'missing_device');
});
