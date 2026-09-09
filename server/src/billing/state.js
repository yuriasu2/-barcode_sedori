'use strict';
const PRODUCT = 'jp.sellira.sellerlens.pro.monthly';
function evaluate(tx, renewal = {}, status, now = Date.now()) {
  if (tx.productId !== PRODUCT || tx.type !== 'Auto-Renewable Subscription' || !['Production', 'Sandbox'].includes(tx.environment) || !tx.originalTransactionId || !tx.transactionId || !Number.isFinite(tx.signedDate) || tx.signedDate > now + 60000 || !Number.isFinite(tx.expiresDate)) throw new Error('invalid_purchase');
  if (renewal.originalTransactionId && renewal.originalTransactionId !== tx.originalTransactionId) throw new Error('invalid_purchase');
  if (renewal.signedDate !== undefined && (!Number.isFinite(renewal.signedDate) || renewal.signedDate > now + 60000)) throw new Error('invalid_purchase');
  let validUntil = 0;
  if (!tx.revocationDate && [1, 3, 4].includes(status)) {
    validUntil = tx.expiresDate;
    if (status === 4 && Number.isFinite(renewal.gracePeriodExpiresDate)) validUntil = Math.max(validUntil, renewal.gracePeriodExpiresDate);
  }
  return { environment: tx.environment, originalTransactionId: tx.originalTransactionId, transactionId: tx.transactionId, productId: tx.productId, status, expiresDate: tx.expiresDate, gracePeriodExpiresDate: renewal.gracePeriodExpiresDate || null, revocationDate: tx.revocationDate || null, appAccountToken: tx.appAccountToken || null, signedDate: Math.max(tx.signedDate, renewal.signedDate || 0), validUntil: validUntil > now ? validUntil : 0, observedAt: now };
}
function mergeState(old, next) {
  if (!old) return next;
  if (next.signedDate < old.signedDate) return old;
  // Equal-version disagreement: a restrictive result wins, including refund races.
  if (next.signedDate === old.signedDate && old.validUntil < next.validUntil) return old;
  return next;
}
module.exports = { PRODUCT, evaluate, mergeState };
