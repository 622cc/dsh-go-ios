#!/usr/bin/env bash
# 构建适用于 TrollStore (巨魔) 的 iOS IPA 安装包
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/app"
OUT_DIR="$ROOT_DIR/build/trollstore"
IPA_NAME="DSH-Go-TrollStore.ipa"

echo "==> 准备构建环境..."
mkdir -p "$OUT_DIR"

cd "$APP_DIR"
echo "==> 获取 Flutter 依赖..."
flutter pub get

echo "==> 安装 CocoaPods 依赖..."
cd ios
pod install --repo-update
cd ..

echo "==> 开始编译 iOS Release (无签名)..."
flutter build ios --release --no-codesign

BUILD_APP_PATH="$APP_DIR/build/ios/iphoneos/Runner.app"
if [ ! -d "$BUILD_APP_PATH" ]; then
  # 兼容从 DerivedData 寻找
  BUILD_APP_PATH=$(find "$APP_DIR/build/ios" -name "Runner.app" -type d | head -n 1)
fi

if [ -z "$BUILD_APP_PATH" ] || [ ! -d "$BUILD_APP_PATH" ]; then
  echo "[-] 错误: 未找到编译生成的 Runner.app"
  exit 1
fi

echo "==> 找到构建产物: $BUILD_APP_PATH"
PAYLOAD_DIR="$OUT_DIR/Payload"
rm -rf "$PAYLOAD_DIR"
mkdir -p "$PAYLOAD_DIR"

cp -R "$BUILD_APP_PATH" "$PAYLOAD_DIR/Runner.app"

ENTITLEMENTS="$APP_DIR/ios/Entitlements.plist"
if command -v ldid >/dev/null 2>&1; then
  echo "==> 使用 ldid 注入 TrollStore 巨魔权限..."
  ldid -S"$ENTITLEMENTS" "$PAYLOAD_DIR/Runner.app"
  echo "==> TrollStore 权限注入成功！"
elif command -v codesign >/dev/null 2>&1; then
  echo "==> 使用 codesign 注入 Entitlements..."
  codesign --force --sign - --entitlements "$ENTITLEMENTS" --timestamp=none "$PAYLOAD_DIR/Runner.app"
fi

echo "==> 打包 IPA..."
cd "$OUT_DIR"
rm -f "$IPA_NAME"
zip -qry "$IPA_NAME" Payload

echo "==> [成功] IPA 已生成: $OUT_DIR/$IPA_NAME"
ls -lh "$OUT_DIR/$IPA_NAME"
