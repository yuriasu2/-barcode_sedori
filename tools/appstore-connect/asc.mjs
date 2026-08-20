// App Store Connect API クライアント(依存パッケージ無し・Nodeのcryptoのみ)。
// 鍵のパスだけを受け取り、鍵の内容は決して出力しない。
//
// 認証情報の解決順:
//   1. 環境変数 ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID
//   2. ~/.config/appstore-connect/config.json
// 2があるおかげで、どのセッション・どのプロジェクトからでも環境変数の設定なしに使える。
// 秘密鍵(.p8)自体はconfigに書かず、パス参照に留める(config.jsonを覗かれても鍵は漏れない)。
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const CONFIG_PATH = path.join(os.homedir(), '.config', 'appstore-connect', 'config.json');

function loadConfig() {
  try {
    return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
  } catch {
    return {};
  }
}

const cfg = loadConfig();

/** 先頭の ~ をホームディレクトリへ展開する(configに ~ 付きで書けるようにするため)。 */
function expandHome(p) {
  if (!p) return p;
  return p.startsWith('~') ? path.join(os.homedir(), p.slice(1)) : p;
}

const KEY_PATH  = expandHome(process.env.ASC_KEY_PATH  || cfg.keyPath);
const KEY_ID    = process.env.ASC_KEY_ID    || cfg.keyId;
const ISSUER_ID = process.env.ASC_ISSUER_ID || cfg.issuerId;

/** status.mjs等が既定のアプリIDを引くための公開値。 */
export const defaultAppId = process.env.ASC_APP_ID || cfg.defaultAppId || null;

function requireCredentials() {
  const missing = [
    !KEY_PATH  && 'keyPath',
    !KEY_ID    && 'keyId',
    !ISSUER_ID && 'issuerId',
  ].filter(Boolean);
  if (missing.length) {
    throw new Error(
      `App Store Connectの認証情報が足りません: ${missing.join(', ')}\n` +
      `${CONFIG_PATH} を作るか、ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID を設定してください。\n` +
      `詳細は tools/appstore-connect/README.md を参照。`
    );
  }
  if (!fs.existsSync(KEY_PATH)) {
    throw new Error(`秘密鍵が見つかりません: ${KEY_PATH}`);
  }
}

function b64url(buf) {
  return Buffer.from(buf).toString('base64')
    .replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
}

function token() {
  requireCredentials();
  const now = Math.floor(Date.now()/1000);
  const header  = { alg:'ES256', kid:KEY_ID, typ:'JWT' };
  const payload = { iss:ISSUER_ID, iat:now, exp:now+1200, aud:'appstoreconnect-v1' };
  const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
  // JOSEはr||sの生署名を要求する。Node既定のDERでは通らないためieee-p1363を指定する。
  const sig = crypto.sign('sha256', Buffer.from(signingInput), {
    key: fs.readFileSync(KEY_PATH, 'utf8'),
    dsaEncoding: 'ieee-p1363',
  });
  return `${signingInput}.${b64url(sig)}`;
}

export async function asc(method, path, body) {
  const url = path.startsWith('http') ? path : `https://api.appstoreconnect.apple.com${path}`;
  const res = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${token()}`,
      ...(body ? {'Content-Type':'application/json'} : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* 空応答や非JSONはそのまま */ }
  if (!res.ok) {
    const detail = json?.errors?.map(e => `${e.status} ${e.code}: ${e.title} / ${e.detail}`).join('\n') || text;
    const err = new Error(`${method} ${path}\n${detail}`);
    err.status = res.status;
    err.body = json;
    throw err;
  }
  return json;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [,, method='GET', path='/v1/apps?limit=5'] = process.argv;
  asc(method, path).then(r => console.log(JSON.stringify(r, null, 2)))
    .catch(e => { console.error('ERROR:', e.message); process.exit(1); });
}
