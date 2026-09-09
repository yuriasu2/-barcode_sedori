'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { report } = require('../src/billing/diagnostics');
test('billing diagnostics expose failure classification without purchase or credential contents', () => {
  const saved = console.warn;
  const lines = [];
  console.warn = (...args) => lines.push(args);
  try {
    report('incoming_signature', { status: 2, message: 'secret-jws', signedTransaction: 'secret-jws', cause: { message: 'secret-key', code: 'ERR_INVALID_ARG_TYPE', stack: 'secret-stack' } });
    const output = JSON.stringify(lines);
    assert.ok(!output.includes('secret-jws'));
    assert.ok(!output.includes('secret-key'));
    assert.ok(!output.includes('secret-stack'));
    assert.equal(JSON.parse(lines[0][1]).verificationStatus, 2);
    assert.equal(JSON.parse(lines[0][1]).causeCode, 'ERR_INVALID_ARG_TYPE');
  } finally { console.warn = saved; }
});
