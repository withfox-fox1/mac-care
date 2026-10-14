#!/bin/zsh
# Core 層のテストをビルドして実行する（XCTest 不使用）。
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 Sources/Core/*.swift tests/*.swift \
  -target "$(uname -m)-apple-macos14.0" -o build/maccare-tests
build/maccare-tests
