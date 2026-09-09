'use strict';
// Wrangler-only alias for the pinned Apple library's node-fetch dependency.
// Keep Apple's verifier intact; adapt only fetch, timeout, and Response.buffer().
async function workersFetch(url, options = {}) {
  const { timeout = 30000, signal, ...init } = options;
  const deadline = AbortSignal.timeout(timeout > 0 ? timeout : 30000);
  const response = await globalThis.fetch(url, {
    ...init,
    signal: signal ? AbortSignal.any([signal, deadline]) : deadline,
  });
  response.buffer = async () => Buffer.from(await response.arrayBuffer());
  return response;
}
module.exports = { default: workersFetch, Headers: globalThis.Headers };
