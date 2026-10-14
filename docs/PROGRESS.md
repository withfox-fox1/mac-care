# 進捗

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
