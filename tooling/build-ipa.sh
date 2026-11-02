#!/usr/bin/env bash
# 构建适用于 TrollStore (巨魔) 的 iOS IPA 安装包
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/app"
OUT_DIR="$ROOT_DIR/build/trollstore"
TEMPLATES_DIR="$ROOT_DIR/tooling/ios_templates"
IPA_NAME="DSH-Go-TrollStore.ipa"

echo "==> 准备构建环境..."
mkdir -p "$OUT_DIR"

cd "$APP_DIR"
echo "==> 使用 Flutter 官方标准生成 iOS 工程底座..."
flutter create --platforms=ios --org io.github.ccch1mneyyy .

echo "==> 注入 DSH 适配层与 TrollStore 巨魔专属配置..."
cp "$TEMPLATES_DIR/AppDelegate.swift" "$APP_DIR/ios/Runner/AppDelegate.swift"
cp "$TEMPLATES_DIR/Entitlements.plist" "$APP_DIR/ios/Entitlements.plist"

# 安全追加自定义 Info.plist 权限配置，不破坏 Flutter 官方键值
python3 "$ROOT_DIR/tooling/patch_plist.py" "$APP_DIR/ios/Runner/Info.plist"

echo "==> 获取 Flutter 依赖..."
flutter pub get

echo "==> 开始编译 iOS Release..."
flutter build ios --release --no-codesign

BUILD_APP_PATH=$(find "$APP_DIR/build/ios" -name "Runner.app" -type d | head -n 1)

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
  echo "==> [关键] 对所有 Frameworks 和 dylib 递归执行伪签名 (防止 dyld SIGKILL)..."
  find "$PAYLOAD_DIR/Runner.app" -depth \( -name "*.framework" -o -name "*.dylib" \) | while read -r item; do
    if [ -d "$item" ]; then
      bin_name=$(basename "$item" .framework)
      if [ -f "$item/$bin_name" ]; then
        echo "  -> 签名 Framework 内部二进制: $item/$bin_name"
        ldid -S "$item/$bin_name"
      fi
    elif [ -f "$item" ]; then
      echo "  -> 签名 Dylib: $item"
      ldid -S "$item"
    fi
  done

  echo "==> 对主二进制 Runner 注入 Entitlements 并签名..."
  ldid -S"$ENTITLEMENTS" "$PAYLOAD_DIR/Runner.app/Runner"
  ldid -S"$ENTITLEMENTS" "$PAYLOAD_DIR/Runner.app"
  echo "==> TrollStore 递归签名注入完成！"
fi

echo "==> 打包 IPA..."
cd "$OUT_DIR"
rm -f "$IPA_NAME"
zip -qry "$IPA_NAME" Payload

echo "==> [成功] IPA 已生成: $OUT_DIR/$IPA_NAME"
ls -lh "$OUT_DIR/$IPA_NAME"
