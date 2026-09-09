'use strict';
const { issue } = require('../src/billing/tokens');
// Test-only signing material. Never loaded by server/src or deployed in the Worker.
function proHeaders() {
  process.env.BILLING_TOKEN_KEY_ID = 'test';
  process.env.BILLING_TOKEN_KEYS = JSON.stringify({ test: 'test-only-'.repeat(8) });
  const now = Date.now();
  return { authorization: `Bearer ${issue('access', { sid: 'test-session', environment: 'Production', originalTransactionId: 'test-purchase' }, now + 600000)}`,
    'x-billing-session': issue('session', { sid: 'test-session' }, now + 600000) };
}
module.exports = { proHeaders };
