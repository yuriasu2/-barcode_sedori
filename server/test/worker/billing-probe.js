import fixture from './apple-fixture.json';
// Local-only probe. Never deploy this entry point: it trusts Apple's TEST certificate.
export default {
  async fetch() {
    const { SignedDataVerifier, AppStoreServerAPIClient, VerificationStatus } = await import('@apple/app-store-server-library');
    const { generateKeyPairSync, verify: verifySignature, X509Certificate } = await import('node:crypto');
    const results = {};
    const verifier = new SignedDataVerifier([Buffer.from(fixture.root, 'base64')], false, 'Sandbox', 'com.example');
    results.validChain = (await verifier.verifyAndDecodeTransaction(fixture.transaction)).bundleId === 'com.example';
    async function rejects(name, fn) {
      try { await fn(); results[name] = false; } catch { results[name] = true; }
    }
    await rejects('tampered', () => verifier.verifyAndDecodeTransaction(fixture.transaction.slice(0, -8) + 'AAAAAAAA'));
    await rejects('untrustedRoot', () => new SignedDataVerifier([], false, 'Sandbox', 'com.example').verifyAndDecodeTransaction(fixture.transaction));
    await rejects('wrongApp', () => new SignedDataVerifier([Buffer.from(fixture.root, 'base64')], false, 'Sandbox', 'other').verifyAndDecodeTransaction(fixture.transaction));
    await rejects('wrongEnvironment', () => new SignedDataVerifier([Buffer.from(fixture.root, 'base64')], false, 'Production', 'com.example', 1234).verifyAndDecodeTransaction(fixture.transaction));
    const pair = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    const client = new AppStoreServerAPIClient(pair.privateKey.export({ type: 'pkcs8', format: 'pem' }), 'TEST', 'test-issuer', 'com.example', 'Sandbox');
    const token = client.createBearerToken();
    const [header, payload, signature] = token.split('.');
    results.apiJwt = verifySignature('sha256', Buffer.from(header + '.' + payload), { key: pair.publicKey.export({ type: 'spki', format: 'pem' }), dsaEncoding: 'ieee-p1363' }, Buffer.from(signature, 'base64url'));
    // The alias must work in workerd, including the official verifier's OCSP path.
    const { default: send, Headers } = require('node-fetch');
    const originalFetch = globalThis.fetch;
    try {
      const bytes = Buffer.from([0, 128, 255, 48, 2]);
      globalThis.fetch = async (_url, options) => {
        results.ocspRequestBytes = Buffer.from(options.body).equals(bytes)
          && options.headers.get('content-type') === 'application/ocsp-request';
        return new Response(bytes);
      };
      const response = await send('http://ocsp.test/', { method: 'POST', headers: new Headers({ 'Content-Type': 'application/ocsp-request' }), body: bytes, timeout: 30000 });
      results.ocspResponseBytes = (await response.buffer()).equals(bytes);
      const chain = JSON.parse(Buffer.from(fixture.transaction.split('.')[0], 'base64url')).x5c;
      const leaf = new X509Certificate(Buffer.from(chain[0], 'base64'));
      const issuer = new X509Certificate(Buffer.from(chain[1], 'base64'));
      const cert = { infoAccess: 'OCSP - URI:http://ocsp.test/', toString: () => leaf.toString() };
      let requests = 0;
      globalThis.fetch = async () => { requests++; return new Response('', { status: 503 }); };
      try { await verifier.checkOCSPStatus(cert, issuer); results.ocspFailureRejected = false; }
      catch (e) { results.ocspFailureRejected = requests === 1 && e.status === VerificationStatus.RETRYABLE_VERIFICATION_FAILURE; }
      globalThis.fetch = async () => { requests++; return new Response(bytes); };
      await rejects('invalidOcspRejected', () => verifier.checkOCSPStatus(cert, issuer));
      results.ocspRequestsUsedNativeFetch = requests === 2;
    } finally { globalThis.fetch = originalFetch; }
    return Response.json(results, { status: Object.values(results).every(Boolean) ? 200 : 500 });
  }
};
