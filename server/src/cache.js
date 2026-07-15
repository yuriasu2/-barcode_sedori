'use strict';

/**
 * 簡易LRUキャッシュ。TTL 5分・最大500件。
 * 依存ゼロで実装(Map の挿入順序を利用したLRU)。
 */

const DEFAULT_TTL_MS = 5 * 60 * 1000;
const DEFAULT_MAX_SIZE = 500;

class LruCache {
  constructor({ ttlMs = DEFAULT_TTL_MS, maxSize = DEFAULT_MAX_SIZE } = {}) {
    this.ttlMs = ttlMs;
    this.maxSize = maxSize;
    this.map = new Map(); // key -> { value, expiresAt }
  }

  get(key) {
    const entry = this.map.get(key);
    if (!entry) return undefined;
    if (entry.expiresAt <= Date.now()) {
      this.map.delete(key);
      return undefined;
    }
    // LRU: アクセスされたら末尾に移動
    this.map.delete(key);
    this.map.set(key, entry);
    return entry.value;
  }

  /**
   * @param {string} key
   * @param {*} value
   * @param {number} [ttlMs] このエントリだけのTTL(省略時はインスタンス既定)。
   *   Keepa結果を長め(共有コスト削減)にするなど、エントリ単位で上書きするために使う。
   */
  set(key, value, ttlMs) {
    if (this.map.has(key)) {
      this.map.delete(key);
    } else if (this.map.size >= this.maxSize) {
      // 最も古い(先頭)エントリを削除
      const oldestKey = this.map.keys().next().value;
      this.map.delete(oldestKey);
    }
    const effectiveTtl = typeof ttlMs === 'number' ? ttlMs : this.ttlMs;
    this.map.set(key, { value, expiresAt: Date.now() + effectiveTtl });
  }

  delete(key) {
    this.map.delete(key);
  }

  clear() {
    this.map.clear();
  }

  get size() {
    return this.map.size;
  }
}

module.exports = { LruCache };
