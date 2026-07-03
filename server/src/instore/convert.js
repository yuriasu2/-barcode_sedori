'use strict';

/**
 * コード種別判定 (CHANGES-v2.md準拠)
 *
 * インストアコード(ブックオフ99形式・学習テーブル)は機能ごと削除。
 * 判定は以下の4分類のみ:
 *  - 978/979始まり13桁 -> isbn
 *  - 45/49始まり13桁   -> jan
 *  - 192/191始まり13桁 -> unresolved (reason: book_jan_second_line)
 *  - その他             -> unresolved (reason: unsupported)
 */

const CODE_TYPES = {
  ISBN: 'isbn',
  JAN: 'jan',
  UNRESOLVED: 'unresolved',
};

/** 13桁の数字文字列かどうか */
function isEan13(code) {
  return typeof code === 'string' && /^\d{13}$/.test(code);
}

/**
 * EAN-13/JANのチェックデジットを計算する。
 * 入力は先頭12桁(チェックデジットを除く)。
 * @param {string} body12 12桁の数字文字列
 * @returns {number} チェックデジット(0-9)
 */
function calcEan13CheckDigit(body12) {
  if (!/^\d{12}$/.test(body12)) {
    throw new Error('calcEan13CheckDigit: body must be 12 digits');
  }
  // GS1/JAN(EAN-13)方式: 奇数位(1始まり, 左から)×1 + 偶数位×3 の合計を10の倍数に丸める差分
  let sum = 0;
  for (let i = 0; i < 12; i++) {
    const digit = Number(body12[i]);
    const weight = (i % 2 === 0) ? 1 : 3; // 1桁目(index0)は奇数位=weight1
    sum += digit * weight;
  }
  const mod = sum % 10;
  return mod === 0 ? 0 : 10 - mod;
}

/**
 * 13桁のEAN-13/ISBN-13/JANコードのチェックデジットを検証する。
 * @param {string} code13
 * @returns {boolean}
 */
function validateEan13CheckDigit(code13) {
  if (!isEan13(code13)) return false;
  const body = code13.slice(0, 12);
  const cd = Number(code13[12]);
  return calcEan13CheckDigit(body) === cd;
}

/**
 * strategy配列。上から順に match() を確認し、最初にmatchしたstrategyのresolve()を試す。
 */
const strategies = [
  {
    name: 'isbn13',
    match: (code) => isEan13(code) && (code.startsWith('978') || code.startsWith('979')),
    resolve: (code) => ({
      codeType: CODE_TYPES.ISBN,
      isbn13: code,
      checkDigitValid: validateEan13CheckDigit(code),
    }),
  },
  {
    name: 'jan',
    match: (code) => isEan13(code) && (code.startsWith('45') || code.startsWith('49')),
    resolve: (code) => ({
      codeType: CODE_TYPES.JAN,
      jan: code,
      checkDigitValid: validateEan13CheckDigit(code),
    }),
  },
  {
    name: 'book_jan_second_line',
    // 書籍JANコード2段目 (192/191始まり)。単独では価格/Cコードのみで商品を一意特定できない。
    match: (code) => isEan13(code) && (code.startsWith('192') || code.startsWith('191')),
    resolve: () => ({
      codeType: CODE_TYPES.UNRESOLVED,
      reason: 'book_jan_second_line',
    }),
  },
];

/**
 * コードを判定するメインエントリポイント。
 * @param {string} code 13桁の数字文字列
 * @returns {{codeType: string, isbn13?: string, jan?: string, reason?: string}}
 */
function convertCode(code) {
  if (typeof code !== 'string' || code.trim() === '') {
    return { codeType: CODE_TYPES.UNRESOLVED, reason: 'invalid_format' };
  }
  code = code.trim();

  for (const strategy of strategies) {
    if (strategy.match(code)) {
      const result = strategy.resolve(code);
      if (result) return result;
    }
  }
  return { codeType: CODE_TYPES.UNRESOLVED, reason: 'unsupported' };
}

module.exports = {
  CODE_TYPES,
  isEan13,
  calcEan13CheckDigit,
  validateEan13CheckDigit,
  convertCode,
  strategies,
};
