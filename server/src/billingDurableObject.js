import billing from './billing/durable.js';
export class BillingDO {
  constructor(state, env) { this.storage = state.storage; this.store = new billing.BillingStore(state.storage, env); }
  async fetch(request) {
    try { return Response.json(await this.store.run(await request.json())); }
    catch (e) {
      const error = ['apple_unavailable', 'purchase_not_found', 'billing_not_configured', 'invalid_purchase'].includes(e.message) ? e.message : 'billing_unavailable';
      return Response.json({ error }, { status: 503 });
    }
  }
  async alarm() { await this.storage.deleteAll(); }
}
