#!/usr/bin/env bash
# ============================================================================
# 构建个人自用 release APK
#
# 固定三件事（都是「少写一个就白打包」的参数）：
#   1. --target-platform android-arm64
#        只打 64 位。三种 ABI 全打是 43.9MB，只留 arm64 是 15.5MB ——
#        体积的 97% 都在 lib/ 里的 libflutter.so，每个 ABI 各一份。
#        2018 年之后的 Android 手机都是 arm64，个人自用没必要为 32 位付 28MB。
#   2. R8（在 app/build.gradle.kts 里开，规则在 app/proguard-rules.pro）
#        dex 从 2004KB 压到 396KB，省约 1.7MB。
#   3. --split-debug-info=build/symbols
#        把调试符号从 libapp.so 里剥离出来单独存，省 0.5MB。
#        崩溃栈仍可用 build/symbols 还原（flutter symbolize）。
#
# 用法：  ./tool/build_apk.sh
# 产物：  build/app/outputs/flutter-apk/app-release.apk
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

# 本机代理会拦 127.0.0.1 的构建请求；Flutter 引擎产物从国内镜像取（见 README）
export NO_PROXY=localhost,127.0.0.1
export HTTP_PROXY=
export HTTPS_PROXY=
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export PUB_HOSTED_URL=https://pub.flutter-io.cn

APK=build/app/outputs/flutter-apk/app-release.apk
SYMBOLS=build/symbols

echo "==> 构建（64 位 arm64-v8a · R8 · 剥离调试符号）"
flutter build apk --release \
  --target-platform android-arm64 \
  --split-debug-info="$SYMBOLS"

echo
echo "==> 校验产物"
python tool/verify_apk.py "$APK"

echo
echo "==> 调试符号（崩溃栈还原用）"
if [ -d "$SYMBOLS" ]; then
  du -sh "$SYMBOLS" | sed 's/^/    /'
  echo "    还原崩溃栈： flutter symbolize -i <stack.txt> -d $SYMBOLS"
else
  echo "    (无)"
fi
