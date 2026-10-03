#!/bin/bash
# 产出 tidy.dmg（M6 分发物；暂未签名/公证，仅本机与信任来源分发可用）。
# 流程：bundle.sh 组装 tidy.app → 读写 dmg 内拷入 app + /Applications 软链 + 背景图，
# AppleScript 摆安装窗口（背景箭头、图标位置、隐藏工具栏）→ 转成 UDZO 压缩只读 dmg。
set -euo pipefail

cd "$(dirname "$0")/.."

bash scripts/bundle.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
ARCH=$(uname -m)
VOLNAME="tidy ${VERSION}-${ARCH}"
DMG="tidy.dmg"
STAGE_DIR="$(mktemp -d)"
RW_DMG="$STAGE_DIR/tidy-rw.dmg"
MOUNT="/Volumes/${VOLNAME}"

cleanup() {
    hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
    rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

hdiutil detach "$MOUNT" -quiet 2>/dev/null || true

# 读写 dmg（足够装下 app 即可，转 UDZO 时会压缩）
hdiutil create -size 20m -fs HFS+ -volname "$VOLNAME" -type UDIF -ov "$RW_DMG" >/dev/null
hdiutil attach "$RW_DMG" -nobrowse -quiet

cp -R tidy.app "$MOUNT/tidy.app"
ln -s /Applications "$MOUNT/Applications"
mkdir -p "$MOUNT/.background"
cp Resources/dmg-background.tiff "$MOUNT/.background/background.tiff"

# 卷宗图标（与 app 图标一致；SetFile 不存在则跳过，不影响功能）
if command -v SetFile >/dev/null 2>&1; then
    cp Resources/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
    SetFile -a C "$MOUNT"
fi

# 摆安装窗口：背景图（虚线箭头）、图标 128、左右对位、隐藏工具栏/状态栏
osascript <<EOF
tell application "Finder"
    tell disk "${VOLNAME}"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {300, 100, 840, 480}
        delay 1
        tell icon view options of container window
            set icon size to 64
            set arrangement to not arranged
            set background picture to ((POSIX file "/Volumes/${VOLNAME}/.background/background.tiff") as alias)
        end tell
        delay 1
        set position of item "tidy.app" of container window to {130, 188}
        set position of item "Applications" of container window to {410, 188}
        delay 2
    end tell
end tell
EOF

sync
hdiutil detach "$MOUNT" -quiet

rm -f "$DMG"
hdiutil convert "$RW_DMG" -format UDZO -ov -o "$DMG" >/dev/null

echo "Built $DMG"
ls -lh "$DMG"
