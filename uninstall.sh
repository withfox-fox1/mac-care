#!/bin/zsh
# MacCare を削除する。Homebrew で入れたパッケージ（yara / clamav / ffmpeg）は削除しない。
#   ./uninstall.sh
set -euo pipefail

APP=/Applications/MacCare.app
DATA="$HOME/Library/Application Support/MacCare"

# ログイン項目の登録を解除（アプリ自身に解除させる）
if [[ -x "$APP/Contents/MacOS/MacCare" ]]; then
  pkill -x MacCare 2>/dev/null || true
  sleep 1
  "$APP/Contents/MacOS/MacCare" --unregister-login-item || true
fi
pkill -x MacCare 2>/dev/null || true

if [[ -d "$APP" ]]; then
  rm -rf "$APP"
  echo "削除: $APP"
fi

if [[ -d "$DATA" ]]; then
  read -r "ans?設定・履歴・スキャン結果 ($DATA) も削除しますか？ [y/N] "
  if [[ "$ans" == [yY]* ]]; then
    rm -rf "$DATA"
    echo "削除: $DATA"
  else
    echo "残しました: $DATA"
  fi
fi

echo ""
echo "完了。Homebrew のパッケージは残しています。不要なら次で削除できます:"
echo "  brew uninstall yara clamav ffmpeg"
