'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const quotaMath = require('../src/quotaMath');

const LIMITS = { base: 5, perAd: 5, max: 100 };

test('computeLimit: base + perAd*adGrants をmaxで頭打ちする', () => {
  assert.equal(quotaMath.computeLimit(0, LIMITS), 5);
  assert.equal(quotaMath.computeLimit(1, LIMITS), 10);
  assert.equal(quotaMath.computeLimit(19, LIMITS), 100); // 5 + 5*19 = 100 = cap
  assert.equal(quotaMath.computeLimit(20, LIMITS), 100); // capを超えない
  assert.equal(quotaMath.computeLimit(1000, LIMITS), 100);
});

test('buildQuota: unitsUsed=0, adGrants=0は基本枠フルの状態', () => {
  const quota = quotaMath.buildQuota(0, 0, LIMITS);
  assert.deepEqual(quota, {
    unitsRemaining: 5,
    baseRemaining: 5,
    unitsUsed: 0,
    adGrantsToday: 0,
    adAvailable: true,
    capReached: false,
    limit: 5,
  });
});

test('buildQuota: unitsUsedがlimitを超えていてもunitsRemaining/baseRemainingは0未満にならない', () => {
  const quota = quotaMath.buildQuota(999, 0, LIMITS);
  assert.equal(quota.unitsRemaining, 0);
  assert.equal(quota.baseRemaining, 0);
});

test('buildQuota: cap(100)到達時はcapReached=true, adAvailable=false', () => {
  // 5 + 5*19 = 100 でcap到達
  const quota = quotaMath.buildQuota(50, 19, LIMITS);
  assert.equal(quota.limit, 100);
  assert.equal(quota.capReached, true);
  assert.equal(quota.adAvailable, false);

  // 18本ではまだcap未到達(5+5*18=95)
  const quotaBeforeCap = quotaMath.buildQuota(50, 18, LIMITS);
  assert.equal(quotaBeforeCap.limit, 95);
  assert.equal(quotaBeforeCap.capReached, false);
  assert.equal(quotaBeforeCap.adAvailable, true);
});

test('canConsume: limit以内はtrue、超えるとfalse(境界値ちょうどはtrue)', () => {
  assert.equal(quotaMath.canConsume(0, 0, 5, LIMITS), true); // ちょうどlimit
  assert.equal(quotaMath.canConsume(0, 0, 6, LIMITS), false); // limit超え
  assert.equal(quotaMath.canConsume(4, 0, 1, LIMITS), true); // ちょうどlimit
  assert.equal(quotaMath.canConsume(5, 0, 1, LIMITS), false); // 既にlimit到達
});

test('canGrantAd: 19本目まではtrue(limitが上がる)、19本目でcap到達後の20本目はfalse', () => {
  assert.equal(quotaMath.canGrantAd(0, LIMITS), true);
  assert.equal(quotaMath.canGrantAd(18, LIMITS), true); // 5+5*18=95 -> 19本目でlimit100に上がる
  assert.equal(quotaMath.canGrantAd(19, LIMITS), false); // 既にlimit100(cap)なのでこれ以上上げられない
  assert.equal(quotaMath.canGrantAd(100, LIMITS), false);
});

test('境界値: base=0のlimitsでもcomputeLimit/buildQuotaが破綻しない', () => {
  const zeroBaseLimits = { base: 0, perAd: 10, max: 20 };
  assert.equal(quotaMath.computeLimit(0, zeroBaseLimits), 0);
  const quota = quotaMath.buildQuota(0, 0, zeroBaseLimits);
  assert.equal(quota.limit, 0);
  assert.equal(quota.unitsRemaining, 0);
  assert.equal(quota.capReached, false); // 0 >= 20 はfalse
});
