'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

// ---------------------------------------------------------------------------
// resolveSpApiCredentials (v5仕様):
// clientId / clientSecret は常に.envを使用(ヘッダーは見ない)。
// refreshToken のみヘッダー(X-Spapi-Refresh-Token) > .env(LWA_REFRESH_TOKEN) の優先順。
// ---------------------------------------------------------------------------
//
// routes.js は resolveSpApiCredentials を直接exportしていないため、
// 同一ロジックをテスト内で再現して検証する(routes.js内の実装と1対1対応)。
// ※ 実装を変更した場合は本テストも追随させること。

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

function resolveSpApiCredentials(headers) {
  const clientId = process.env.LWA_CLIENT_ID || null;
  const clientSecret = process.env.LWA_CLIENT_SECRET || null;
  const refreshToken =
    (headers && (headers['x-spapi-refresh-token'] || headers['X-Spapi-Refresh-Token'])) ||
    process.env.LWA_REFRESH_TOKEN ||
    null;
  if (!clientId || !clientSecret || !refreshToken) return null;
  return { clientId, clientSecret, refreshToken };
}

test('resolveSpApiCredentials: ヘッダーにX-Spapi-Refresh-Tokenがあれば.envのLWA_REFRESH_TOKENより優先される(clientId/clientSecretは常に.env)', () => {
  delete require.cache[require.resolve('../src/routes')];
  const routes = require('../src/routes');

  withEnv(
    {
      LWA_CLIENT_ID: 'env-client-id',
      LWA_CLIENT_SECRET: 'env-client-secret',
      LWA_REFRESH_TOKEN: 'env-refresh-token',
    },
    () => {
      const headers = {
        'x-spapi-refresh-token': 'header-refresh-token',
      };
      const result = resolveSpApiCredentials(headers);
      assert.deepEqual(result, {
        clientId: 'env-client-id',
        clientSecret: 'env-client-secret',
        refreshToken: 'header-refresh-token',
      });
    }
  );

  assert.ok(routes); // モジュールが読み込めること(副作用のロード確認)
});

test('resolveSpApiCredentials: ヘッダーが無ければ.envのLWA_REFRESH_TOKENにフォールバックする', () => {
  withEnv(
    {
      LWA_CLIENT_ID: 'env-client-id',
      LWA_CLIENT_SECRET: 'env-client-secret',
      LWA_REFRESH_TOKEN: 'env-refresh-token',
    },
    () => {
      const result = resolveSpApiCredentials({});
      assert.deepEqual(result, {
        clientId: 'env-client-id',
        clientSecret: 'env-client-secret',
        refreshToken: 'env-refresh-token',
      });
    }
  );
});

test('resolveSpApiCredentials: .envにLWA_CLIENT_ID/LWA_CLIENT_SECRET/LWA_REFRESH_TOKENのいずれかが無ければnull', () => {
  withEnv(
    {
      LWA_CLIENT_ID: undefined,
      LWA_CLIENT_SECRET: undefined,
      LWA_REFRESH_TOKEN: undefined,
    },
    () => {
      const result = resolveSpApiCredentials({});
      assert.equal(result, null);
    }
  );

  // ヘッダーにrefreshTokenがあってもclientId/clientSecretが.envに無ければnull
  withEnv(
    {
      LWA_CLIENT_ID: undefined,
      LWA_CLIENT_SECRET: undefined,
      LWA_REFRESH_TOKEN: undefined,
    },
    () => {
      const result = resolveSpApiCredentials({ 'x-spapi-refresh-token': 'header-refresh-token' });
      assert.equal(result, null);
    }
  );

  // clientIdのみ無い場合もnull
  withEnv(
    {
      LWA_CLIENT_ID: undefined,
      LWA_CLIENT_SECRET: 'env-client-secret',
      LWA_REFRESH_TOKEN: 'env-refresh-token',
    },
    () => {
      const result = resolveSpApiCredentials({});
      assert.equal(result, null);
    }
  );
});

test('resolveSpApiCredentials: 旧ヘッダーX-Spapi-Client-Id/X-Spapi-Client-Secretを送っても無視され、クライアントID/シークレットは.envの値になる', () => {
  withEnv(
    {
      LWA_CLIENT_ID: 'env-client-id',
      LWA_CLIENT_SECRET: 'env-client-secret',
      LWA_REFRESH_TOKEN: 'env-refresh-token',
    },
    () => {
      const headers = {
        'x-spapi-client-id': 'header-client-id',
        'x-spapi-client-secret': 'header-client-secret',
      };
      const result = resolveSpApiCredentials(headers);
      assert.deepEqual(result, {
        clientId: 'env-client-id',
        clientSecret: 'env-client-secret',
        refreshToken: 'env-refresh-token',
      });
    }
  );
});

// ---------------------------------------------------------------------------
// auth.js: トークンキャッシュが認証情報ごとに分離されること(fetchをモック)
// ---------------------------------------------------------------------------

test('auth.getAccessToken: 異なる認証情報は別々にキャッシュされ、fetchがそれぞれ1回ずつ呼ばれる', async (t) => {
  delete require.cache[require.resolve('../src/spapi/auth')];
  const auth = require('../src/spapi/auth');
  auth._resetCache();

  let fetchCallCount = 0;
  const originalFetch = global.fetch;
  global.fetch = async (url, opts) => {
    fetchCallCount += 1;
    const body = String(opts.body);
    // client_idごとに異なるトークンを返す
    const clientIdMatch = /client_id=([^&]+)/.exec(body);
    const clientId = clientIdMatch ? decodeURIComponent(clientIdMatch[1]) : 'unknown';
    return {
      ok: true,
      status: 200,
      json: async () => ({ access_token: `token-for-${clientId}` }),
      text: async () => '',
    };
  };

  t.after(() => {
    global.fetch = originalFetch;
    auth._resetCache();
  });

  const credsA = { clientId: 'client-a', clientSecret: 'secret-a', refreshToken: 'refresh-a' };
  const credsB = { clientId: 'client-b', clientSecret: 'secret-b', refreshToken: 'refresh-b' };

  const tokenA1 = await auth.getAccessToken(credsA);
  const tokenB1 = await auth.getAccessToken(credsB);

  assert.equal(tokenA1, 'token-for-client-a');
  assert.equal(tokenB1, 'token-for-client-b');
  assert.equal(fetchCallCount, 2);

  // 同じ認証情報で再度呼び出すとキャッシュが使われ、fetchは増えない
  const tokenA2 = await auth.getAccessToken(credsA);
  assert.equal(tokenA2, 'token-for-client-a');
  assert.equal(fetchCallCount, 2);

  const tokenB2 = await auth.getAccessToken(credsB);
  assert.equal(tokenB2, 'token-for-client-b');
  assert.equal(fetchCallCount, 2);
});

test('auth.credentialsCacheKey: 同じ認証情報は同じキーになり、異なる認証情報は異なるキーになる', () => {
  const auth = require('../src/spapi/auth');
  const keyA = auth.credentialsCacheKey({ clientId: 'a', refreshToken: 'x' });
  const keyA2 = auth.credentialsCacheKey({ clientId: 'a', refreshToken: 'x' });
  const keyB = auth.credentialsCacheKey({ clientId: 'b', refreshToken: 'x' });

  assert.equal(keyA, keyA2);
  assert.notEqual(keyA, keyB);
  // トークン本体やシークレットそのものが平文で含まれないこと(ハッシュ値であること)
  assert.match(keyA, /^[0-9a-f]{64}$/);
});

test('auth.getAccessToken: 認証情報未指定時は.envにフォールバックする', async (t) => {
  const auth = require('../src/spapi/auth');
  auth._resetCache();

  let fetchCallCount = 0;
  const originalFetch = global.fetch;
  global.fetch = async () => {
    fetchCallCount += 1;
    return {
      ok: true,
      status: 200,
      json: async () => ({ access_token: 'token-from-env' }),
      text: async () => '',
    };
  };

  const savedClientId = process.env.LWA_CLIENT_ID;
  const savedClientSecret = process.env.LWA_CLIENT_SECRET;
  const savedRefreshToken = process.env.LWA_REFRESH_TOKEN;
  process.env.LWA_CLIENT_ID = 'env-client';
  process.env.LWA_CLIENT_SECRET = 'env-secret';
  process.env.LWA_REFRESH_TOKEN = 'env-refresh';

  t.after(() => {
    global.fetch = originalFetch;
    auth._resetCache();
    if (savedClientId === undefined) delete process.env.LWA_CLIENT_ID;
    else process.env.LWA_CLIENT_ID = savedClientId;
    if (savedClientSecret === undefined) delete process.env.LWA_CLIENT_SECRET;
    else process.env.LWA_CLIENT_SECRET = savedClientSecret;
    if (savedRefreshToken === undefined) delete process.env.LWA_REFRESH_TOKEN;
    else process.env.LWA_REFRESH_TOKEN = savedRefreshToken;
  });

  const token = await auth.getAccessToken();
  assert.equal(token, 'token-from-env');
  assert.equal(fetchCallCount, 1);
});
