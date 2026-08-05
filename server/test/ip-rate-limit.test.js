'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const ipRateLimit = require('../src/ipRateLimit');

test('RateLimitCore: 上限までは許可し、超えたら拒否する', () => {
  const core = new ipRateLimit.RateLimitCore(3);
  const now = 1_000_000;

  assert.equal(core.check(now).allowed, true);
  assert.equal(core.check(now).allowed, true);
  assert.equal(core.check(now).allowed, true);
  assert.equal(core.check(now).allowed, false);
});

test('RateLimitCore: 残り回数(remaining)を返す', () => {
  const core = new ipRateLimit.RateLimitCore(3);
  const now = 1_000_000;

  assert.equal(core.check(now).remaining, 2);
  assert.equal(core.check(now).remaining, 1);
  assert.equal(core.check(now).remaining, 0);
});

test('RateLimitCore: ウィンドウ(60秒)が明けたらカウンタがリセットされる', () => {
  const core = new ipRateLimit.RateLimitCore(2);
  const now = 1_000_000;

  assert.equal(core.check(now).allowed, true);
  assert.equal(core.check(now).allowed, true);
  assert.equal(core.check(now).allowed, false);

  // 59秒後はまだ同じウィンドウ
  assert.equal(core.check(now + 59_000).allowed, false);
  // 60秒後は新しいウィンドウ
  assert.equal(core.check(now + 60_000).allowed, true);
});

test('RateLimitCore: 拒否時のretryAfterSecはウィンドウの残り秒数(1以上)', () => {
  const core = new ipRateLimit.RateLimitCore(1);
  const now = 1_000_000;

  core.check(now);
  const denied = core.check(now + 20_000);
  assert.equal(denied.allowed, false);
  assert.equal(denied.retryAfterSec, 40);
});

test('checkAndCount: ipがnull(Workers以外の環境)なら素通しする', async () => {
  ipRateLimit._reset();
  const result = await ipRateLimit.checkAndCount(null);
  assert.equal(result.allowed, true);
});

test('checkAndCount: インメモリ経路でIPごとに独立して数える', async () => {
  ipRateLimit._reset();
  ipRateLimit._setDurableBinding(null); // インメモリ経路を強制

  // 既定30回/分。同一IPで31回目が拒否される。
  for (let i = 0; i < 30; i += 1) {
    const ok = await ipRateLimit.checkAndCount('1.2.3.4');
    assert.equal(ok.allowed, true, `${i + 1}回目は許可されるはず`);
  }
  const denied = await ipRateLimit.checkAndCount('1.2.3.4');
  assert.equal(denied.allowed, false);

  // 別IPは影響を受けない
  const other = await ipRateLimit.checkAndCount('5.6.7.8');
  assert.equal(other.allowed, true);

  ipRateLimit._setDurableBinding(undefined);
});

test('checkAndCount: DO障害時は許可で倒す(可用性優先)', async () => {
  ipRateLimit._reset();
  ipRateLimit._setDurableBinding({
    idFromName() { return 'id'; },
    get() {
      return { fetch() { throw new Error('DO down'); } };
    },
  });

  const result = await ipRateLimit.checkAndCount('1.2.3.4');
  assert.equal(result.allowed, true);

  ipRateLimit._setDurableBinding(undefined);
});

test('readLimitPerMin: envの値を読み、無効なら既定30', () => {
  assert.equal(ipRateLimit.readLimitPerMin({ IP_RATE_LIMIT_PER_MIN: '10' }), 10);
  assert.equal(ipRateLimit.readLimitPerMin({}), 30);
  assert.equal(ipRateLimit.readLimitPerMin({ IP_RATE_LIMIT_PER_MIN: 'abc' }), 30);
  assert.equal(ipRateLimit.readLimitPerMin({ IP_RATE_LIMIT_PER_MIN: '0' }), 30);
});
