'use strict';
// Deliberately excludes message, stack, JWS, identifiers, headers and credentials.
function report(stage, error, environment) {
  const cause = error?.cause || error;
  console.warn('[billing-diagnostic]', JSON.stringify({
    stage,
    environment: ['Production', 'Sandbox', 'Xcode', 'LocalTesting'].includes(environment) ? environment : null,
    failure: ['invalid_purchase', 'purchase_not_found', 'billing_not_configured', 'billing_unauthorized', 'billing_unavailable', 'apple_unavailable', 'billing_rate_limited'].includes(error?.message) ? error.message : null,
    verificationStatus: Number.isInteger(error?.status) ? error.status : null,
    httpStatus: Number.isInteger(error?.httpStatusCode) ? error.httpStatusCode : null,
    apiError: Number.isInteger(error?.apiError) ? error.apiError : null,
    causeCode: typeof cause?.code === 'string' && /^ERR_[A-Z_]{1,60}$/.test(cause.code) ? cause.code : null,
    keyObjectError: /PublicKeyObject|KeyObject/.test(cause?.message || ''),
  }));
}
module.exports = { report };
