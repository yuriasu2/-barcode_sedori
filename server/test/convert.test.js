'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  calcEan13CheckDigit,
  validateEan13CheckDigit,
  convertCode,
  CODE_TYPES,
} = require('../src/instore/convert');

test('calcEan13CheckDigit: 既知ISBNのチェックデジットを正しく計算する', () => {
  // 9784471103644 -> body12 = 978447110364, CD = 4
  assert.equal(calcEan13CheckDigit('978447110364'), 4);
});

test('validateEan13CheckDigit: 正しいISBN-13はtrueを返す', () => {
  assert.equal(validateEan13CheckDigit('9784471103644'), true);
});

test('validateEan13CheckDigit: チェックデジットが誤っているとfalseを返す', () => {
  assert.equal(validateEan13CheckDigit('9784471103645'), false);
});

test('validateEan13CheckDigit: 13桁でない/数字でない場合はfalse', () => {
  assert.equal(validateEan13CheckDigit('123'), false);
  assert.equal(validateEan13CheckDigit('978447110364a'), false);
});

test('convertCode: 978始まりはISBNとして判定される', () => {
  const result = convertCode('9784471103644');
  assert.equal(result.codeType, CODE_TYPES.ISBN);
  assert.equal(result.isbn13, '9784471103644');
  assert.equal(result.checkDigitValid, true);
});

test('convertCode: 979始まりもISBNとして判定される', () => {
  // 979から始まる13桁ダミー(チェックデジットは検証結果のみ確認、種別判定が目的)
  const body12 = '979123456789';
  const cd = calcEan13CheckDigit(body12);
  const code = body12 + String(cd);
  const result = convertCode(code);
  assert.equal(result.codeType, CODE_TYPES.ISBN);
});

test('convertCode: 45/49始まりはJANとして判定される', () => {
  const body12 = '450123456789';
  const cd = calcEan13CheckDigit(body12);
  const code = body12 + String(cd);
  const result = convertCode(code);
  assert.equal(result.codeType, CODE_TYPES.JAN);
  assert.equal(result.jan, code);
});

test('convertCode: 49始まりもJANとして判定される', () => {
  const body12 = '490123456789';
  const cd = calcEan13CheckDigit(body12);
  const code = body12 + String(cd);
  const result = convertCode(code);
  assert.equal(result.codeType, CODE_TYPES.JAN);
  assert.equal(result.jan, code);
});

test('convertCode: 192始まり(書籍JAN2段目)はunresolved(book_jan_second_line)になる', () => {
  const body12 = '192123456789';
  const cd = calcEan13CheckDigit(body12);
  const code = body12 + String(cd);
  const result = convertCode(code);
  assert.equal(result.codeType, CODE_TYPES.UNRESOLVED);
  assert.equal(result.reason, 'book_jan_second_line');
});

test('convertCode: 191始まり(書籍JAN2段目)もunresolved(book_jan_second_line)になる', () => {
  const body12 = '191123456789';
  const cd = calcEan13CheckDigit(body12);
  const code = body12 + String(cd);
  const result = convertCode(code);
  assert.equal(result.codeType, CODE_TYPES.UNRESOLVED);
  assert.equal(result.reason, 'book_jan_second_line');
});

test('convertCode: チェックデジットが不正な13桁はunresolved(unsupported)になる', () => {
  const result = convertCode('2012345678905');
  assert.equal(result.codeType, CODE_TYPES.UNRESOLVED);
  assert.equal(result.reason, 'unsupported');
});

test('convertCode: 45/49以外でもチェックデジット有効な13桁はJANになる(全EAN-13対応)', () => {
  // 3045387245504 はフランス(GS1プレフィックス30)の有効なEAN-13
  const result = convertCode('3045387245504');
  assert.equal(result.codeType, CODE_TYPES.JAN);
  assert.equal(result.jan, '3045387245504');
  assert.equal(result.checkDigitValid, true);
});

test('convertCode: 192始まりは全EAN-13対応後もjanに飲まれずunresolvedのまま(順序回帰)', () => {
  const body12 = '192123456789';
  const cd = calcEan13CheckDigit(body12); // 有効なCDを付与
  const code = body12 + String(cd);
  const result = convertCode(code);
  assert.equal(result.codeType, CODE_TYPES.UNRESOLVED);
  assert.equal(result.reason, 'book_jan_second_line');
});

test('convertCode: 13桁EANでないコードはunresolved(unsupported)になる', () => {
  const result = convertCode('12345');
  assert.equal(result.codeType, CODE_TYPES.UNRESOLVED);
  assert.equal(result.reason, 'unsupported');
});

test('convertCode: 空文字・非文字列はinvalid_format', () => {
  assert.equal(convertCode('').reason, 'invalid_format');
  assert.equal(convertCode(null).reason, 'invalid_format');
});
