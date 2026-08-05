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

  // 既定回数まで許可し、その次(既定+1回目)が拒否される。
  for (let i = 0; i < ipRateLimit.DEFAULT_LIMIT_PER_MIN; i += 1) {
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

test('readLimitPerMin: envの値を読み、無効なら既定10', () => {
  assert.equal(ipRateLimit.readLimitPerMin({ IP_RATE_LIMIT_PER_MIN: '15' }), 15);
  assert.equal(ipRateLimit.readLimitPerMin({}), 10);
  assert.equal(ipRateLimit.readLimitPerMin({ IP_RATE_LIMIT_PER_MIN: 'abc' }), 10);
  assert.equal(ipRateLimit.readLimitPerMin({ IP_RATE_LIMIT_PER_MIN: '0' }), 10);
});

// --- rateLimitKeyFor: IPv6は/64、IPv4はそのまま ---

test('rateLimitKeyFor: IPv4はそのまま返す', () => {
  assert.equal(ipRateLimit.rateLimitKeyFor('203.0.113.9'), '203.0.113.9');
});

test('rateLimitKeyFor: IPv6フル表記は先頭4ブロック(/64)に丸める', () => {
  assert.equal(
    ipRateLimit.rateLimitKeyFor('2001:0db8:85a3:0000:0000:8a2e:0370:7334'),
    '2001:0db8:85a3:0000'
  );
});

test('rateLimitKeyFor: "::"を含む圧縮表記(中間省略)も同じ/64に丸める', () => {
  assert.equal(
    ipRateLimit.rateLimitKeyFor('2001:db8:85a3::8a2e:370:7334'),
    '2001:0db8:85a3:0000'
  );
});

test('rateLimitKeyFor: "::"の前が4ブロック未満の圧縮表記も丸める', () => {
  assert.equal(ipRateLimit.rateLimitKeyFor('2001:db8::1'), '2001:0db8:0000:0000');
});

test('rateLimitKeyFor: ループバック(::1)は専用のキーになる', () => {
  assert.equal(ipRateLimit.rateLimitKeyFor('::1'), '0000:0000:0000:0000');
});

test('rateLimitKeyFor: IPv4射影アドレス(::ffff:x.x.x.x)は埋め込みIPv4で区別する', () => {
  assert.equal(ipRateLimit.rateLimitKeyFor('::ffff:192.0.2.1'), 'v4mapped:192.0.2.1');
  // 先頭4ブロックが全て0で揃う別の射影アドレスと衝突しないこと。
  assert.notEqual(
    ipRateLimit.rateLimitKeyFor('::ffff:192.0.2.1'),
    ipRateLimit.rateLimitKeyFor('::ffff:198.51.100.1')
  );
});

test('rateLimitKeyFor: ゾーンID(%eth0)や前後の空白を許容する', () => {
  assert.equal(
    ipRateLimit.rateLimitKeyFor('  2001:db8:85a3::8a2e:370:7334%eth0  '),
    '2001:0db8:85a3:0000'
  );
});

test('rateLimitKeyFor: 同一/64の2アドレスは同じキー、別/64は別キーになる', () => {
  const a = ipRateLimit.rateLimitKeyFor('2001:db8:85a3:0:aaaa:bbbb:cccc:dddd');
  const b = ipRateLimit.rateLimitKeyFor('2001:db8:85a3:0:1111:2222:3333:4444');
  const c = ipRateLimit.rateLimitKeyFor('2001:db8:85a3:1:aaaa:bbbb:cccc:dddd');
  assert.equal(a, b);
  assert.notEqual(a, c);
});

test('checkAndCount: 同一/64内でIPv6アドレスを変えても同じバケットとして数える(インメモリ経路)', async () => {
  ipRateLimit._reset();
  ipRateLimit._setDurableBinding(null);

  for (let i = 0; i < ipRateLimit.DEFAULT_LIMIT_PER_MIN; i += 1) {
    const ok = await ipRateLimit.checkAndCount('2001:db8:85a3:0:aaaa:bbbb:cccc:dddd');
    assert.equal(ok.allowed, true, `${i + 1}回目は許可されるはず`);
  }
  // 同一/64内の別アドレス(下位64bitだけ変更)は同じバケットを消費済みなので拒否される。
  const denied = await ipRateLimit.checkAndCount('2001:db8:85a3:0:1111:2222:3333:4444');
  assert.equal(denied.allowed, false);

  // 別の/64は影響を受けない。
  const other = await ipRateLimit.checkAndCount('2001:db8:85a3:1::1');
  assert.equal(other.allowed, true);

  ipRateLimit._setDurableBinding(undefined);
});
