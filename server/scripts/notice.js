'use strict';

/**
 * 障害告知(notice)を対話式で配信/停止するスクリプト。
 *
 * これまでは `npx wrangler kv key put --remote --binding ADS_CONFIG notice '{...}'`
 * のような長いコマンドを手打ちする必要があり、障害対応中の作業としては危険で面倒だった。
 * このスクリプトはそれを対話式のメニューに置き換える。
 *
 * - `npm run notice` から実行する(cwd は server/ を想定)。
 * - 本番KV(ADS_CONFIG namespace の notice キー)を直接読み書きする。
 *   wrangler v4 の KV 操作は既定でローカル環境を見るため、必ず `--remote` を付ける。
 * - 依存ゼロ方針のため、Node標準モジュール(readline/promises, child_process 等)のみを使う。
 * - KVへ渡すJSONはシェル経由で組み立てず、一時ファイルに書いて
 *   `wrangler kv key put --path <file>` で渡す(本文中の引用符・改行での破損を避けるため)。
 */

const readline = require('node:readline/promises');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const KV_BINDING = 'ADS_CONFIG';
const KV_KEY = 'notice';
// server/src/routes.js の NOTICE_URL_PREFIX / NOTICE_TITLE_MAX_LEN / NOTICE_BODY_MAX_LEN と
// 揃えること(ここで弾いておかないと配信してもサーバー側で無視されるだけで気付きにくい)。
const NOTICE_URL_PREFIX = 'https://sellira.jp/';
const TITLE_MAX_LEN = 100;
const BODY_MAX_LEN = 1000;

// --- wrangler呼び出し ---

/**
 * 本番KVから notice キーを読む。
 * 戻り値:
 *   { ok: true, raw: string|null }  読み取り成功(raw=nullはキー無し)
 *   { ok: false, message: string }  読み取り失敗(認証切れ等)
 */
function kvGet() {
  const result = spawnSync(
    'npx',
    ['wrangler', 'kv', 'key', 'get', KV_KEY, '--binding', KV_BINDING, '--remote', '--text'],
    { encoding: 'utf8', timeout: 60_000 }
  );

  if (result.error) {
    if (result.error.code === 'ETIMEDOUT') {
      return {
        ok: false,
        message: 'wranglerが60秒以内に応答しませんでした(認証が切れている可能性があります)',
      };
    }
    return { ok: false, message: result.error.message };
  }
  if (result.status === 0) {
    const raw = typeof result.stdout === 'string' ? result.stdout.replace(/\n$/, '') : result.stdout;
    return { ok: true, raw: raw || null };
  }

  const stderr = (result.stderr || '').trim();
  // wrangler(remote)はキーが存在しない場合、Cloudflare APIのエラー(key not found等)を
  // 標準エラーに出して非ゼロ終了する。これは「告知なし」であって「取得失敗」ではないので
  // 区別する。
  if (/key not found|not found/i.test(stderr)) {
    return { ok: true, raw: null };
  }
  return { ok: false, message: stderr || `wrangler がコード ${result.status} で終了しました` };
}

/**
 * 本番KVへ notice キーを書き込む。JSON文字列を一時ファイルへ書いて --path で渡すことで、
 * シェルのクォート・改行問題を回避する。
 * 戻り値は spawnSync の結果(status/stderr/stdout/error)そのもの。
 * wranglerが60秒以内に応答しない場合(認証切れ等でプロンプトが出て止まっている場合)は
 * result.error.code === 'ETIMEDOUT' となり、result.status は null になる。
 */
function kvPut(jsonString) {
  const tmpFile = path.join(os.tmpdir(), `sellira-notice-${Date.now()}-${process.pid}.json`);
  fs.writeFileSync(tmpFile, jsonString, 'utf8');
  try {
    return spawnSync(
      'npx',
      ['wrangler', 'kv', 'key', 'put', KV_KEY, '--binding', KV_BINDING, '--remote', '--path', tmpFile],
      { encoding: 'utf8', timeout: 60_000 }
    );
  } finally {
    try {
      fs.unlinkSync(tmpFile);
    } catch {
      // 一時ファイル削除の失敗は無視する(OSの一時領域クリーンアップに任せる)。
    }
  }
}

/**
 * kvPut() の spawnSync 結果からエラーメッセージを組み立てる。
 * result.error がある場合(タイムアウト含む)を最優先で扱う。
 */
function formatKvPutError(result) {
  if (result.error) {
    if (result.error.code === 'ETIMEDOUT') {
      return 'wranglerが60秒以内に応答しませんでした(認証が切れている可能性があります)';
    }
    return result.error.message;
  }
  return (result.stderr || result.stdout || `wrangler がコード ${result.status} で終了しました`).trim();
}

// --- 現在の状態の読み込み・表示 ---

/**
 * 現在の告知状態を読み込む。
 * 戻り値:
 *   { state: 'ok', notice: {...} }  読み取り成功(告知オブジェクトそのまま。activeを含む)
 *   { state: 'none' }               告知なし(キー無し)
 *   { state: 'error', message }     読み取り失敗、またはJSON破損
 */
function loadCurrentNotice() {
  const result = kvGet();
  if (!result.ok) {
    return { state: 'error', message: result.message };
  }
  if (!result.raw) {
    return { state: 'none' };
  }
  let parsed;
  try {
    parsed = JSON.parse(result.raw);
  } catch (err) {
    return { state: 'error', message: `KVの値がJSONとして解析できませんでした(${err.message})` };
  }
  if (!parsed || typeof parsed !== 'object') {
    return { state: 'error', message: 'KVの値がオブジェクトではありません' };
  }
  return { state: 'ok', notice: parsed };
}

function printCurrentState(loaded) {
  console.log('▼ 現在の状態');
  if (loaded.state === 'error') {
    console.log(`  現在の状態を取得できませんでした(理由: ${loaded.message})`);
    return;
  }
  if (loaded.state === 'none') {
    console.log('  状態  : 告知なし');
    return;
  }
  const n = loaded.notice;
  console.log(`  状態  : ${n.active === true ? '配信中' : '停止中'}`);
  console.log(`  id    : ${n.id}`);
  console.log(`  題名  : ${n.title}`);
  console.log(`  本文  : ${n.body}`);
  console.log(`  URL   : ${n.url || '(無し)'}`);
}

// --- id生成(JST, YYYY-MM-DD-HHmmss) ---

/**
 * 告知idをJSTの現在時刻から生成する。
 * 秒まで含める理由: 分単位だと、配信直後に誤字へ気づいて同じ分内に再配信した場合に
 * idが衝突してしまい、既に告知を閉じた(既読にした)ユーザーには修正版が二度と
 * 表示されなくなる。障害対応中は慌てて書くため、これは十分起こり得る。
 */
function generateNoticeId(now = new Date()) {
  const jst = new Date(now.getTime() + 9 * 60 * 60 * 1000);
  const yyyy = jst.getUTCFullYear();
  const mm = String(jst.getUTCMonth() + 1).padStart(2, '0');
  const dd = String(jst.getUTCDate()).padStart(2, '0');
  const hh = String(jst.getUTCHours()).padStart(2, '0');
  const mi = String(jst.getUTCMinutes()).padStart(2, '0');
  const ss = String(jst.getUTCSeconds()).padStart(2, '0');
  return `${yyyy}-${mm}-${dd}-${hh}${mi}${ss}`;
}

// --- 入力ヘルパー ---

async function askRequiredText(rl, promptLabel, maxLen) {
  for (;;) {
    const value = (await rl.question(promptLabel)).trim();
    if (!value) {
      console.log('  空にはできません。もう一度入力してください。');
      continue;
    }
    if (value.length > maxLen) {
      console.log(`  ${maxLen}文字以内で入力してください(現在 ${value.length}文字)。`);
      continue;
    }
    return value;
  }
}

async function askOptionalUrl(rl) {
  for (;;) {
    const value = (await rl.question('詳細ページのURL (省略可。Enterで無し): ')).trim();
    if (!value) return null;
    if (!value.startsWith(NOTICE_URL_PREFIX)) {
      console.log(`  URLは "${NOTICE_URL_PREFIX}" で始まる必要があります。もう一度入力してください。`);
      continue;
    }
    return value;
  }
}

async function askYesNo(rl, promptLabel) {
  const answer = (await rl.question(promptLabel)).trim();
  return answer === 'yes';
}

async function askMenuChoice(rl) {
  for (;;) {
    console.log('何をしますか?');
    console.log('  1) 新しい告知を出す');
    console.log('  2) 配信中の告知を止める');
    console.log('  3) 何もせず終了');
    const answer = (await rl.question('> ')).trim();
    if (answer === '1' || answer === '2' || answer === '3') return answer;
    console.log('1〜3の数字で入力してください。');
    console.log('');
  }
}

// --- 各メニューの処理 ---

async function handleNewNotice(rl, loaded) {
  const title = await askRequiredText(rl, `題名 (${TITLE_MAX_LEN}文字以内): `, TITLE_MAX_LEN);
  const body = await askRequiredText(rl, `本文 (${BODY_MAX_LEN}文字以内): `, BODY_MAX_LEN);
  const url = await askOptionalUrl(rl);
  const id = generateNoticeId();

  console.log('');
  console.log('▼ この内容で配信します');
  console.log(`  id    : ${id}`);
  console.log(`  題名  : ${title}`);
  console.log(`  本文  : ${body}`);
  console.log(`  URL   : ${url || '(無し)'}`);
  console.log('');
  console.log('  ※ 新しいidのため、以前に告知を閉じた人にも再度表示されます。');
  console.log('  ※ 反映まで最大60秒かかります(サーバーキャッシュのため)。');
  if (loaded.state === 'ok' && loaded.notice.active === true) {
    console.log(`  ※ 現在配信中の告知「${loaded.notice.title}」は、この内容で上書きされます。`);
  }
  console.log('');

  const confirmed = await askYesNo(rl, '本当に配信しますか? (yes/no) > ');
  if (!confirmed) {
    console.log('キャンセルしました。');
    return;
  }

  const notice = { id, active: true, title, body, ...(url ? { url } : {}) };
  const result = kvPut(JSON.stringify(notice, null, 2));
  if (result.status === 0) {
    console.log('配信しました。反映まで最大60秒かかります。');
  } else {
    console.error('配信に失敗しました:');
    console.error(formatKvPutError(result));
    process.exitCode = 1;
  }
}

async function handleStopNotice(rl, loaded) {
  if (loaded.state === 'error') {
    console.log('現在の状態が読み取れていないため、停止操作はできません(何を書き戻すべきか分からないため)。');
    return;
  }
  if (loaded.state === 'none') {
    console.log('配信中の告知はありません。');
    return;
  }
  if (loaded.notice.active !== true) {
    console.log('配信中の告知はありません。');
    return;
  }

  console.log('');
  console.log('▼ 配信中の告知を停止します');
  console.log(`  id    : ${loaded.notice.id}`);
  console.log(`  題名  : ${loaded.notice.title}`);
  console.log('');

  const confirmed = await askYesNo(rl, '本当に停止しますか? (yes/no) > ');
  if (!confirmed) {
    console.log('キャンセルしました。');
    return;
  }

  const updated = { ...loaded.notice, active: false };
  const result = kvPut(JSON.stringify(updated, null, 2));
  if (result.status === 0) {
    console.log('停止しました。反映まで最大60秒かかります。');
  } else {
    console.error('停止に失敗しました:');
    console.error(formatKvPutError(result));
    process.exitCode = 1;
  }
}

// --- エントリポイント ---

async function main() {
  console.log('=== アマレンズ 障害告知の配信 ===');
  console.log('※ 本番環境(api.sellira.jp)に配信されます');
  console.log('');
  console.log('現在の告知を確認しています...');
  console.log('');

  const loaded = loadCurrentNotice();
  printCurrentState(loaded);
  console.log('');

  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  try {
    const choice = await askMenuChoice(rl);
    console.log('');
    if (choice === '1') {
      await handleNewNotice(rl, loaded);
    } else if (choice === '2') {
      await handleStopNotice(rl, loaded);
    } else {
      console.log('何もせず終了します。');
    }
  } finally {
    rl.close();
  }
}

main().catch((err) => {
  console.error(`予期しないエラーが発生しました: ${err.message}`);
  process.exitCode = 1;
});
