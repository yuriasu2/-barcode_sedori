'use strict';

/**
 * AdMobリワード広告のサーバーサイド検証(SSV: Server-Side Verification)。
 *
 * 背景:
 * 無料ユーザーが動画広告を最後まで視聴したら無料枠を+5するが、クライアントの自己申告
 * (「見ました」というAPI呼び出し)だけを信じると、動画を見ずに任意の回数だけ枠を
 * 水増しできてしまう。AdMob SSVは、Googleのサーバーが実際に広告が完了したことを
 * 確認した上で、こちらが指定したコールバックURLへ**署名付き**のGETリクエストを送ってくる
 * 仕組み。この署名を検証できて初めて「本当に広告を見た」と信頼できる。
 *
 * 署名検証の要点(公式仕様):
 * - パラメータはアルファベット順に並ぶが、末尾2つは必ず signature, key_id の順で固定。
 * - 署名対象(signed content)は「クエリ文字列の先頭から '&signature=' の直前まで」の
 *   UTF-8バイト列。**生のクエリ文字列をそのまま使う必要がある**(パース後に
 *   URLSearchParams等で再シリアライズすると、エンコード方式の違い(スペースの
 *   %20/+表現、大文字小文字の16進エスケープなど)で元のバイト列と一致しなくなり、
 *   正しい署名でも検証に失敗し得るため)。
 * - 公開鍵は https://www.gstatic.com/admob/reward/verifier-keys.json から取得し、
 *   base64フィールドがDER形式のSubjectPublicKeyInfo(spki)。ローテーションされるため
 *   24時間を超えてキャッシュしてはいけない(このモジュールは23時間でキャッシュ切れとする)。
 * - 署名アルゴリズムはECDSA(P-256/SHA-256)、符号化はDER、クエリ内はbase64url。
 *
 * 重要な落とし穴(DER→raw変換):
 * WebCryptoのcrypto.subtle.verifyはECDSA署名を「raw形式(r||sの64バイト連結)」で
 * 要求するが、AdMobから届く署名はDER形式(0x30 <len> 0x02 <rLen> <r> 0x02 <sLen> <s>)。
 * DERのままcrypto.subtle.verifyへ渡すと(例外にならず)常に検証失敗になるため、
 * 明示的にraw形式へ変換する必要がある。DERの整数は符号ビット衝突回避のため先頭に
 * 0x00パディングが付くことがある一方、rawは常に固定長(P-256なら32バイト)・左詰め
 * ゼロ埋めが必要なため、単純なバイト列のスライスでは変換できない。
 *
 * Node/Workers両対応:
 * crypto.subtle はCloudflare Workersではグローバルに存在する。Node 18+ でも
 * globalThis.crypto.subtle がグローバルに存在するが、念のため
 * require('crypto').webcrypto.subtle へのフォールバックを用意する。
 */

const VERIFIER_KEYS_URL = 'https://www.gstatic.com/admob/reward/verifier-keys.json';

// 公開鍵はロテーションされるため24時間を超えてキャッシュしてはいけない。安全マージンを
// 取って23時間で失効させる。
// 注意: Cloudflare WorkersはリクエストごとにisolateがWorker間で共有されないことがあり、
// このモジュールスコープの変数によるキャッシュは「isolate単位」になる(全世界で1つの
// グローバルキャッシュにはならない)。isolateはCloudflareのエッジ拠点/時間経過で
// 入れ替わるため、実質的には「isolateが生きている間・最大23時間」のキャッシュとなる。
const KEY_CACHE_TTL_MS = 23 * 60 * 60 * 1000;

/** @type {Array<{keyId:number|string, pem?:string, base64:string}>|null} */
let cachedKeys = null;
let cachedAt = 0;

/**
 * テスト専用フック。非nullを設定すると、fetchVerifierKeysは実ネットワークへ
 * アクセスせず、このオーバーライド配列をそのまま返す(forceRefreshの有無にかかわらず)。
 * null(既定)に戻すと通常のネットワーク取得+キャッシュ挙動に戻る。
 * @param {Array<{keyId:number|string, base64:string}>|null} keys
 */
function _setKeysForTest(keys) {
  keysOverride = keys;
}
let keysOverride = null;

/**
 * AdMobの検証用公開鍵一覧を取得する。23時間以内の取得結果があればそれを使い回す。
 * @param {{forceRefresh?: boolean}} [opts] forceRefresh:trueならキャッシュを無視して再取得する
 *   (key_idに一致する鍵が見つからない場合の、ローテーション直後を救うための1回きりのリトライ用)。
 * @returns {Promise<Array<{keyId:number|string, base64:string}>>}
 */
async function fetchVerifierKeys(opts) {
  if (keysOverride !== null) return keysOverride;

  const forceRefresh = !!(opts && opts.forceRefresh);
  const now = Date.now();
  if (!forceRefresh && cachedKeys && now - cachedAt < KEY_CACHE_TTL_MS) {
    return cachedKeys;
  }

  const res = await fetch(VERIFIER_KEYS_URL);
  if (!res.ok) {
    throw new Error(`verifier-keys.json の取得に失敗しました: HTTP ${res.status}`);
  }
  const data = await res.json();
  const keys = Array.isArray(data && data.keys) ? data.keys : [];
  cachedKeys = keys;
  cachedAt = now;
  return keys;
}

/**
 * base64url文字列をUint8Arrayへデコードする。
 * '-'→'+', '_'→'/' に置換し、長さが4の倍数になるまで'='を補ってから通常のbase64として
 * デコードする(標準base64を渡しても、置換対象文字が含まれず既に4の倍数長のため無害)。
 * @param {string} str
 * @returns {Uint8Array}
 */
function base64UrlToBytes(str) {
  let normalized = String(str).replace(/-/g, '+').replace(/_/g, '/');
  while (normalized.length % 4 !== 0) normalized += '=';
  const buf = Buffer.from(normalized, 'base64');
  return new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
}

/**
 * DERの長さフィールドを読む(短形式1バイト、長形式は先頭バイトの下位7bitが後続バイト数)。
 * @param {Uint8Array} bytes
 * @param {number} offset 長さフィールドの開始位置
 * @returns {{length:number, offset:number}} lengthと、長さフィールドを読み終えた後のoffset
 */
function readDerLength(bytes, offset) {
  if (offset >= bytes.length) throw new Error('invalid DER signature: unexpected end of data (length)');
  const first = bytes[offset];
  let pos = offset + 1;
  if ((first & 0x80) === 0) {
    return { length: first, offset: pos };
  }
  const numBytes = first & 0x7f;
  if (numBytes === 0 || numBytes > 4) {
    throw new Error('invalid DER signature: unsupported length encoding');
  }
  if (pos + numBytes > bytes.length) {
    throw new Error('invalid DER signature: unexpected end of data (long-form length)');
  }
  let length = 0;
  for (let i = 0; i < numBytes; i += 1) {
    length = (length << 8) | bytes[pos + i];
    pos += 1;
  }
  return { length, offset: pos };
}

/**
 * DERのINTEGER(0x02 <len> <bytes>)を読む。
 * @param {Uint8Array} bytes
 * @param {number} offset INTEGERタグの位置
 * @returns {{bytes:Uint8Array, offset:number}} 整数の中身(先頭0x00パディング込み)と、読み終えた後のoffset
 */
function readDerInteger(bytes, offset) {
  if (bytes[offset] !== 0x02) {
    throw new Error('invalid DER signature: expected INTEGER tag (0x02)');
  }
  const { length, offset: afterLen } = readDerLength(bytes, offset + 1);
  const start = afterLen;
  const end = start + length;
  if (end > bytes.length) {
    throw new Error('invalid DER signature: INTEGER length exceeds buffer');
  }
  return { bytes: bytes.slice(start, end), offset: end };
}

/**
 * DERのINTEGERの中身(先頭に0x00パディングが付き得る可変長バイト列)を、P-256用の
 * 固定長32バイト・左詰めゼロ埋めのraw形式へ変換する。
 * @param {Uint8Array} intBytes
 * @returns {Uint8Array} 32バイト
 */
function toFixed32(intBytes) {
  let b = intBytes;
  let i = 0;
  // 符号ビット衝突回避用に付与された先頭0x00パディングを取り除く(値自体は変えない)。
  while (i < b.length - 1 && b[i] === 0x00) i += 1;
  b = b.slice(i);
  if (b.length > 32) {
    throw new Error('invalid DER signature: integer too large for P-256 (>32 bytes)');
  }
  const out = new Uint8Array(32);
  out.set(b, 32 - b.length); // 左詰めゼロ埋め
  return out;
}

/**
 * ECDSA署名のDER形式(0x30 <len> 0x02 <rLen> <r> 0x02 <sLen> <s>)を、
 * WebCryptoのcrypto.subtle.verifyが要求するraw形式(r||sの64バイト連結)へ変換する。
 * 不正なDERは例外を投げる。
 * @param {Uint8Array|ArrayBuffer} derBytes
 * @returns {Uint8Array} 64バイト(r 32バイト + s 32バイト)
 */
function derToRawSignature(derBytes) {
  const bytes = derBytes instanceof Uint8Array ? derBytes : new Uint8Array(derBytes);
  if (bytes.length < 2 || bytes[0] !== 0x30) {
    throw new Error('invalid DER signature: expected SEQUENCE tag (0x30)');
  }
  const seq = readDerLength(bytes, 1);
  const r = readDerInteger(bytes, seq.offset);
  const s = readDerInteger(bytes, r.offset);

  const rawR = toFixed32(r.bytes);
  const rawS = toFixed32(s.bytes);

  const out = new Uint8Array(64);
  out.set(rawR, 0);
  out.set(rawS, 32);
  return out;
}

/** globalThis.crypto.subtle優先、無ければNodeのwebcryptoへフォールバックする。 */
function getSubtle() {
  if (globalThis.crypto && globalThis.crypto.subtle) return globalThis.crypto.subtle;
  // eslint-disable-next-line global-require
  return require('crypto').webcrypto.subtle;
}

/**
 * rawQuery(クエリ文字列。先頭に'?'は含まない)から、指定パラメータの生の値を取り出す。
 * URLSearchParamsで再パースせず正規表現で直接抜き出すのは、値を必ず生のクエリ文字列
 * (signed contentと同じ入力)から取得するため。値は仕様どおりdecodeURIComponentしてから返す。
 * @param {string} rawQuery
 * @param {string} name
 * @returns {string|null}
 */
function extractRawParam(rawQuery, name) {
  const re = new RegExp(`(?:^|&)${name}=([^&]*)`);
  const m = rawQuery.match(re);
  if (!m) return null;
  try {
    return decodeURIComponent(m[1]);
  } catch (err) {
    return null;
  }
}

/**
 * AdMob SSVコールバックの署名を検証する。
 * @param {string} rawQuery '?'を含まない生のクエリ文字列(パース前・再エンコードなし)
 * @returns {Promise<{valid:boolean, reason?:string}>}
 */
async function verifySsv(rawQuery) {
  if (typeof rawQuery !== 'string' || !rawQuery) {
    return { valid: false, reason: 'empty_query' };
  }

  // signed content = クエリ文字列の先頭から '&signature=' の直前まで。
  // 再シリアライズすると符号化が変わり検証に失敗するため、必ず生の文字列をスライスする。
  const sigMarker = '&signature=';
  const idx = rawQuery.indexOf(sigMarker);
  if (idx === -1) {
    return { valid: false, reason: 'signature_param_not_found' };
  }
  const signedContent = rawQuery.slice(0, idx);

  const signature = extractRawParam(rawQuery, 'signature');
  const keyId = extractRawParam(rawQuery, 'key_id');
  if (!signature || !keyId) {
    return { valid: false, reason: 'missing_signature_or_key_id' };
  }

  let keys;
  try {
    keys = await fetchVerifierKeys();
  } catch (err) {
    return { valid: false, reason: `verifier_keys_fetch_failed: ${err.message}` };
  }

  let keyEntry = keys.find((k) => String(k.keyId) === String(keyId));
  if (!keyEntry) {
    // key_idが見つからない場合、ローテーション直後の可能性があるため一度だけ強制再取得してリトライする。
    try {
      keys = await fetchVerifierKeys({ forceRefresh: true });
    } catch (err) {
      return { valid: false, reason: `verifier_keys_fetch_failed: ${err.message}` };
    }
    keyEntry = keys.find((k) => String(k.keyId) === String(keyId));
  }
  if (!keyEntry) {
    return { valid: false, reason: 'unknown_key_id' };
  }

  let rawSignature;
  try {
    const sigBytes = base64UrlToBytes(signature);
    rawSignature = derToRawSignature(sigBytes);
  } catch (err) {
    return { valid: false, reason: `invalid_signature_encoding: ${err.message}` };
  }

  const subtle = getSubtle();

  let cryptoKey;
  try {
    const spkiBytes = base64UrlToBytes(keyEntry.base64);
    cryptoKey = await subtle.importKey('spki', spkiBytes, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
  } catch (err) {
    return { valid: false, reason: `invalid_public_key: ${err.message}` };
  }

  try {
    const valid = await subtle.verify(
      { name: 'ECDSA', hash: 'SHA-256' },
      cryptoKey,
      rawSignature,
      new TextEncoder().encode(signedContent)
    );
    return valid ? { valid: true } : { valid: false, reason: 'signature_mismatch' };
  } catch (err) {
    return { valid: false, reason: `verify_error: ${err.message}` };
  }
}

module.exports = {
  fetchVerifierKeys,
  derToRawSignature,
  base64UrlToBytes,
  verifySsv,
  _setKeysForTest,
};
