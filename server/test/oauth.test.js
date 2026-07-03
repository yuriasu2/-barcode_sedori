'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const oauth = require('../src/oauth');

function withEnv(vars, fn) {
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
    return fn();
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
// state生成・検証・期限切れ
// ---------------------------------------------------------------------------

test('oauth._createState: stateを生成でき、_verifyAndConsumeStateで一度だけ有効', () => {
  const state = oauth._createState();
  assert.equal(typeof state, 'string');
  assert.equal(state.length, 32); // randomBytes(16).toString('hex') => 32文字

  // 1回目は有効
  assert.equal(oauth._verifyAndConsumeState(state), true);
  // 消費済みなので2回目は無効
  assert.equal(oauth._verifyAndConsumeState(state), false);
});

test('oauth._verifyAndConsumeState: 存在しないstateは無効', () => {
  assert.equal(oauth._verifyAndConsumeState('nonexistent-state-xxxx'), false);
});

test('oauth._verifyAndConsumeState: 期限切れのstateは無効(テスト用フックでcreatedAtを過去に書き換え)', () => {
  const state = oauth._createState();
  oauth._expireStateForTest(state);
  assert.equal(oauth._verifyAndConsumeState(state), false);
});

// ---------------------------------------------------------------------------
// GET /oauth/login
// ---------------------------------------------------------------------------

test('handleOAuthLogin: SPAPI_APP_IDが未設定なら500', () => {
  withEnv({ SPAPI_APP_ID: undefined }, () => {
    const req = createMockReq();
    const res = createMockRes();
    oauth.handleOAuthLogin(req, res);
    assert.equal(res.statusCode, 500);
    assert.equal(typeof res.body, 'string');
    assert.match(res.body, /SPAPI_APP_ID/);
  });
});

test('handleOAuthLogin: SPAPI_APP_ID設定時はSeller Central認可URLへ302リダイレクト', () => {
  withEnv(
    {
      SPAPI_APP_ID: 'test-app-id',
      SELLER_CENTRAL_URL: 'https://sellercentral.amazon.co.jp',
    },
    () => {
      const req = createMockReq();
      const res = createMockRes();
      oauth.handleOAuthLogin(req, res);

      assert.equal(res.statusCode, 302);
      const location = res.headers.Location;
      assert.equal(typeof location, 'string');
      assert.match(location, /^https:\/\/sellercentral\.amazon\.co\.jp\/apps\/authorize\/consent\?/);
      assert.match(location, /application_id=test-app-id/);
      assert.match(location, /state=[0-9a-f]{32}/);
      assert.match(location, /version=beta/);
    }
  );
});

// ---------------------------------------------------------------------------
// GET /oauth/callback
// ---------------------------------------------------------------------------

test('handleOAuthCallback: 存在しないstateは403', async () => {
  const req = createMockReq({
    query: { state: 'invalid-state', spapi_oauth_code: 'x', selling_partner_id: 'y' },
  });
  const res = createMockRes();
  await oauth.handleOAuthCallback(req, res);
  assert.equal(res.statusCode, 403);
  assert.equal(typeof res.body, 'string');
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
    },
    async () => {
      const state = oauth._createState();
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
    },
    async () => {
      const state = oauth._createState();
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
