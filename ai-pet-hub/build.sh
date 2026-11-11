#!/bin/zsh
# 编译打包 AIPetHub（AIPetHub.app）。
#   ./build.sh            只打包到 build/AIPetHub.app
#   ./build.sh --install  打包后装到 /Applications 并重新打开（正在运行的会被关掉，有回答在进行也一样；装完本机只剩这一份）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="AIPetHub"
APP="build/$APP_NAME.app"

if [[ ! -f AppIcon.icns ]]; then
  echo "生成图标…"
  mkdir -p build/AppIcon.iconset
  swift tools/make_icon.swift web/sprites build/icon_1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon_1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o AppIcon.icns
fi

echo "编译 Sources/**/*.swift…"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
mkdir -p build
touch build/.metadata_never_index
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"
swiftc -O Sources/**/*.swift -o "$APP/Contents/MacOS/$APP_NAME" -framework Cocoa -framework WebKit -lsqlite3

cp web/index.html "$APP/Contents/Resources/web/"
cp -R web/js web/css web/vendor web/rig "$APP/Contents/Resources/web/"

# 逐帧素材：源码里是 PNG 原图（1024 像素的一帧 1–5 MB，一共 125 MB）。装了 cwebp（brew install webp）就转成 WebP 再放进 App：
# 长边超过 SPRITE_MAX 的缩到 SPRITE_MAX（舞台上显示得比这小），质量 90、透明通道无损，整套约 10 MB，载入和解码都快得多。
# 转好的放在 build/sprites-webp，原图没改过就不重转。没装 cwebp、或设了 AIPETHUB_PNG_SPRITES=1，就原样拷 PNG，功能一样。
SPRITE_MAX="${AIPETHUB_SPRITE_MAX:-640}"   # 0 = 不缩小，只换格式
WEB_OUT="$APP/Contents/Resources/web"
if [[ "${AIPETHUB_PNG_SPRITES:-}" != 1 ]] && command -v cwebp >/dev/null; then
  CACHE="build/sprites-webp/$SPRITE_MAX"
  mkdir -p "$CACHE"
  convert_sprite() {   # $1 = 相对 web/sprites 的 PNG 路径
    local src="web/sprites/$1" dst="$CACHE/${1%.png}.webp" w
    [[ -s "$dst" && "$dst" -nt "$src" ]] && return 0
    mkdir -p "${dst:h}"
    w=$(sips -g pixelWidth "$src" | awk '/pixelWidth/ {print $2}')
    if (( SPRITE_MAX > 0 && w > SPRITE_MAX )); then
      cwebp -quiet -q 90 -alpha_q 100 -m 5 -sharp_yuv -resize "$SPRITE_MAX" 0 "$src" -o "$dst.tmp"
    else
      cwebp -quiet -q 90 -alpha_q 100 -m 5 -sharp_yuv "$src" -o "$dst.tmp"
    fi && mv "$dst.tmp" "$dst"
  }
  sprites=(web/sprites/**/*.png(N))
  echo "逐帧素材转 WebP（${#sprites} 张，没改过的不重转）…"
  jobs_max=$(sysctl -n hw.ncpu); failed="$CACHE/.failed"; rm -f "$failed"
  for f in $sprites; do
    while (( ${#jobstates} >= jobs_max )); do sleep 0.02; done
    { convert_sprite "${f#web/sprites/}" || touch "$failed" } &
  done
  wait
  # 原图已经删掉的，缓存里对应的也删掉
  for w in $CACHE/**/*.webp(N); do [[ -e "web/sprites/${${w#$CACHE/}%.webp}.png" ]] || rm -f "$w"; done
  if [[ -e "$failed" || $(print -l $CACHE/**/*.webp(N) | wc -l) -ne ${#sprites} ]]; then
    echo "⚠️ 有素材没转成，这次原样用 PNG。" >&2
    cp -R web/sprites "$WEB_OUT/"
  else
    cp -R "$CACHE" "$WEB_OUT/sprites"
    grep -q "^const SPRITE_EXT = 'png';" "$WEB_OUT/js/stage/sprites.js" || { echo "js/stage/sprites.js 里没找到 SPRITE_EXT 那一行" >&2; exit 1; }
    sed -i '' "s/^const SPRITE_EXT = 'png';/const SPRITE_EXT = 'webp';/" "$WEB_OUT/js/stage/sprites.js"
  fi
else
  echo "没有 cwebp（brew install webp），逐帧素材原样用 PNG。"
  cp -R web/sprites "$WEB_OUT/"
fi
rm -rf "$APP/Contents/Resources/web/rig/src"   # 骨骼动画源码只用来打包 rig/pet-rig.js，不放进 App
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AIPetHub</string>
    <key>CFBundleIdentifier</key>
    <string>com.aipethub.app</string>
    <key>CFBundleName</key>
    <string>AIPetHub</string>
    <key>CFBundleDisplayName</key>
    <string>AIPetHub</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>极其猫 · 克劳蒂娜 · 吉佩缇</string>
</dict>
</plist>
PLIST

xattr -cr "$APP"
# 签名：钥匙串里有名为「AIPetHub」的代码签名证书（或用 AIPETHUB_SIGN_ID 指定）就用它，签名固定，
# 在「隐私与安全性」里给过的权限（完全磁盘访问等）重新编译后仍然有效；没有就临时签名（每次编译都算新 App，系统会重新询问权限）
SIGN_ID="${AIPETHUB_SIGN_ID:-}"
if [[ -z "$SIGN_ID" ]] && security find-identity -p codesigning 2>/dev/null | grep -q '"AIPetHub"'; then SIGN_ID="AIPetHub"; fi
codesign --force --sign "${SIGN_ID:--}" "$APP" >/dev/null
echo "已打包：$PWD/$APP（签名：${SIGN_ID:-临时签名}）"

if [[ "${1:-}" == "--install" ]]; then
  # 安装就是要换成新的：正在运行的 AIPetHub 一律关掉，不等、不问。
  # 测试窗口（--uitest，可能是上次测试卡住留下的）直接结束；正常的那个先让它自己退（3 秒），还在就强制结束。
  pkill -9 -f "$APP_NAME.app/Contents/MacOS/$APP_NAME --uitest" 2>/dev/null || true
  if pgrep -x "$APP_NAME" >/dev/null; then
    pkill -x "$APP_NAME" || true
    for _ in {1..15}; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.2; done
    if pgrep -x "$APP_NAME" >/dev/null; then
      echo "$APP_NAME 还有回答在进行，强制关掉。"
      pkill -9 -x "$APP_NAME" || true
      for _ in {1..25}; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.2; done
    fi
  fi
  rm -rf "/Applications/$APP_NAME.app"
  mv "$APP" "/Applications/$APP_NAME.app"
  "$LSREG" -u "$PWD/$APP" 2>/dev/null || true
  open "/Applications/$APP_NAME.app"
  echo "已安装并打开：/Applications/$APP_NAME.app"
else
  "$LSREG" -u "$PWD/$APP" 2>/dev/null || true
fi
