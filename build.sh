#!/bin/zsh
# MacCare.app をビルドして署名する。
#   ./build.sh            → build/MacCare.app を作成
#   ./build.sh install    → さらに /Applications へ上書きコピーして起動
set -euo pipefail
cd "$(dirname "$0")"

APP=build/MacCare.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# Sources 配下の全 Swift ファイルをコンパイル
swiftc -O -swift-version 5 $(find Sources -name '*.swift') \
  -framework SwiftUI -framework AppKit -framework IOKit -framework ServiceManagement -framework IOBluetooth -framework CoreWLAN \
  -target "$(uname -m)-apple-macos14.0" \
  -o "$APP/Contents/MacOS/MacCare"

cp Info.plist "$APP/Contents/Info.plist"
# 自己アップデート用: ソースの場所とビルド時のコミットを埋め込む
PB=/usr/libexec/PlistBuddy
"$PB" -c "Add :MCSourceDir string $PWD" "$APP/Contents/Info.plist"
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || true)
[[ -n "$COMMIT" ]] && "$PB" -c "Add :MCBuildCommit string $COMMIT" "$APP/Contents/Info.plist"
# アプリアイコンとメニューバー用アイコンを同梱
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns Resources/MenuBarIcon*.png "$APP/Contents/Resources/"

# Apple Development 証明書があればそれで、なければアドホック署名
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')
codesign --force --options runtime --entitlements MacCare.entitlements --sign "${IDENTITY:--}" "$APP"
echo "Built: $APP (signed with: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "install" ]]; then
  pkill -x MacCare 2>/dev/null || true
  rm -rf /Applications/MacCare.app
  cp -R "$APP" /Applications/
  # Dock / Finder のアイコンキャッシュを更新
  touch /Applications/MacCare.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/MacCare.app >/dev/null 2>&1 || true
  open /Applications/MacCare.app
  echo "Installed: /Applications/MacCare.app"
fi
