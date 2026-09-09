import fixture from './apple-fixture.json';
// Local-only probe. Never deploy this entry point: it trusts Apple's TEST certificate.
export default {
  async fetch() {
    const { SignedDataVerifier, AppStoreServerAPIClient } = await import('@apple/app-store-server-library');
    const { generateKeyPairSync, verify: verifySignature } = await import('node:crypto');
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
    return Response.json(results, { status: Object.values(results).every(Boolean) ? 200 : 500 });
  }
};
