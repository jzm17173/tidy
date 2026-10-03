#!/bin/bash
# 把 SPM release 产物组装成 tidy.app（M5）。
# Info.plist 对 SPM 可执行文件不生效，需手动组装 bundle（详设 §4）。
set -euo pipefail

cd "$(dirname "$0")/.."

# CLT-only 环境：注入 fake Developer dir 与 swift.org toolchain（见 scripts/test-env/bootstrap.sh）
DEVDIR="${TIDY_DEVDIR:-/private/tmp/Xcode.app/Contents/Developer}"
TOOLCHAIN_BIN=/tmp/swiftpkg/swift-5.8.1-RELEASE-osx-package.pkg/Payload/usr/bin
if [ ! -d "$DEVDIR/Platforms" ]; then
    bash scripts/test-env/bootstrap.sh
fi
export DEVELOPER_DIR="$DEVDIR"
export PATH="$TOOLCHAIN_BIN:$PATH"

swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"
APP="tidy.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/tidy" "$APP/Contents/MacOS/tidy"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 应用图标（Resources/AppIcon.icns，由 1024px 源图经 iconset/iconutil 生成）
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "Built $APP"
find "$APP" -type f | sort
