'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { LruCache } = require('../src/cache');

test('LruCache: 既定TTL内はヒットする', () => {
  const c = new LruCache();
  c.set('k', 1);
  assert.equal(c.get('k'), 1);
});

test('LruCache: set の第3引数でエントリ単位のTTLを上書きできる', () => {
  const c = new LruCache({ ttlMs: 5 * 60 * 1000 });
  // 過去TTL(負値)=即時失効
  c.set('expired', 'x', -1000);
  assert.equal(c.get('expired'), undefined);
  // 長いTTL=有効
  c.set('valid', 'y', 60 * 60 * 1000);
  assert.equal(c.get('valid'), 'y');
});

test('LruCache: ttlMs未指定なら従来どおりインスタンス既定を使う', () => {
  // 既定TTLを負にしたインスタンスは、ttl省略のsetで即時失効する
  const c = new LruCache({ ttlMs: -1 });
  c.set('k', 1);
  assert.equal(c.get('k'), undefined);
  // 同じインスタンスでも第3引数で有効TTLを与えればヒットする
  c.set('k2', 2, 60 * 1000);
  assert.equal(c.get('k2'), 2);
});
