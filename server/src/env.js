'use strict';

/**
 * .env ファイルの簡易ローダー(dotenv互換の最小実装)。
 * 依存ゼロ構成のため標準fsのみで .env を読み込み process.env にマージする。
 * 既にprocess.envに設定済みの値は上書きしない。
 */

const fs = require('fs');
const path = require('path');

function loadEnv(envPath) {
  const filePath = envPath || path.join(process.cwd(), '.env');
  if (!fs.existsSync(filePath)) return;

  const content = fs.readFileSync(filePath, 'utf8');
  const lines = content.split(/\r?\n/);

  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eqIndex = trimmed.indexOf('=');
    if (eqIndex === -1) continue;
    const key = trimmed.slice(0, eqIndex).trim();
    let value = trimmed.slice(eqIndex + 1).trim();
    // クォート除去
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (!(key in process.env)) {
      process.env[key] = value;
    }
  }
}

module.exports = { loadEnv };
