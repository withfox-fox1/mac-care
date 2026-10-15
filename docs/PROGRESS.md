# 進捗

## 2026-10-15（現在の状態）

### 実装状況
- P0〜P5 完了・コミット済み（土台、クリーンアップ、大容量ファイル、動画圧縮、セキュリティ、アプリ／ログイン項目、スマートケア＋定期実行＋メニューバー）。
- P6（堅牢化）完了：確認ダイアログの既定をキャンセルに統一、確認時点のスナップショットのみ実行、SafeTrash の拒否リスト拡張、許可範囲の絞り込み、クリーンアップの除外ルール（実行中アプリ・never-clean・ドットファイル）、残骸の誤検出対策（Containers は表示のみ）、ログイン項目の無効化の検証強化、動画検証の強化。
- P6（配布）：アプリ／メニューバーアイコン、`install.sh`／`uninstall.sh`／`README.md`／`SETUP_PROMPT.md`。
- セキュリティスキャンの既定を標準モード（ClamAV は `/Applications` 除外）に変更。`deepScan` で従来の範囲。
- テストは `./test.sh`（独自ランナー、XCTest 不使用）。

### 事故の記録と対応
- 2026-10-14 18:13 にユーザーがクリーンアップを実行し、46 項目／1.88GB をゴミ箱へ移動した（`ms-playwright` を含む）。
  - 復元：ゴミ箱から戻す、または `npx playwright install` で再取得。
  - 対応：実行中アプリ・プロセス・提供元の除外、never-clean リスト（ms-playwright ほか）、除外項目の理由表示、確認ダイアログの既定をキャンセルに変更。
- 同日 18:33 に `~/Library/Caches/.DS_Store` が1件ゴミ箱へ移動された（以後ドットファイルは対象外）。

### 次の作業
- P7：CleanMyMac を止めて1週間運用（完成条件 6）。別 Mac への導入確認（`SETUP_PROMPT.md`）。

### 未確認
- 通知の実表示（権限ダイアログが未許可のため）。
- メニューバー拡張ウィンドウの画面確認。

---

## 2026-10-14

### 完了
- CleanMyMac 5（v5.7.1）の機能をアプリ内の文言・モジュール構成から洗い出し（GUI 操作なし）。
- ディスク使用状況の調査（読み取りのみ）。結果は SPEC.md 1.2。
- `brew install yara clamav`（yara 4.5.8 / clamav 1.5.4）。`/opt/homebrew/etc/clamav/freshclam.conf` を作成し `freshclam` で定義取得（daily 28152）。定義の自動更新は未設定。
- Downloads のスキャン：YARA(XProtect) 0件、ClamAV 0件。ClamAV は EICAR 検出を確認。
  - 制約：YARA は 200MB 超を除外、ClamAV は大容量ファイルを既定上限で打ち切り（73.8GB 読込中 9.2GB を検査）。
  - YARA ルールの「陽性検出」は未検証。
- 動画圧縮テスト（60秒区間）：100.8MB → 15.9MB、SSIM 0.993。
- SPEC / ROADMAP / DECISIONS 作成。

### 次の作業
- ユーザーの承認後、P0 着手。

### 未決定
- アプリ名（仮称 MacCare）
- GitHub リポジトリの公開範囲（public / private）

### 注意事項
- ターミナルにフルディスクアクセスがなく `~/.Trash` は未調査。
- 削除対象外：`~/Library/Application Support/Claude/vm_bundles`（10GB）、`~/voicevox_engine`。
