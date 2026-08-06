#!/bin/bash
#
# 构建 Jarvis.app 并安装到 ~/Applications，然后重启 LaunchAgent。
#
#   ./build.sh              构建 + 安装 + 重启
#   ./build.sh --no-restart 只构建安装，不碰 launchd
#
# 从 JarvisWallpaper.app / com.jarvis.wallpaper 迁移过来的旧安装会被自动清理。
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

APP_NAME="Jarvis"
BUNDLE_ID="com.jarvis.desktop"
LABEL="com.jarvis.desktop"
DEST="${HOME}/Applications"
APP="${DEST}/${APP_NAME}.app"
AGENT="${HOME}/Library/LaunchAgents/${LABEL}.plist"

OLD_APP="${DEST}/JarvisWallpaper.app"
OLD_LABEL="com.jarvis.wallpaper"
OLD_AGENT="${HOME}/Library/LaunchAgents/${OLD_LABEL}.plist"

RESTART=1
[[ "${1:-}" == "--no-restart" ]] && RESTART=0

# ── 停掉正在跑的实例（KeepAlive 会立刻把它拉回来，必须先 bootout）────────
if [[ $RESTART -eq 1 ]]; then
  for label in "$OLD_LABEL" "$LABEL"; do
    launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
  done

  # bootout 是异步的：它返回时进程可能还活着。不等就 bootstrap，launchd 会认新 pid，
  # 旧进程从此没人管、永远不退——两个实例各拉一个 Brain 抢同一个 socket，
  # 面板就一直「未连接」。等它真的死透，超时了再强杀。
  for _ in $(seq 1 30); do
    pgrep -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}\$" >/dev/null || break
    sleep 0.2
  done
  if pgrep -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}\$" >/dev/null; then
    echo "▸ 旧实例没退干净，强制结束"
    pkill -9 -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}\$" || true
    sleep 0.5
  fi
fi

echo "▸ 清理旧构建"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ 写入 Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>       <string>J.A.R.V.I.S.</string>
  <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key>        <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleIconFile</key>          <string>Jarvis.icns</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key>           <string>3</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <key>LSUIElement</key>               <true/>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>JARVIS 需要麦克风来听你说话。</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>JARVIS 需要语音识别把你说的话转成文字（本机离线完成）。</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>JARVIS 需要发送 Apple 事件来发系统通知和控制其他应用。</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>JARVIS 需要读取日历，以便回答接下来的安排并提供及时提醒。</string>
  <key>NSCalendarsUsageDescription</key>
  <string>JARVIS 需要读取日历，以便回答接下来的安排并提供及时提醒。</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>JARVIS 需要访问桌面来帮你查找和整理文件。</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>JARVIS 需要访问文稿来帮你查找和整理文件。</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>JARVIS 需要访问下载文件夹来帮你查找和整理文件。</string>
</dict>
</plist>
PLIST

echo "▸ 编译 Objective-C"
# 本机 CommandLineTools 的 Swift SDK 与编译器版本对不上，任何 import 系统框架的
# Swift 都编不过（详见 README）。ObjC 不走 .swiftinterface，不受影响。
SOURCES=$(find "$HERE" -name '*.m' | sort)
clang -O2 -fobjc-arc -mmacosx-version-min=13.0 \
  -Wall -Wno-unused-parameter \
  -I"$HERE" -I"$ROOT/vendor/sherpa-onnx/include" \
  -framework Cocoa -framework WebKit -framework IOKit \
  -framework Carbon -framework UserNotifications -framework EventKit \
  -framework AVFoundation -framework Speech -framework PDFKit \
  -framework OSAKit -framework QuartzCore -framework CoreAudio \
  -o "$APP/Contents/MacOS/${APP_NAME}" \
  $SOURCES \
  -lsqlite3 \
  -L"$ROOT/vendor/sherpa-onnx/lib" -lsherpa-onnx-c-api \
  -Wl,-rpath,@executable_path/../Frameworks

echo "▸ 打包网页资源"
mkdir -p "$APP/Contents/Resources/web"
cp "$ROOT/ui/wallpaper.html" "$ROOT/ui/conversation.html" "$ROOT/ui/three.min.js" \
   "$APP/Contents/Resources/web/"

echo "▸ 打包应用图标"
cp "$ROOT/assets/Jarvis.icns" "$APP/Contents/Resources/Jarvis.icns"

echo "▸ 打包 Brain"
mkdir -p "$APP/Contents/Resources/brain"
rsync -a --delete --exclude '__pycache__' --exclude '*.pyc' \
  "$ROOT/brain/jarvis_brain" "$APP/Contents/Resources/brain/"

echo "▸ 打包 sherpa-onnx 动态库"
# 静态库不含 ONNX Runtime，只能走 shared。装进 Frameworks/，
# 可执行文件用 @executable_path/../Frameworks 这条 rpath 找它们。
mkdir -p "$APP/Contents/Frameworks"
cp -a "$ROOT/vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib" \
      "$ROOT/vendor/sherpa-onnx/lib/libonnxruntime.1.27.0.dylib" \
      "$APP/Contents/Frameworks/"

echo "▸ 打包唤醒词模型"
MODEL_DEST="$APP/Contents/Resources/models"
KWS_DEST="$MODEL_DEST/kws-zh-en"
mkdir -p "$KWS_DEST"
# 模型发布包含多套 chunk/精度组合；运行时只引用下面这套 chunk-16 INT8。
# 只装实际会打开的文件，避免把约 28MB 从未加载的 ONNX 塞进 App。
cp "$ROOT/models/kws-jarvis.txt" "$MODEL_DEST/"
for file in \
  encoder-epoch-13-avg-2-chunk-16-left-64.int8.onnx \
  decoder-epoch-13-avg-2-chunk-16-left-64.onnx \
  joiner-epoch-13-avg-2-chunk-16-left-64.int8.onnx \
  tokens.txt; do
  cp "$ROOT/models/kws-zh-en/$file" "$KWS_DEST/"
done

# ── 签名 ──────────────────────────────────────────────────────────────
# 优先用固定身份。ad-hoc 签名的 designated requirement 是 cdhash，二进制一改就变，
# TCC 里的辅助功能/自动化授权随之作废——而系统设置里开关看着还是开的。
# 症状是"权限明明给了，播放器还是控制不了"，每次 build 复发一次。
# 造身份：./native/make-signing-identity.sh
IDENTITY="Jarvis Local Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  # 花括号不能省：紧跟的全角括号是多字节字符，bash 会把它算进变量名，set -u 下直接报错
  echo "▸ 签名（固定身份：${IDENTITY}）"
  SIGN_AS="$IDENTITY"
else
  echo "▸ 签名（ad-hoc）"
  echo "  ⚠️  没有固定签名身份，重新构建后辅助功能权限会失效。"
  echo "     跑一次 ./native/make-signing-identity.sh 可以一劳永逸。"
  SIGN_AS="-"
fi

# 嵌入的动态库要先各自签，最后再签整个 bundle，否则 Gatekeeper 会拒
codesign --force --sign "$SIGN_AS" "$APP/Contents/Frameworks/libonnxruntime.1.27.0.dylib"
codesign --force --sign "$SIGN_AS" "$APP/Contents/Frameworks/libsherpa-onnx-c-api.dylib"
codesign --force --deep --sign "$SIGN_AS" "$APP"

# ── LaunchAgent ───────────────────────────────────────────────────────
echo "▸ 安装 LaunchAgent（${LABEL}）"
cat > "$AGENT" <<AGENTPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>             <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array><string>${APP}/Contents/MacOS/${APP_NAME}</string></array>
  <key>RunAtLoad</key>         <true/>
  <key>ProcessType</key>       <string>Interactive</string>
  <key>StandardOutPath</key>   <string>/tmp/jarvis.log</string>
  <key>StandardErrorPath</key> <string>/tmp/jarvis.log</string>
</dict>
</plist>
AGENTPLIST
cp "$AGENT" "$ROOT/launchagents/${LABEL}.plist"

if [[ -f "$OLD_AGENT" ]]; then
  echo "▸ 移除旧的 ${OLD_LABEL}"
  rm -f "$OLD_AGENT" "$ROOT/launchagents/${OLD_LABEL}.plist"
fi
if [[ -d "$OLD_APP" ]]; then
  echo "▸ 移除旧的 JarvisWallpaper.app"
  rm -rf "$OLD_APP"
fi

if [[ $RESTART -eq 1 ]]; then
  echo "▸ 启动"
  launchctl bootstrap "gui/$(id -u)" "$AGENT"
fi

echo "✓ 完成：$APP"
echo "  菜单栏图标 → 对话…，或按 ⌥Space"
