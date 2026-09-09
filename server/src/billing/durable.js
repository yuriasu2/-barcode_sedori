'use strict';
const apple = require('./apple');
const { mergeState } = require('./state');
const MINUTE = 60000, DAY = 86400000;
class BillingStore {
  constructor(storage, env, fetchLatest = apple.latest, now = Date.now) {
    this.storage = storage; this.env = env; this.fetchLatest = fetchLatest; this.now = now;
    this.queue = Promise.resolve();
  }
  run(input) {
    const task = this.queue.then(() => this.execute(input));
    this.queue = task.catch(() => {});
    return task;
  }
  async execute(input) {
    const now = this.now();
    if (input.op === 'limit') {
      const period = input.daily ? DAY : MINUTE;
      let count = await this.storage.get('counter');
      if (!count || count.window !== Math.floor(now / period)) count = { window: Math.floor(now / period), used: 0 };
      if (count.used >= input.limit) return { allowed: false };
      count.used++;
      await this.storage.put('counter', count);
      await this.storage.setAlarm(now + period * 2);
      return { allowed: true };
    }
    let record = await this.storage.get('subscription') || { state: null, checkedAt: 0, seen: {}, dirty: false };
    const notification = input.notification;
    if (notification && record.seen[notification.id]) return { stored: true };
    if (notification) {
      record.dirty = true;
      if (notification.state) record.state = mergeState(record.state, notification.state);
      // Restrictive changes survive Apple downtime; no stale-access fallback while dirty.
      await this.storage.put('subscription', record);
      await this.storage.setAlarm(Math.max(now + 1, (record.state ? Math.max(record.state.expiresDate, record.state.validUntil) : now) + 90 * DAY));
    }
    const stale = now - record.checkedAt >= (input.force ? 5000 : 15 * MINUTE);
    if (!record.state || stale || record.dirty) {
      try {
        const latest = await this.fetchLatest(input.environment, input.originalTransactionId, this.env);
        record.state = mergeState(record.state, latest);
        record.checkedAt = this.now();
        record.dirty = false;
      } catch (e) {
        if (e.message !== 'apple_unavailable' || record.dirty || !record.state || record.checkedAt === 0 || now - record.checkedAt >= DAY || record.state.validUntil <= now || record.state.revocationDate) throw e;
        return { state: { ...record.state, validUntil: Math.min(record.state.validUntil, record.checkedAt + DAY) }, provisional: true };
      }
    }
    record.seen = Object.fromEntries(Object.entries(record.seen).filter(([, time]) => now - time < 30 * DAY));
    if (notification) record.seen[notification.id] = now;
    await this.storage.put('subscription', record);
    await this.storage.setAlarm(Math.max(now + 1, Math.max(record.state.expiresDate, record.state.validUntil) + 90 * DAY));
    return { state: record.state, provisional: false, stored: true };
  }
}
module.exports = { BillingStore };
