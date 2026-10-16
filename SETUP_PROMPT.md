# セットアップ指示書（Claude Code向け）

このファイルは、別の Mac に MacCare（メンテナンスアプリ）を導入するための自己完結した指示書です。
ユーザーからこのファイル（またはリポジトリの URL）を渡されて「これで実装して」と言われたら、以下を上から順に実施してください。

MacCare は、不要データの掃除・大容量ファイル整理・動画圧縮・セキュリティスキャン（YARA／ClamAV）・アプリのアンインストール・ログイン項目の監視を行うメニューバー常駐アプリです。

## 前提

- **必要なもの**: macOS 14 以降、Xcode Command Line Tools（`swiftc`）、Homebrew。Xcode 本体と Apple ID は不要。
- 開発・動作確認は macOS 27（Apple Silicon）。それ以外は未検証なので、違いがあればユーザーに伝える。
- ビルドは `build.sh`（`swiftc`）。署名は Apple Development 証明書があればそれ、なければアドホック。どちらでも動く。
- **セットアップ中にアプリの削除系ボタン（ゴミ箱へ・ゴミ箱を空にする・アンインストール・無効化）を操作しないこと。** 確認はスキャン（読み取り専用）までに留める。

## 手順

### 1. 環境の確認

```bash
sw_vers -productVersion
uname -m
xcode-select -p && xcrun --find swiftc
ls /opt/homebrew/bin/brew /usr/local/bin/brew 2>/dev/null
```

- macOS が 14 未満なら中断してユーザーに伝える。
- `xcode-select -p` が失敗する場合: `xcode-select --install` を実行し、ダイアログでのインストールをユーザーに依頼して完了を待つ。
- Homebrew が無い場合: **自動インストールはしない**。ユーザーに公式コマンドを案内し、インストール完了後に続行する。
  `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`

### 2. ソースの取得

リポジトリは公開（public）なのでログイン不要。

```bash
cd ~
if [ -d mac-care/.git ]; then git -C mac-care pull --ff-only; else git clone https://github.com/withfox-fox1/mac-care.git; fi
cd ~/mac-care
```

### 3. インストール

```bash
./install.sh
```

- `yara`・`clamav`・`ffmpeg` を Homebrew で導入し（導入済みはスキップ）、`freshclam.conf` を作成して定義を取得（初回は数分）、アプリをビルドして `/Applications/MacCare.app` に配置・起動する。
- アプリだけ入れ直す場合は `./install.sh --app-only`。
- 初回起動でログイン項目に自動登録される（設定画面で切替可）。

### 4. 動作確認

```bash
./test.sh | tail -3                    # 全件 PASS（最終行が「N/N passed」）
pgrep -x MacCare                       # PID が表示される
ls /Applications/MacCare.app/Contents/Resources   # AppIcon.icns などがある
```

- メニューバーに MacCare のアイコンが出ていること、「ウィンドウを開く」でウィンドウが開くことをユーザーに確認してもらう。
- 初回のウィンドウ表示時に案内（オンボーディング）が出る。内容を読んでもらい、閉じてもらう。
- 設定画面の上部に「〜に必要なツールが見つかりません」という警告が出ていないこと。「バージョン詳細」を開くと「使用している外部ツール」が「N/N 利用可能」になっていること（yara / yarac / clamscan / freshclam / ffmpeg / ffprobe / brew）。

### 5. ユーザーに確認すること

- **フルディスクアクセス（任意）**: ゴミ箱の中身の確認と「ゴミ箱を空にする」に必要。許可しなくても他は動く。許可する場合はシステム設定 › プライバシーとセキュリティ › フルディスクアクセス で MacCare を追加。
- 初回スキャン時に macOS が表示する「デスクトップ／書類／ダウンロード」へのアクセス確認は、ユーザー自身に許可してもらう（回避しない）。
- 通知の許可（定期スキャンの結果通知に使用）。

## 注意

- 標準のセキュリティスキャンは ClamAV で `/Applications` を除外している（時間短縮）。ユーザーが望めば設定の「じっくりスキャン」を有効にできる。
- 更新: `cd ~/mac-care && git pull --ff-only && ./install.sh --app-only`
- 削除: `./uninstall.sh`（Homebrew のパッケージは残る）。
