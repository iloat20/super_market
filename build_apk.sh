#!/usr/bin/env bash
# 超级市场 release 构建脚本（Git Bash / Linux / macOS 通用）。
#
# 必须带这些参数，理由：
#  - --target-platform android-arm64：只打 64 位引擎（三 ABI 混包 48.9MB → 16.6MB）
#  - --obfuscate + --split-debug-info：混淆 Dart 代码并把符号表分离到
#    build/debug-info/（还原混淆堆栈时用它，别删）
#
# 产物：build/app/outputs/flutter-apk/app-release.apk（flutter 固定名）
#       gradle 的 copySuperMarketApk 会复制为
#       build/app/outputs/supermarket/super market.apk
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v flutter > /dev/null 2>&1; then
  FLUTTER="${FLUTTER:-C:/Users/Administrator/Downloads/flutter/bin/flutter}"
else
  FLUTTER=flutter
fi

"$FLUTTER" build apk --release \
  --target-platform android-arm64 \
  --obfuscate \
  --split-debug-info=build/debug-info

echo
echo "[OK] 产物：build/app/outputs/supermarket/super market.apk"
