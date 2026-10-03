#!/bin/bash
# CLT-only 环境引导：本机只有 Command Line Tools（无 Xcode），SPM 需要平台路径与 XCTest。
# 本脚本构建一个最小 "Xcode 目录结构"（fake Developer dir）：
#   $TIDY_DEVDIR/Contents/Developer/{Platforms, Toolchains, usr/bin}
# 其中 XCTest.framework 由 swift-corelibs-xctest 源码编译（打了 NSObject 基类补丁），
# xctest 由 scripts/test-env/xctest-runner.swift 编译（ObjC 运行时枚举 @objcMembers 测试类）。
# 幂等：已存在则跳过。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEVDIR="${TIDY_DEVDIR:-/private/tmp/Xcode.app/Contents/Developer}"
SWIFT_VERSION="5.8.1"
TOOLCHAIN_CACHE=/tmp/swiftpkg/swift-${SWIFT_VERSION}-RELEASE-osx-package.pkg/Payload
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk

log() { echo "[bootstrap] $*"; }

# 1. swift.org toolchain（CLT 自带的缺 PackageDescription.swiftmodule，无法编译 Package.swift）
if [ ! -x "$TOOLCHAIN_CACHE/usr/bin/swiftc" ]; then
    log "下载并展开 swift.org toolchain $SWIFT_VERSION ..."
    PKG=/tmp/swift-${SWIFT_VERSION}.pkg
    [ -f "$PKG" ] || curl -fSL -o "$PKG" \
        "https://download.swift.org/swift-${SWIFT_VERSION}-release/xcode/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE-osx.pkg"
    rm -rf /tmp/swiftpkg
    (cd /tmp && pkgutil --expand-full "$PKG" /tmp/swiftpkg)
fi

# 2. fake Developer 目录骨架
if [ ! -d "$DEVDIR/Platforms/MacOSX.platform" ]; then
    log "创建 fake Developer 目录 $DEVDIR ..."
    rm -rf "$(dirname "$(dirname "$DEVDIR")")"
    mkdir -p "$DEVDIR/Toolchains" "$DEVDIR/Platforms/MacOSX.platform/Developer" "$DEVDIR/usr/bin"
    ln -sfn "$TOOLCHAIN_CACHE" "$DEVDIR/Toolchains/XcodeDefault.xctoolchain"
    ln -sfn /Library/Developer/CommandLineTools/SDKs "$DEVDIR/Platforms/MacOSX.platform/Developer/SDKs"
    ln -sfn /Library/Developer/CommandLineTools/Library "$DEVDIR/Library"
    for tool in /Library/Developer/CommandLineTools/usr/bin/*; do
        ln -sfn "$tool" "$DEVDIR/usr/bin/$(basename "$tool")"
    done
    for t in swift swiftc swift-build swift-test swift-package; do
        ln -sfn "$TOOLCHAIN_CACHE/usr/bin/$t" "$DEVDIR/usr/bin/$t"
    done
    cat > "$(dirname "$DEVDIR")/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>com.apple.dt.Xcode</string>
	<key>CFBundleName</key><string>Xcode</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>14.3.1</string>
	<key>CFBundleVersion</key><string>14E300c</string>
</dict>
</plist>
EOF
    cat > "$(dirname "$DEVDIR")/version.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>CFBundleShortVersionString</key><string>14.3.1</string>
	<key>CFBundleVersion</key><string>14E300c</string>
</dict>
</plist>
EOF
fi

# 3. xcodebuild shim（xcrun 的 SDK/平台路径查询依赖它）
if [ ! -f "$DEVDIR/usr/bin/xcodebuild" ] || ! grep -q "Minimal xcodebuild shim" "$DEVDIR/usr/bin/xcodebuild"; then
    log "写入 xcodebuild shim ..."
    cat > "$DEVDIR/usr/bin/xcodebuild" <<EOF
#!/bin/bash
# Minimal xcodebuild shim for CLT-only machines: implements the queries xcrun/xcselect use.
PLATFORM_PATH="$DEVDIR/Platforms/MacOSX.platform"
SDK_PATH="$DEVDIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

args=("\$@")
has() { local f="\$1"; shift; for a in "\$@"; do [ "\$a" = "\$f" ] && return 0; done; return 1; }

if has "-find" "\${args[@]}"; then
  tool=""
  for ((i=0; i<\${#args[@]}; i++)); do
    if [ "\${args[\$i]}" = "-find" ]; then tool="\${args[\$((i+1))]:-}"; fi
  done
  for base in "$DEVDIR/usr/bin" \\
              "$DEVDIR/Toolchains/XcodeDefault.xctoolchain/usr/bin" \\
              "/Library/Developer/CommandLineTools/usr/bin" \\
              "/usr/bin"; do
    if [ -x "\$base/\$tool" ]; then echo "\$(cd "\$base" && pwd)/\$tool"; exit 0; fi
  done
  exit 1
fi

if has "-version" "\${args[@]}"; then
  if has "-sdk" "\${args[@]}"; then
    item=""
    for ((i=0; i<\${#args[@]}; i++)); do
      case "\${args[\$i]}" in
        -sdk) i=\$((i+1));;
        -version) ;;
        *) item="\${args[\$i]}";;
      esac
    done
    print_all() {
      echo "MacOSX.sdk"
      echo "	CanonicalName: macosx"
      echo "	PlatformPath: \$PLATFORM_PATH"
      echo "	Path: \$SDK_PATH"
      echo "	SDKPath: \$SDK_PATH"
      echo "	ProductName: Mac OS X"
      echo "	ProductVersion: 13.3"
      echo "	SDKVersion: 13.3"
    }
    if [ -z "\$item" ]; then print_all; exit 0; fi
    case "\$item" in
      PlatformPath) echo "\$PLATFORM_PATH";;
      Path|SDKPath) echo "\$SDK_PATH";;
      CanonicalName) echo "macosx";;
      ProductName) echo "Mac OS X";;
      ProductVersion|SDKVersion) echo "13.3";;
      *) echo "";;
    esac
    exit 0
  fi
  echo "Xcode 14.3.1"
  echo "Build version 14E300c"
  exit 0
fi

if has "-showsdks" "\${args[@]}"; then
  echo "macOS SDKs:"
  echo "	macOS 13.3                    	-sdk macosx"
  exit 0
fi
exit 0
EOF
    chmod +x "$DEVDIR/usr/bin/xcodebuild"
fi

FRAMEWORKS="$DEVDIR/Platforms/MacOSX.platform/Developer/Library/Frameworks"

# 4. XCTest.framework（corelibs-xctest 源码编译 + NSObject 基类补丁）
if [ ! -f "$FRAMEWORKS/XCTest.framework/Versions/A/XCTest" ]; then
    log "编译 XCTest.framework（corelibs-xctest）..."
    SRC=/tmp/corelibs-xctest
    if [ ! -d "$SRC/Sources/XCTest" ]; then
        rm -rf "$SRC"
        git clone --depth 1 --branch swift-${SWIFT_VERSION}-RELEASE \
            https://github.com/apple/swift-corelibs-xctest.git "$SRC"
    fi
    # Darwin 上 ObjC 发现需要 NSObject 基类
    python3 - <<'EOF'
p = "/tmp/corelibs-xctest/Sources/XCTest/Public/XCAbstractTest.swift"
s = open(p).read()
s = s.replace("open class XCTest {", "open class XCTest: NSObject {")
s = s.replace("    public init() {}", "    public override init() {}")
open(p, "w").write(s)
EOF
    F="$FRAMEWORKS/XCTest.framework"
    rm -rf "$F"
    mkdir -p "$F/Versions/A/Modules/XCTest.swiftmodule" "$F/Versions/A/Resources"
    "$TOOLCHAIN_CACHE/usr/bin/swiftc" -emit-library -emit-module \
        -module-name XCTest \
        -target arm64-apple-macosx11.0 \
        -sdk "$SDK" \
        -D USE_FOUNDATION_FRAMEWORK \
        -Xlinker -install_name -Xlinker @rpath/XCTest.framework/XCTest \
        -emit-module-path "$F/Versions/A/Modules/XCTest.swiftmodule/arm64-apple-macos.swiftmodule" \
        -o "$F/Versions/A/XCTest" \
        -O \
        $(find "$SRC/Sources/XCTest" -name "*.swift")
    ln -sfn A "$F/Versions/Current"
    ln -sfn Versions/Current/XCTest "$F/XCTest"
    ln -sfn Versions/Current/Modules "$F/Modules"
    ln -sfn Versions/Current/Resources "$F/Resources"
    cat > "$F/Versions/A/Resources/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>com.apple.XCTest</string>
	<key>CFBundleName</key><string>XCTest</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleExecutable</key><string>XCTest</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
</dict>
</plist>
EOF
fi

# 5. xctest runner（ObjC 运行时枚举 @objcMembers 测试类 → corelibs XCTMain）
if [ ! -x "$DEVDIR/usr/bin/xctest-bin" ] || [ "$REPO_ROOT/scripts/test-env/xctest-runner.swift" -nt "$DEVDIR/usr/bin/xctest-bin" ]; then
    log "编译 xctest runner ..."
    "$TOOLCHAIN_CACHE/usr/bin/swiftc" "$REPO_ROOT/scripts/test-env/xctest-runner.swift" \
        -o "$DEVDIR/usr/bin/xctest-bin" \
        -sdk "$SDK" \
        -target arm64-apple-macosx11.0 \
        -F "$FRAMEWORKS" -framework XCTest \
        -Xlinker -rpath -Xlinker "$FRAMEWORKS"
    cat > "$DEVDIR/usr/bin/xctest" <<EOF
#!/bin/bash
export DYLD_FRAMEWORK_PATH="$FRAMEWORKS"
exec "$DEVDIR/usr/bin/xctest-bin" "\$@"
EOF
    chmod +x "$DEVDIR/usr/bin/xctest"
fi

log "完成。使用时 export DEVELOPER_DIR=$DEVDIR 并把 toolchain bin 放 PATH 前："
log "  export DEVELOPER_DIR=$DEVDIR"
log "  export PATH=$TOOLCHAIN_CACHE/usr/bin:\$PATH"
