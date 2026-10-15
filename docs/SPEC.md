# MacCare 仕様書（v0.1 草案）

> 名称「MacCare」は仮称。変更可。

## 1. 目的

CleanMyMac（現行 CleanMyMac 5 / v5.7.1）を解約しても困らない状態を、自作アプリで実現する。
対象は CleanMyMac で日常的に使っていた 5 機能（スマートケア／クリーンアップ／セキュリティ保護／パフォーマンス／アプリケーション）と、
本 Mac で実際に容量を占めている大容量動画の圧縮。

### 1.1 想定ユーザー

- 本人（このMac）と、別の Mac（GitHub リポジトリ＋SETUP_PROMPT.md で導入）。
- 管理者権限を持つ macOS ユーザー。ターミナル操作は不要な前提で UI を作る。

### 1.2 現状調査の結果（2026-10-14、読み取りのみ）

| 項目 | 値 |
|---|---|
| ディスク | 494GB 中 空き 245GB（使用 約47%） |
| 安全に消せる不要データ | 合計 3〜5GB 程度（Caches 1.2GB、npm 311MB、未使用 node_modules 約1GB、Codex ランタイム等） |
| 最大の容量 | `~/Downloads/ナレッジ` 56GB（画面収録 .mov、H.264 2940×1912 約12.5Mbps） |
| 動画圧縮テスト | 60秒区間を HEVC（hevc_videotoolbox, -q:v 50）で 100.8MB → 15.9MB（約16%）。SSIM 0.993、目視で差なし。変換速度は約1.7倍速 |
| ウイルススキャン | YARA＋XProtect ルール（500件）：Downloads を12.6秒・検出0。ClamAV：3分46秒・検出0、EICAR 検出を確認済み |

## 2. 機能要件

### 2.1 画面構成（メニューバー＋ウィンドウ）

- **メニューバー**：空き容量、前回スキャン結果（脅威数・掃除できる量）、「スマートケアを実行」「ウィンドウを開く」。
- **ウィンドウ**（左サイドバー＋右ペイン）：スマートケア／クリーンアップ／大容量ファイル／動画圧縮／アプリケーション／ログイン項目／セキュリティ／履歴／設定。
- Dock アイコンはウィンドウ表示中のみ出す。

### 2.2 スマートケア

ボタン1つで「不要データの集計」「セキュリティスキャン」「ログイン項目の変化チェック」を実行し、結果を1画面にまとめる。
削除は結果画面で確認してから実行する（自動削除しない）。

### 2.3 クリーンアップ（不要データ）

- 対象は**許可リスト方式**（リストにないパスには一切触れない）。初期リスト：
  - `~/Library/Caches/*`（除外：ドットで始まる項目、`com.apple.*`、実行中アプリ・プロセスに関連するもの（バンドルID・実行ファイル名・表示名・提供元）、再取得が高コスト／システム管理のもの（ms-playwright、CloudKit、GeoServices、PassKit、GameKit、FamilyCircle）。除外した項目は理由つきで画面に表示する）
  - `~/Library/Logs/*`
  - `~/.npm/_cacache`、Homebrew キャッシュ（`brew --cache`）、pip キャッシュ
  - Xcode：`DerivedData`、古い `iOS DeviceSupport`、`Archives`（存在する場合）
  - 指定日数以上更新のないプロジェクトの `node_modules`（検索範囲は設定で指定）
  - ゴミ箱（「空にする」操作のみ。フルディスクアクセスが必要）
- 削除は `FileManager.trashItem`（ゴミ箱へ移動）。完全削除はしない（ゴミ箱を空にする操作を除く）。
- 項目ごとにサイズ・説明・「消すとどうなるか」を表示し、チェックで選択。
- 対象外として明示：Claude の `vm_bundles`、`voicevox_engine`、アプリの Application Support 全般。
- SafeTrash の拒否リスト：`/`・`/System`・`/Library`・`/Applications` 等、ホーム直下の Desktop／Documents／Downloads／Pictures／Movies／Music／Public／Applications 自体、`~/Library` の Mobile Documents／CloudStorage／Keychains／Mail／Messages／Accounts／Photos／Safari／Cookies、`Containers/com.apple.*`、`Group Containers/group.com.apple.*`、`*.photoslibrary`／`*.musiclibrary`。
- すべての破壊的操作は確認ダイアログを経由し、**既定（Return）はキャンセル**。実行ボタンは明示的なクリックが必要。確認で見せた内容（スナップショット）だけを実行する。

### 2.4 大容量ファイル

- 検索範囲（初期値：ホーム全体。`~/Library` と隠しフォルダは除外）から、閾値（初期 500MB）以上のファイルを一覧。
- 並び替え：サイズ／最終使用日（Spotlight の `kMDItemLastUsedDate`、無ければ更新日）／種類。
- 操作：Finder で表示、ゴミ箱へ移動、（動画なら）圧縮キューへ追加。

### 2.5 動画圧縮

- 入力：.mov / .mp4 / .m4v（H.264 等）。出力：同じフォルダに `<元の名前>.mp4`（HEVC, hvc1 タグ, AAC 96kbps）。
- エンコーダ：`ffmpeg` の `hevc_videotoolbox`（ハードウェア）。画質プリセット：標準（-q:v 50、テスト済み）／高画質（-q:v 60）。
- **安全手順**：変換 → ffprobe で長さ（±1秒）と映像・音声ストリームの存在を確認 → 出力が元より小さいことを確認 → 元の作成日・更新日を出力にコピー → 元ファイルをゴミ箱へ。検証失敗時は出力を削除し、元は残す。
- 1本ずつ順番に処理。進捗（%・残り時間）表示、一時停止・中止可。スリープ抑止（変換中のみ）。
- HEVC 変換済みのファイルはスキップ。

### 2.6 アプリケーション（アンインストーラ）

- `/Applications`・`~/Applications` のアプリを一覧（サイズ、最終使用日、入手元：App Store／その他）。
- 選択したアプリの関連ファイルを Bundle ID・アプリ名で検索：`~/Library` 配下の Application Support / Caches / Containers / Group Containers / Preferences / Saved Application State / HTTPStorages / WebKit / Logs / LaunchAgents。
- 一覧で確認してからまとめてゴミ箱へ。Apple 製アプリと実行中のアプリ（削除の直前に再確認）は対象外。
- 関連ファイルは Bundle ID 完全一致のみ既定で選択。前方一致のみ・名前のみ一致は既定で未選択。より具体的な別アプリ（例：Chrome と Chrome Canary）のデータは除外する。削除の許可範囲は検索した各サブフォルダに限る。
- root 所有のファイル・`/Library` 配下（管理者権限が必要）は v1 では「表示のみ＋Finder で開く」。
- 「残骸」表示：アプリ本体が存在しない Bundle ID のフォルダを一覧化（既定で未選択）。LaunchServices に登録済みのID、iOS/iPadOS アプリ（Wrapper）、同じ提供元のアプリが入っているもの、macOS 管理の設定（`org.cups.*`、`com.openssh.*`、`com.apple.*` など）は除外。`Containers`／`Group Containers` は書類を含み得るため**表示のみ**（削除不可）。

### 2.7 ログイン項目・バックグラウンド項目

- `~/Library/LaunchAgents`、`/Library/LaunchAgents`、`/Library/LaunchDaemons` を一覧（ラベル、実行ファイル、署名者）。
- ユーザー領域のものは「無効化（`launchctl bootout`＋plist をゴミ箱へ）」可。システム領域は表示のみ＋「システム設定 › 一般 › ログイン項目」を開くボタン。
- 前回スキャン時のスナップショットと比較し、**新しく増えた項目を強調・通知**（マルウェアの常駐検知を兼ねる）。

### 2.8 セキュリティ

- **常時保護**は macOS 標準（XProtect／Gatekeeper）に任せる。アプリは状態（XProtect のバージョン・更新日、Gatekeeper 有効か、SIP 有効か）を表示する。
- **スキャン**：
  - YARA：`/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Resources/XProtect.yara` を `yarac` でコンパイル（XProtect 更新を検知したら再コンパイル）。
  - ClamAV：`clamscan`。スキャン前に `freshclam` で定義を更新。**標準モードでは `/Applications` を除外**（時間短縮）。設定の「じっくりスキャン」（`deepScan`、既定オフ）で含める。
  - 対象（初期値）：ダウンロード、デスクトップ、書類、`/Applications`（YARA のみ標準対象）、LaunchAgents/Daemons の参照先実行ファイル（ClamAV にも個別に渡す）。
  - YARA は `-p`（マルチスレッド）を使わない（~/Documents で無期限にハングしたため）。
  - アプリバンドル内のファイルの検出は単独削除せず、アプリ単位の削除へ誘導する。
- 検出時：ファイルパス・検出名・エンジン名を表示。操作は「ゴミ箱へ」「Finder で表示」「無視（記録）」。
- 外部送信はしない（VirusTotal 連携は将来検討。実装する場合もハッシュ値のみ）。

### 2.9 定期実行

- アプリ内スケジューラ（ログイン項目として常駐）で**毎日 0:00（設定可）にフルスキャン**：全ファイルを YARA・ClamAV で検査（差分キャッシュは使わない）→ 不要データ集計 → ログイン項目の変化チェック → 結果を通知。予定時刻を過ぎて未実行なら、起動・スリープ復帰の数分後に補完（1 日 1 回、Calendar 基準）。実行中・バッテリー 20% 未満はスキップし 1 時間ごとに再確認。
- 任意設定「スリープ中でも起こしてスキャン」: `pmset repeat wake MTWRFSU <時刻の2分前>`（管理者権限・ユーザー操作時のみ）。フルスキャン中は IOPMAssertion でスリープを抑止する。
- ダッシュボードのスマートケアと手動スキャンは既定でクイック（サイズ・更新時刻・inode が前回と同じファイルは再検査しない）。ClamAV は `--max-filesize/--max-scansize` を libclamav の上限（2 GiB-1）に設定し、超過ファイルは YARA のみで検査して UI に件数を表示する。
- 進捗: 全体 %・残り時間（経過÷進捗の指数移動平均）・ステップ状態をダッシュボード／メニューバーパネル／セキュリティ画面に表示。
- 自己アップデート: ビルド時に埋め込んだソースフォルダで `git fetch` → `origin/main` と比較。更新は `git pull --ff-only` → `install.sh --app-only` を切り離して実行（ログ: Application Support/MacCare/update.log）。
- **自動で削除はしない。**

### 2.10 履歴

- 実行した操作（削除・圧縮・スキャン）を JSON Lines で記録：日時、種類、対象、サイズ、結果。
- 画面で一覧表示（月ごとの削減量合計）。

## 3. 非機能要件

| 項目 | 要件 |
|---|---|
| 安全性 | 許可リスト外は触らない／削除はゴミ箱経由／実行前に一覧確認／例外時は何もしない側に倒す |
| 権限 | フルディスクアクセスは任意（なくても動く。必要な機能だけ案内を出す）。管理者権限は v1 では要求しない |
| 外部送信 | なし（ClamAV 定義のダウンロードを除く） |
| 性能 | UI を止めない（スキャン・変換はバックグラウンド）。大容量ファイル検索はホーム全体で数分以内 |
| 対応環境 | macOS 14 以降（`install.sh` が確認する。SwiftUI の Observation の都合）、Apple Silicon。開発・確認は macOS 27 |
| 依存 | Homebrew の `yara`、`clamav`、`ffmpeg`。未導入時は画面で案内し、該当機能を無効表示 |

## 4. 技術構成

- Swift 6 / SwiftUI（ウィンドウ）＋ AppKit `NSStatusItem`（メニューバー）。
- ビルドは menubar-meters と同じく `build.sh`（`swiftc` で `Sources/*.swift` をコンパイル、Xcode プロジェクトなし）。
- 署名：Apple Development 証明書があればそれ、なければアドホック。ハードンドランタイム有効。サンドボックスなし（App Store 配布しないため）。
- 外部コマンドは `Process` で絶対パス実行（`/opt/homebrew/bin/...`、Intel Mac は `/usr/local/bin/...` を探索）。シェル経由にしない。
- データ保存：`~/Library/Application Support/MacCare/`（設定 JSON、履歴 JSONL、ログイン項目スナップショット、コンパイル済み YARA ルール）。

## 5. 配布

- GitHub リポジトリ（`~/mac-care`）。`install.sh`（brew 依存の導入、ClamAV 設定、ビルド、/Applications へ配置）と `SETUP_PROMPT.md`（Claude Code 向け導入指示書）を用意する。
- 公開範囲：public（https://github.com/withfox-fox1/mac-care）。更新は `git pull --ff-only && ./install.sh --app-only`。
- `uninstall.sh` はアプリとログイン項目を削除し、データ削除は確認する。brew パッケージは削除しない。

## 6. v1 でやらないこと

ウイルスの常時監視（XProtect に任せる）、RAM 解放・メンテナンスタスク、ブラウザのプライバシー掃除、アプリの一括アップデート、
クラウド・メールのお掃除、類似画像検出、管理者権限が必要な削除、VirusTotal 連携。

## 7. 完成条件

1. 2.2〜2.10 の機能が動作し、各機能の実機確認結果（コマンド出力・スクリーンショット）がある。
2. 許可リスト外のパスを削除しないことをテストで確認済み。
3. 動画圧縮の検証失敗時に元ファイルが残ることをテストで確認済み。
4. EICAR テストファイルを ClamAV 経由で検出できる。
5. 別の Mac への導入手順（install.sh / SETUP_PROMPT.md）が揃っている。
6. CleanMyMac を終了した状態で1週間、定期スキャンが動作する。
