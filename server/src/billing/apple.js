'use strict';
const { evaluate, mergeState } = require('./state');
const { report } = require('./diagnostics');
const root = require('./apple-root.json');
const BUNDLE = 'jp.sellira.sellerlens';
const verifiers = new Map();
// Loaded from request context: jsrsasign initializes random data on import.
function verifier(environment) {
  if (!['Production', 'Sandbox'].includes(environment)) throw new Error('invalid_environment');
  if (verifiers.has(environment)) return verifiers.get(environment);
  const { SignedDataVerifier } = require('@apple/app-store-server-library');
  const result = new SignedDataVerifier([Buffer.from(root.der, 'base64')], true, environment, BUNDLE, 6801570852);
  verifiers.set(environment, result);
  return result;
}
async function decode(jws, method) {
  if (typeof jws !== 'string' || jws.length > 60000 || jws.split('.').length !== 3) throw new Error('invalid_purchase');
  // Untrusted environment only selects a verifier. It never grants access.
  let payload;
  try { payload = JSON.parse(Buffer.from(jws.split('.')[1], 'base64url')); } catch { throw new Error('invalid_purchase'); }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) throw new Error('invalid_purchase');
  const environment = payload.environment || payload.data?.environment || payload.summary?.environment;
  try { return await verifier(environment)[method](jws); }
  catch (e) {
    report('incoming_signature', e, environment);
    const { VerificationStatus } = require('@apple/app-store-server-library');
    if (e.status === VerificationStatus.RETRYABLE_VERIFICATION_FAILURE) throw new Error('apple_unavailable');
    throw new Error('invalid_purchase');
  }
}
async function latest(environment, originalTransactionId, env) {
  if (!env.APPLE_IAP_PRIVATE_KEY || !env.APPLE_IAP_KEY_ID || !env.APPLE_IAP_ISSUER_ID) throw new Error('billing_not_configured');
  const { AppStoreServerAPIClient } = require('@apple/app-store-server-library');
  class Client extends AppStoreServerAPIClient {
    async makeFetchRequest(path, query, method, body, headers) {
      return fetch(`${this.urlBase}${path}?${query}`, { method, body, headers, signal: AbortSignal.timeout(15000) });
    }
  }
  const client = new Client(env.APPLE_IAP_PRIVATE_KEY, env.APPLE_IAP_KEY_ID, env.APPLE_IAP_ISSUER_ID, BUNDLE, environment);
  let response;
  try { response = await client.getAllSubscriptionStatuses(originalTransactionId); }
  catch (e) {
    report('subscription_api', e, environment);
    if (e.httpStatusCode === 404) throw new Error('purchase_not_found');
    throw new Error('apple_unavailable');
  }
  if (response.environment !== environment || response.bundleId !== BUNDLE || (environment === 'Production' && response.appAppleId !== 6801570852)) throw new Error('invalid_purchase');
  const v = verifier(environment);
  let state = null;
  try {
    for (const group of response.data || []) {
      for (const item of group.lastTransactions || []) {
        if (item.originalTransactionId !== originalTransactionId) continue;
        const tx = await v.verifyAndDecodeTransaction(item.signedTransactionInfo);
        const renewal = item.signedRenewalInfo ? await v.verifyAndDecodeRenewalInfo(item.signedRenewalInfo) : {};
        if (tx.originalTransactionId !== originalTransactionId) throw new Error('invalid_purchase');
        state = mergeState(state, evaluate(tx, renewal, item.status));
      }
    }
  } catch (e) {
    report('subscription_signature', e, environment);
    const { VerificationStatus } = require('@apple/app-store-server-library');
    if (e.status === VerificationStatus.RETRYABLE_VERIFICATION_FAILURE) throw new Error('apple_unavailable');
    throw new Error('invalid_purchase');
  }
  if (!state) throw new Error('purchase_not_found');
  return state;
}
module.exports = { decode, latest };
