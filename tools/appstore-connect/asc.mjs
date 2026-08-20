// App Store Connect API クライアント(依存パッケージ無し・Nodeのcryptoのみ)。
// 鍵はASC_KEY_PATHで受け取り、内容は決して出力しない。
import crypto from 'node:crypto';
import fs from 'node:fs';

const KEY_PATH  = process.env.ASC_KEY_PATH;
const KEY_ID    = process.env.ASC_KEY_ID;
const ISSUER_ID = process.env.ASC_ISSUER_ID;

function b64url(buf) {
  return Buffer.from(buf).toString('base64')
    .replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
}

function token() {
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
