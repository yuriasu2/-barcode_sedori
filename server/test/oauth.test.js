'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const oauth = require('../src/oauth');

const TEST_SECRET = 'test-oauth-state-secret';

// 注意: fnが非同期(Promiseを返す)場合、finally節がfnの内部処理(awaitを跨ぐ箇所)より
// 先に実行されてしまうと、fnの途中でprocess.envが元に戻ってしまう(_createState/
// _verifyAndConsumeStateはcrypto.subtle呼び出しでawaitを挟むため特に問題になる)。
// そのためwithEnv自体をasyncにし、fn()の結果を必ずawaitしてから env を復元する。
async function withEnv(vars, fn) {
  const saved = {};
  for (const key of Object.keys(vars)) {
    saved[key] = process.env[key];
    if (vars[key] === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = vars[key];
    }
  }
  try {
    return await fn();
  } finally {
    for (const key of Object.keys(saved)) {
      if (saved[key] === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = saved[key];
      }
    }
  }
}

function createMockRes() {
  const res = {
    statusCode: 200,
    body: null,
    headers: {},
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(payload) {
      this.body = payload;
      return this;
    },
    html(str) {
      this.body = str;
      return this;
    },
    redirect(url) {
      this.statusCode = this.statusCode === 200 ? 302 : this.statusCode;
      this.headers.Location = url;
      return this;
    },
  };
  return res;
}

function createMockReq({ query = {}, headers = {} } = {}) {
  return { query, headers, method: 'GET' };
}

// ---------------------------------------------------------------------------
// state生成・検証・改ざん・期限切れ
//
// 新方式(自己完結トークン: `<issuedAtMs>.<nonce>.<hmacHex>`)では、stateの真正性は
// OAUTH_STATE_SECRETによるHMAC署名のみで担保する。サーバー側の状態(Map/DO)を
// 持たないため、「一度きりの消費」ではなく「署名が正しく、かつTTL以内であるか」だけを
// 検証する(oauth.js冒頭コメント参照)。
// ---------------------------------------------------------------------------

test('oauth._createState: OAUTH_STATE_SECRET設定時、署名付きstateを生成できる', async () => {
  await withEnv({ OAUTH_STATE_SECRET: TEST_SECRET }, async () => {
    const state = await oauth._createState();
    assert.equal(typeof state, 'string');
    const parts = state.split('.');
    assert.equal(parts.length, 3);
    const [issuedAtStr, nonce, sigHex] = parts;
    assert.ok(Number.isFinite(Number(issuedAtStr)));
    assert.match(nonce, /^[0-9a-f]{32}$/);
    assert.match(sigHex, /^[0-9a-f]+$/);
  });
});

test('oauth._createState: OAUTH_STATE_SECRET未設定ならnullを返す', async () => {
  await withEnv({ OAUTH_STATE_SECRET: undefined }, async () => {
    const state = await oauth._createState();
    assert.equal(state, null);
  });
});

test('oauth._verifyAndConsumeState: 正しく生成されたstateは有効(何度検証しても有効=自己完結トークンのため消費されない)', async () => {
  await withEnv({ OAUTH_STATE_SECRET: TEST_SECRET }, async () => {
    const state = await oauth._createState();
    assert.equal(await oauth._verifyAndConsumeState(state), true);
    assert.equal(await oauth._verifyAndConsumeState(state), true);
  });
});

test('oauth._verifyAndConsumeState: 存在しない(形式が不正な)stateは無効', async () => {
  await withEnv({ OAUTH_STATE_SECRET: TEST_SECRET }, async () => {
    assert.equal(await oauth._verifyAndConsumeState('nonexistent-state-xxxx'), false);
    assert.equal(await oauth._verifyAndConsumeState(''), false);
    assert.equal(await oauth._verifyAndConsumeState(null), false);
  });
});

test('oauth._verifyAndConsumeState: 改ざんしたstateは拒否される(署名部分を書き換え)', async () => {
  await withEnv({ OAUTH_STATE_SECRET: TEST_SECRET }, async () => {
    const state = await oauth._createState();
    const [issuedAtStr, nonce, sigHex] = state.split('.');
    // 署名の先頭1文字を別の16進文字へ変える(同じ長さを保ったまま改ざん)。
    const tamperedChar = sigHex[0] === 'a' ? 'b' : 'a';
    const tamperedSig = tamperedChar + sigHex.slice(1);
    const tampered = `${issuedAtStr}.${nonce}.${tamperedSig}`;
    assert.equal(await oauth._verifyAndConsumeState(tampered), false);
  });
});

test('oauth._verifyAndConsumeState: nonceを書き換えたstateも拒否される(署名対象の改ざん)', async () => {
  await withEnv({ OAUTH_STATE_SECRET: TEST_SECRET }, async () => {
    const state = await oauth._createState();
    const [issuedAtStr, nonce, sigHex] = state.split('.');
    const tamperedNonce = nonce.split('').reverse().join('');
    const tampered = `${issuedAtStr}.${tamperedNonce}.${sigHex}`;
    assert.equal(await oauth._verifyAndConsumeState(tampered), false);
  });
});

test('oauth._verifyAndConsumeState: TTL(STATE_TTL_MS)超過は拒否される', async () => {
  await withEnv({ OAUTH_STATE_SECRET: TEST_SECRET }, async () => {
    const expiredIssuedAt = Date.now() - oauth.STATE_TTL_MS - 1000;
    const state = await oauth._createState(expiredIssuedAt);
    assert.equal(await oauth._verifyAndConsumeState(state), false);
  });
});

test('oauth._verifyAndConsumeState: 別のOAUTH_STATE_SECRETで生成されたstateは拒否される', async () => {
  const state = await withEnv({ OAUTH_STATE_SECRET: 'secret-a' }, () => oauth._createState());
  await withEnv({ OAUTH_STATE_SECRET: 'secret-b' }, async () => {
    assert.equal(await oauth._verifyAndConsumeState(state), false);
  });
});

test('oauth._verifyAndConsumeState: OAUTH_STATE_SECRET未設定なら検証も常に無効', async () => {
  const state = await withEnv({ OAUTH_STATE_SECRET: TEST_SECRET }, () => oauth._createState());
  await withEnv({ OAUTH_STATE_SECRET: undefined }, async () => {
    assert.equal(await oauth._verifyAndConsumeState(state), false);
  });
});

// ---------------------------------------------------------------------------
// GET /oauth/login
// ---------------------------------------------------------------------------

test('handleOAuthLogin: SPAPI_APP_IDが未設定なら500', async () => {
  await withEnv({ SPAPI_APP_ID: undefined, OAUTH_STATE_SECRET: TEST_SECRET }, async () => {
    const req = createMockReq();
    const res = createMockRes();
    await oauth.handleOAuthLogin(req, res);
    assert.equal(res.statusCode, 500);
    assert.equal(typeof res.body, 'string');
    assert.match(res.body, /SPAPI_APP_ID/);
  });
});

test('handleOAuthLogin: OAUTH_STATE_SECRET未設定なら503(フェイルセーフ。署名なしでは通さない)', async () => {
  await withEnv(
    { SPAPI_APP_ID: 'test-app-id', OAUTH_STATE_SECRET: undefined },
    async () => {
      const req = createMockReq();
      const res = createMockRes();
      await oauth.handleOAuthLogin(req, res);
      assert.equal(res.statusCode, 503);
      assert.equal(typeof res.body, 'string');
    }
  );
});

test('handleOAuthLogin: SPAPI_APP_ID・OAUTH_STATE_SECRET設定時はSeller Central認可URLへ302リダイレクト', async () => {
  await withEnv(
    {
      SPAPI_APP_ID: 'test-app-id',
      SELLER_CENTRAL_URL: 'https://sellercentral.amazon.co.jp',
      OAUTH_STATE_SECRET: TEST_SECRET,
    },
    async () => {
      const req = createMockReq();
      const res = createMockRes();
      await oauth.handleOAuthLogin(req, res);

      assert.equal(res.statusCode, 302);
      const location = res.headers.Location;
      assert.equal(typeof location, 'string');
      assert.match(location, /^https:\/\/sellercentral\.amazon\.co\.jp\/apps\/authorize\/consent\?/);
      assert.match(location, /application_id=test-app-id/);
      assert.match(location, /state=\d+\.[0-9a-f]{32}\.[0-9a-f]+/);
      assert.match(location, /version=beta/);
    }
  );
});

// ---------------------------------------------------------------------------
// GET /oauth/callback
// ---------------------------------------------------------------------------

test('handleOAuthCallback: 存在しないstateは403', async () => {
  await withEnv({ OAUTH_STATE_SECRET: TEST_SECRET }, async () => {
    const req = createMockReq({
      query: { state: 'invalid-state', spapi_oauth_code: 'x', selling_partner_id: 'y' },
    });
    const res = createMockRes();
    await oauth.handleOAuthCallback(req, res);
    assert.equal(res.statusCode, 403);
    assert.equal(typeof res.body, 'string');
  });
});

test('handleOAuthCallback: LWA交換成功時、HTMLにディープリンクとrefresh_tokenが含まれる', async (t) => {
  const originalFetch = global.fetch;
  global.fetch = async () => ({
    ok: true,
    status: 200,
    json: async () => ({ access_token: 'test-access-token', refresh_token: 'test-refresh-token' }),
  });

  t.after(() => {
    global.fetch = originalFetch;
  });

  await withEnv(
    {
      LWA_CLIENT_ID: 'env-client-id',
      LWA_CLIENT_SECRET: 'env-client-secret',
      OAUTH_STATE_SECRET: TEST_SECRET,
    },
    async () => {
      const state = await oauth._createState();
      const req = createMockReq({
        query: { state, spapi_oauth_code: 'auth-code-xyz', selling_partner_id: 'SP123' },
      });
      const res = createMockRes();
      await oauth.handleOAuthCallback(req, res);

      assert.equal(res.statusCode, 200);
      assert.equal(typeof res.body, 'string');
      assert.match(res.body, /barcodesedori:\/\/spapi-auth/);
      assert.match(res.body, new RegExp(`refresh_token=${encodeURIComponent('test-refresh-token')}`));
      // 機密情報(client_secret)がHTMLに含まれないこと
      assert.doesNotMatch(res.body, /env-client-secret/);
    }
  );
});

test('handleOAuthCallback: LWA交換失敗時(res.ok=false)は502でエラーHTML、機密情報を含まない', async (t) => {
  const originalFetch = global.fetch;
  global.fetch = async () => ({
    ok: false,
    status: 400,
    json: async () => ({ error: 'invalid_grant' }),
  });

  t.after(() => {
    global.fetch = originalFetch;
  });

  await withEnv(
    {
      LWA_CLIENT_ID: 'env-client-id',
      LWA_CLIENT_SECRET: 'env-client-secret',
      OAUTH_STATE_SECRET: TEST_SECRET,
    },
    async () => {
      const state = await oauth._createState();
      const req = createMockReq({
        query: { state, spapi_oauth_code: 'auth-code-xyz', selling_partner_id: 'SP123' },
      });
      const res = createMockRes();
      await oauth.handleOAuthCallback(req, res);

      assert.equal(res.statusCode, 502);
      assert.equal(typeof res.body, 'string');
      assert.doesNotMatch(res.body, /env-client-secret/);
    }
  );
});
