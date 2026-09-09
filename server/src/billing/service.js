'use strict';
const { randomUUID, createHash } = require('node:crypto');
const tokens = require('./tokens');
const apple = require('./apple');
const { evaluate } = require('./state');
const { report } = require('./diagnostics');
const DAY = 86400000;
const verifiedRequests = new WeakMap();
async function call(name, body) {
  const ns = globalThis.__billingDO;
  if (!ns) throw new Error('billing_not_configured');
  const response = await ns.get(ns.idFromName(name)).fetch('https://billing/internal', { method: 'POST', body: JSON.stringify(body) });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || 'billing_unavailable');
  return result;
}
async function limit(key, limit, daily = false) {
  const hash = createHash('sha256').update(key).digest('hex');
  if (!(await call(`limit:${hash}`, { op: 'limit', limit, daily })).allowed) throw new Error('billing_rate_limited');
}
function session(headers) {
  try { return tokens.verify(headers['x-billing-session'], 'session'); }
  catch { throw new Error('billing_unauthorized'); }
}
function claims(headers) {
  if (!headers.authorization?.startsWith('Bearer ')) throw new Error('billing_unauthorized');
  const access = tokens.verify(headers.authorization.slice(7), 'access');
  const s = session(headers);
  if (access.sid !== s.sid || !['Production', 'Sandbox'].includes(access.environment)) throw new Error('billing_unauthorized');
  return access;
}
function isPro(headers) { return verifiedRequests.get(headers)?.pro === true; }
async function authorize(req, res) {
  verifiedRequests.delete(req.headers);
  const path = new URL(req.url, 'https://local').pathname;
  if (path.startsWith('/api/billing/') || path === '/api/apple/notifications') return true;
  if (!req.headers.authorization) return true;
  try {
    const c = claims(req.headers);
    if (c.environment === 'Sandbox' && /\/api\/(search|graph|graph-data)(\?|$)/.test(req.url)) {
      // TestFlight/review: separate aggregate budget, cannot drain an unlimited shared Keepa pool.
      await limit('sandbox-shared-resources', 100, true);
    }
    verifiedRequests.set(req.headers, { pro: true, environment: c.environment });
    return true;
  } catch (e) { sendError(res, e, 401); return false; }
}
function sendError(res, error, fallback = 503) {
  report('billing_response', error);
  const code = error.message;
  const status = code === 'billing_rate_limited' ? 429 : ['invalid_purchase', 'purchase_not_found', 'invalid_environment'].includes(code) ? 400 : code === 'billing_unauthorized' ? 401 : fallback;
  return res.status(status).json({ error: status === 503 ? 'billing_unavailable' : code, message: status === 429 ? '購入状態の確認が集中しています。少し待って再度お試しください。' : '購入状態を確認できませんでした。再購入せず、しばらくしてから再度お試しください。' });
}
function register(router) {
  const route = (path, handler) => router.post(path, async (req, res) => {
    try {
      await limit(`ip:${req.headers['cf-connecting-ip'] || 'local'}`, 20);
      return res.json(await handler(req));
    } catch (e) { return sendError(res, e); }
  });
  route('/api/billing/session', async () => {
    if (!process.env.APPLE_IAP_PRIVATE_KEY || !process.env.APPLE_IAP_KEY_ID || !process.env.APPLE_IAP_ISSUER_ID) throw new Error('billing_not_configured');
    const sid = randomUUID();
    return { session: tokens.issue('session', { sid }, Date.now() + 365 * DAY), appAccountToken: sid };
  });
  async function entitlement(s, environment, originalTransactionId, force) {
    const result = await call(`subscription:${environment}:${originalTransactionId}`, { environment, originalTransactionId, force });
    const now = Date.now();
    const expiresAt = Math.floor(Math.min(now + 15 * 60000, result.state.validUntil) / 1000) * 1000;
    const pro = expiresAt > now;
    const common = { sid: s.sid, environment, originalTransactionId };
    return { pro, pending: false, provisional: result.provisional, expiresAt: pro ? expiresAt : 0,
      accessToken: pro ? tokens.issue('access', common, expiresAt) : null,
      refreshToken: tokens.issue('refresh', common, now + 90 * DAY) };
  }
  route('/api/billing/verify', async req => {
    const s = session(req.headers);
    await limit(`session:${s.sid}`, 10);
    const tx = await apple.decode(req.body?.signedTransaction, 'verifyAndDecodeTransaction');
    evaluate(tx, {}, 1); // Checks product/type; expiry does not invalidate a legitimate restore proof.
    return entitlement(s, tx.environment, tx.originalTransactionId, true);
  });
  route('/api/billing/refresh', async req => {
    const s = session(req.headers);
    await limit(`session:${s.sid}`, 10);
    const r = tokens.verify(req.body?.refreshToken, 'refresh');
    if (r.sid !== s.sid) throw new Error('billing_unauthorized');
    return entitlement(s, r.environment, r.originalTransactionId, false);
  });
  route('/api/apple/notifications', async req => {
    const n = await apple.decode(req.body?.signedPayload, 'verifyAndDecodeNotification');
    if (n.notificationType === 'TEST') return { stored: true };
    if (!n.data?.signedTransactionInfo || !n.notificationUUID) throw new Error('invalid_purchase');
    const tx = await apple.decode(n.data.signedTransactionInfo, 'verifyAndDecodeTransaction');
    if (tx.environment !== n.data.environment) throw new Error('invalid_purchase');
    // Apple is re-queried for every non-duplicate notification. No event-name-only grant.
    evaluate(tx, {}, 1);
    const state = tx.revocationDate ? evaluate(tx, {}, 5) : null;
    await call(`subscription:${tx.environment}:${tx.originalTransactionId}`, { environment: tx.environment, originalTransactionId: tx.originalTransactionId, force: true, notification: { id: n.notificationUUID, state } });
    return { stored: true };
  });
}
module.exports = { register, authorize, isPro, claims };
