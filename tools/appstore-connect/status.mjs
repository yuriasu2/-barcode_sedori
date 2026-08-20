// 審査ステータスの確認。もっとも頻繁に使うため専用コマンドにしている。
//
// バージョンの状態・紐付いたビルド番号・メモ欄の文字数・提出物の内訳を1画面で出す。
// 却下されている場合は、Web UIを開かなくても却下理由(ガイドライン番号)まで分かる。
//
// 使い方は README.md 参照。
import { asc, defaultAppId } from './asc.mjs';

// 対象アプリ。configのdefaultAppId(またはASC_APP_ID)で切り替えられるため、
// このスクリプト自体はセラーレンズ専用ではない。
const APP_ID = process.argv[2] || defaultAppId;
if (!APP_ID) {
  console.error('アプリIDが未指定です。引数で渡すか、configにdefaultAppIdを設定してください。');
  process.exit(1);
}

const app = await asc('GET', `/v1/apps/${APP_ID}?fields[apps]=name,bundleId`);
console.log(`# ${app.data.attributes.name} (${app.data.attributes.bundleId})\n`);

const versions = await asc('GET', `/v1/apps/${APP_ID}/appStoreVersions?limit=5`);
for (const ver of versions.data) {
  const a = ver.attributes;
  // appStoreState は新しいAPIで appVersionState に置き換わったが、
  // 環境によってどちらが返るか異なるため両方見る。
  console.log(`## バージョン ${a.versionString} — ${a.appStoreState ?? a.appVersionState}`);

  try {
    const b = await asc('GET', `/v1/appStoreVersions/${ver.id}/build`);
    console.log(`   ビルド : ${b.data ? b.data.attributes.version : '(未選択)'}`);
  } catch {
    console.log('   ビルド : (取得不可)');
  }

  try {
    const d = await asc('GET', `/v1/appStoreVersions/${ver.id}/appStoreReviewDetail`);
    const n = d.data?.attributes?.notes;
    console.log(`   メモ欄 : ${n ? `${n.length}文字` : '(空)'}`);
  } catch {
    console.log('   メモ欄 : (未作成)');
  }
  console.log();
}

// 提出物の状態。却下時はここに理由が出る。
const subs = await asc('GET', `/v1/reviewSubmissions?filter[app]=${APP_ID}&limit=5`);
for (const sub of subs.data) {
  const a = sub.attributes;
  // 完了済みの古い提出まで並べると読みにくいので、進行中のものだけ詳細を出す。
  if (a.state === 'COMPLETE') {
    console.log(`## 提出 ${sub.id.slice(0, 8)} — ${a.state} (${a.submittedDate})`);
    continue;
  }
  console.log(`## 提出 ${sub.id.slice(0, 8)} — ${a.state}`);
  console.log(`   提出日時 : ${a.submittedDate}`);
  const items = await asc('GET', `/v1/reviewSubmissions/${sub.id}/items?limit=20`);
  for (const it of items.data) {
    console.log(`   - ${it.attributes.state}`);
  }
  console.log();
}
