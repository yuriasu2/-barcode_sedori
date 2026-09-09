'use strict';
const { createHmac, timingSafeEqual } = require('node:crypto');
const ISSUER = 'sellerlens-billing';
function keys(env) {
  const values = JSON.parse(env.BILLING_TOKEN_KEYS || '{}');
  if (!env.BILLING_TOKEN_KEY_ID || typeof values[env.BILLING_TOKEN_KEY_ID] !== 'string' || values[env.BILLING_TOKEN_KEY_ID].length < 64) throw new Error('billing_not_configured');
  return values;
}
function signature(data, key) { return createHmac('sha256', key).update(data).digest(); }
function issue(purpose, claims, expiresAt, env = process.env, now = Date.now()) {
  const key = keys(env)[env.BILLING_TOKEN_KEY_ID];
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const data = `${encode({ alg: 'HS256', typ: 'JWT', kid: env.BILLING_TOKEN_KEY_ID })}.${encode({ ...claims, iss: ISSUER, aud: purpose, iat: Math.floor(now / 1000), exp: Math.floor(expiresAt / 1000) })}`;
  return `${data}.${signature(data, key).toString('base64url')}`;
}
function verify(token, purpose, env = process.env, now = Date.now()) {
  if (typeof token !== 'string' || token.length > 8192) throw new Error('billing_unauthorized');
  const parts = token.split('.');
  if (parts.length !== 3) throw new Error('billing_unauthorized');
  const header = JSON.parse(Buffer.from(parts[0], 'base64url'));
  const key = keys(env)[header.kid];
  if (header.alg !== 'HS256' || header.typ !== 'JWT' || typeof key !== 'string' || key.length < 64) throw new Error('billing_unauthorized');
  const actual = Buffer.from(parts[2], 'base64url');
  const expected = signature(`${parts[0]}.${parts[1]}`, key);
  if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) throw new Error('billing_unauthorized');
  const data = JSON.parse(Buffer.from(parts[1], 'base64url'));
  if (data.iss !== ISSUER || data.aud !== purpose || !Number.isFinite(data.exp) || data.exp * 1000 <= now || !Number.isFinite(data.iat) || data.iat * 1000 > now + 60000) throw new Error('billing_unauthorized');
  return data;
}
module.exports = { issue, verify };
