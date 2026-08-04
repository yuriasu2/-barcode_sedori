'use strict';

const test = require('node:test');
const assert = require('node:assert');

const keepaCoalesce = require('../src/keepaCoalesce');

test.beforeEach(() => keepaCoalesce._resetForTest());

test('coalesce: 同じkeyへの同時呼び出しはfnを1回しか実行しない', async () => {
  let callCount = 0;
  const fn = async () => {
    callCount += 1;
    await new Promise((r) => setTimeout(r, 20));
    return 'result';
  };

  const [a, b, c] = await Promise.all([
    keepaCoalesce.coalesce('key-1', fn),
    keepaCoalesce.coalesce('key-1', fn),
    keepaCoalesce.coalesce('key-1', fn),
  ]);

  assert.equal(callCount, 1, 'fnは1回だけ呼ばれるべき');
  assert.equal(a, 'result');
  assert.equal(b, 'result');
  assert.equal(c, 'result');
});

test('coalesce: 異なるkeyは束ねられず、それぞれfnが呼ばれる', async () => {
  let callCount = 0;
  const fn = async () => {
    callCount += 1;
    return callCount;
  };

  const [a, b] = await Promise.all([
    keepaCoalesce.coalesce('key-a', fn),
    keepaCoalesce.coalesce('key-b', fn),
  ]);

  assert.equal(callCount, 2);
  assert.notEqual(a, b);
});

test('coalesce: fnが失敗したら、束ねられた全員に同じエラーが伝播する', async () => {
  const fn = async () => {
    await new Promise((r) => setTimeout(r, 10));
    throw new Error('boom');
  };

  const results = await Promise.allSettled([
    keepaCoalesce.coalesce('key-err', fn),
    keepaCoalesce.coalesce('key-err', fn),
  ]);

  assert.equal(results[0].status, 'rejected');
  assert.equal(results[1].status, 'rejected');
  assert.equal(results[0].reason.message, 'boom');
  assert.equal(results[1].reason.message, 'boom');
});

test('coalesce: 完了後は同じkeyでも新規にfnが呼ばれる(in-flight解除)', async () => {
  let callCount = 0;
  const fn = async () => {
    callCount += 1;
    return callCount;
  };

  const first = await keepaCoalesce.coalesce('key-seq', fn);
  const second = await keepaCoalesce.coalesce('key-seq', fn);

  assert.equal(first, 1);
  assert.equal(second, 2);
  assert.equal(callCount, 2);
});

test('coalesce: 実行中は_inFlightCountForTestが増え、完了後は0に戻る', async () => {
  let resolveFn;
  const fn = () => new Promise((r) => { resolveFn = r; });

  const promise = keepaCoalesce.coalesce('key-inflight', fn);
  assert.equal(keepaCoalesce._inFlightCountForTest(), 1);

  resolveFn('done');
  await promise;
  assert.equal(keepaCoalesce._inFlightCountForTest(), 0);
});
