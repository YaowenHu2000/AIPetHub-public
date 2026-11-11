#!/bin/zsh
# 打一个给别人用的安装包：build/AIPetHub-<版本>.dmg，打开后把 AIPetHub 拖进「应用程序」。
#   tools/make-dmg.sh [版本号]      版本号不给就用 git 的短提交号
# 用临时签名（ad-hoc）：没有苹果公证，别人第一次打开要在「隐私与安全性」里放行一次（README 里写了步骤）。
# 你自己钥匙串里的「AIPetHub」证书只在本机有效，分发出去反而让 Gatekeeper 更不认，所以这里不用它。
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:-$(git rev-parse --short HEAD 2>/dev/null || date +%Y%m%d)}
AIPETHUB_SIGN_ID=- ./build.sh >/dev/null
APP=build/AIPetHub.app
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" >/dev/null
STAGE=$(mktemp -d -t aipethub-dmg)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
OUT="build/AIPetHub-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname "AIPetHub" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$OUT" >/dev/null
echo "安装包：$PWD/$OUT（$(du -h "$OUT" | cut -f1)）"
