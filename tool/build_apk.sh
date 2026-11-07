#!/usr/bin/env bash
# ============================================================================
# 构建个人自用 release APK —— **唯一入口**
#
# 用法：
#   ./tool/build_apk.sh               默认不混淆（崩溃栈保留可读的 Dart 符号）
#   ./tool/build_apk.sh --obfuscate   额外混淆（只省约 0.06MB，符号表必须归档）
#   ./tool/build_apk.sh --help        显示帮助
#
# 固定四件事，少写一个就白打包：
#   1. --target-platform android-arm64
#        只打 64 位。三种 ABI 全打是 43.9MB，只留 arm64 是 15.5MB ——
#        体积的 97% 都在 lib/ 里的 libflutter.so，每个 ABI 各一份。
#        2018 年之后的 Android 手机都是 arm64，个人自用没必要为 32 位付 28MB。
#   2. R8（在 app/build.gradle.kts 里开，规则在 app/proguard-rules.pro）
#        dex 从 2004KB 压到 396KB，省约 1.7MB。
#   3. --split-debug-info=build/symbols
#        把调试符号从 libapp.so 里剥离出来单独存，省 0.5MB。
#        崩溃栈可用 build/symbols 还原（flutter symbolize）。
#   4. tool/verify_apk.py
#        解包断言 ABI / R8 keep 类 / 数据源字符串确实进了包——这三样肉眼看不出来。
#
# 为什么默认**不**混淆：
#   2026-11-07 在同一份源码上复测：默认包 8 289 399 B，--obfuscate 包 8 260 727 B，
#   只省 28 672 B（0.03MB）；代价是崩溃栈变成一堆 a.b.c()，必须长期保管符号表
#   才能还原。个人自用不值得。真要开就显式传 --obfuscate，并把 build/symbols
#   与 APK 一起归档——换台机器就再也还原不出来。
#
# 产物：build/app/outputs/flutter-apk/app-release.apk
#       gradle 的 copySuperMarketApk 另存为
#       build/app/outputs/supermarket/super market.apk
# ============================================================================
set -euo pipefail

usage() {
  cat <<'EOF'
用法：./tool/build_apk.sh [--obfuscate]

  （无参数）      不混淆：崩溃栈保留可读的 Dart 符号（推荐）
  --obfuscate    额外混淆 Dart 代码；符号表在 build/symbols，发版必须一起归档
  -h, --help     显示本帮助
EOF
}

OBFUSCATE=0
for arg in "$@"; do
  case "$arg" in
    --obfuscate) OBFUSCATE=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "[!] 未知参数：$arg" >&2
      echo >&2
      usage >&2
      exit 2
      ;;
  esac
done

cd "$(dirname "$0")/.."

# ---------------------------------------------------------------- 工具链
#
# Flutter 不在 PATH 时退到仓库约定的本机路径（README 第 3 节）；
# FLUTTER=/path/to/flutter 可显式覆盖，方便换机器。
FLUTTER="${FLUTTER:-}"
if [ -z "$FLUTTER" ]; then
  if command -v flutter >/dev/null 2>&1; then
    FLUTTER=flutter
  else
    FLUTTER=/c/Users/Administrator/Downloads/flutter/bin/flutter
  fi
fi
if ! command -v "$FLUTTER" >/dev/null 2>&1; then
  echo "[!] 找不到 flutter：先 export PATH=...，或 FLUTTER=/path/to/flutter $0" >&2
  exit 1
fi

# 本机代理会拦 127.0.0.1 的构建请求；Flutter 引擎产物从国内镜像取（见 README）。
# 小写变量也要清：Gradle / pub 有一部分实现只认小写，留着会让构建偶尔卡在下载。
unset http_proxy https_proxy all_proxy ALL_PROXY
export NO_PROXY=localhost,127.0.0.1
export HTTP_PROXY=
export HTTPS_PROXY=
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export PUB_HOSTED_URL=https://pub.flutter-io.cn

# pubspec.lock 已按镜像地址提交（2026-11-07：只改 47 处来源 url，版本一个没动），
# 所以正常构建 / 测试不会再产生锁文件 diff；只有在**不设** PUB_HOSTED_URL 的
# 环境里重新 pub get 才会被改回 pub.dev——那属于换源，不是依赖漂移。

APK=build/app/outputs/flutter-apk/app-release.apk
SYMBOLS=build/symbols

BUILD_ARGS=(
  build apk
  --release
  --target-platform android-arm64
  --split-debug-info="$SYMBOLS"
)
if [ "$OBFUSCATE" -eq 1 ]; then
  BUILD_ARGS+=(--obfuscate)
  echo "==> 构建（64 位 arm64-v8a · R8 · 剥离符号 · Dart 混淆）"
  echo "    ⚠ 混淆符号表只对本次构建有效：发版请把 $SYMBOLS 与 APK 一起归档"
else
  echo "==> 构建（64 位 arm64-v8a · R8 · 剥离符号 · 不混淆）"
fi

"$FLUTTER" "${BUILD_ARGS[@]}"

echo
echo "==> 校验产物"
python tool/verify_apk.py "$APK"

echo
echo "==> 调试符号（崩溃栈还原用）"
if [ -d "$SYMBOLS" ]; then
  du -sh "$SYMBOLS" | sed 's/^/    /'
  echo "    还原崩溃栈：flutter symbolize -i <stack.txt> -d $SYMBOLS"
else
  echo "    (无)"
fi

echo
echo "==> 产物"
ls -lh "$APK" | sed 's/^/    /'
COPIED="build/app/outputs/supermarket/super market.apk"
if [ -f "$COPIED" ]; then
  ls -lh "$COPIED" | sed 's/^/    /'
fi
