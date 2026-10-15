#!/bin/zsh
# MacCare を導入する（依存ツールの導入 → ClamAV 設定 → ビルド → /Applications へ配置）。
#
#   ./install.sh             → 依存ツールの確認・導入＋アプリのビルドとインストール
#   ./install.sh --app-only  → アプリのビルドとインストールのみ（依存ツールには触れない）
#
# 何度実行してもよい（導入済みの項目はスキップする。コード更新後の再インストールにも使う）。
set -euo pipefail
cd "$(dirname "$0")"

APP_ONLY=0
[[ "${1:-}" == "--app-only" ]] && APP_ONLY=1

# ---- 1. 前提チェック ----
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if (( MAJOR < 14 )); then
  echo "エラー: macOS 14 以降が必要です（現在 $(sw_vers -productVersion)）" >&2
  exit 1
fi
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "エラー: Xcode Command Line Tools がありません。" >&2
  echo "  xcode-select --install を実行し、表示されるダイアログでインストールしてから再実行してください。" >&2
  exit 1
fi

if (( ! APP_ONLY )); then
  # ---- 2. Homebrew と依存ツール ----
  BREW=""
  for c in /opt/homebrew/bin/brew /usr/local/bin/brew; do [[ -x "$c" ]] && { BREW="$c"; break; }; done
  if [[ -z "$BREW" ]]; then
    echo "エラー: Homebrew がありません。自動ではインストールしません。" >&2
    echo "  公式の手順でインストールしてから再実行してください:" >&2
    echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' >&2
    exit 1
  fi
  PREFIX=$("$BREW" --prefix)

  for pkg in yara clamav ffmpeg; do
    if "$BREW" list --formula "$pkg" >/dev/null 2>&1; then
      echo "導入済み: $pkg（スキップ）"
    else
      echo "導入: $pkg"
      "$BREW" install "$pkg"
    fi
  done

  # ---- 3. ClamAV の設定と定義の取得 ----
  CONF_DIR="$PREFIX/etc/clamav"
  if [[ ! -f "$CONF_DIR/freshclam.conf" ]]; then
    if [[ -f "$CONF_DIR/freshclam.conf.sample" ]]; then
      sed 's/^Example/#Example/' "$CONF_DIR/freshclam.conf.sample" > "$CONF_DIR/freshclam.conf"
      echo "作成: $CONF_DIR/freshclam.conf"
    else
      echo "警告: $CONF_DIR/freshclam.conf.sample がありません。ClamAV の設定を手動で作成してください。" >&2
    fi
  else
    echo "設定あり: $CONF_DIR/freshclam.conf（スキップ）"
  fi
  mkdir -p "$PREFIX/var/lib/clamav"
  if [[ -f "$CONF_DIR/freshclam.conf" ]]; then
    echo "ウイルス定義を更新します（初回は数分かかります）…"
    "$PREFIX/bin/freshclam" || echo "警告: 定義の更新に失敗しました。あとで freshclam を実行してください。" >&2
  fi
fi

# ---- 4. ビルド＆インストール ----
./build.sh install

echo ""
echo "完了。メニューバーの MacCare アイコンからウィンドウを開けます。"
echo "アンインストール: ./uninstall.sh"
