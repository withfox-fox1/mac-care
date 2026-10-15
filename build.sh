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
  -framework SwiftUI -framework AppKit -framework IOKit -framework ServiceManagement \
  -target "$(uname -m)-apple-macos14.0" \
  -o "$APP/Contents/MacOS/MacCare"

cp Info.plist "$APP/Contents/Info.plist"

# Apple Development 証明書があればそれで、なければアドホック署名
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')
codesign --force --options runtime --entitlements MacCare.entitlements --sign "${IDENTITY:--}" "$APP"
echo "Built: $APP (signed with: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "install" ]]; then
  pkill -x MacCare 2>/dev/null || true
  rm -rf /Applications/MacCare.app
  cp -R "$APP" /Applications/
  open /Applications/MacCare.app
  echo "Installed: /Applications/MacCare.app"
fi
