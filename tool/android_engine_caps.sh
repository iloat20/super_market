#!/usr/bin/env bash
# 查 Android 引擎里几个「性能开关」到底在不在。
#
# 为什么要有这个脚本：ADPF / HCPP / 脏视图合成 这三件事，官方博客、issue、
# 合并记录各说各话（有的合并后被回退），光看文章判断不了「我这个 SDK 里有没有」。
# 这里直接从**本机引擎产物**里数符号，升级 Flutter 之后重跑一次就知道到货没有。
#
# 用法：bash tool/android_engine_caps.sh [abi]
#   abi 默认 arm64（本项目只打 arm64-v8a）。
set -u

ABI="${1:-arm64}"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
if ! command -v "$FLUTTER_BIN" >/dev/null 2>&1; then
  # 本项目机器上 flutter 不在 PATH
  FLUTTER_BIN="/c/Users/Administrator/Downloads/flutter/bin/flutter"
fi
FLUTTER_ROOT="$(cd "$(dirname "$FLUTTER_BIN")/.." && pwd)"
ENGINE_DIR="$FLUTTER_ROOT/bin/cache/artifacts/engine/android-$ABI-release"
JAR="$ENGINE_DIR/flutter.jar"

if [ ! -f "$JAR" ]; then
  echo "找不到引擎产物：$JAR" >&2
  echo "先跑一次 flutter precache --android，或确认 abi 拼写（arm/arm64/x64）。" >&2
  exit 1
fi

TMP="$PWD/build/engine_caps_$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && unzip -q -o "$JAR" 'lib/*/libflutter.so' >/dev/null 2>&1)
SO="$(find "$TMP/lib" -name libflutter.so 2>/dev/null | head -1)"
if [ -z "$SO" ]; then
  echo "jar 里没有 libflutter.so，引擎产物结构变了？" >&2
  exit 1
fi

# grep -c 在二进制上按「匹配行数」计，这里只关心 0 / 非 0。
# 注意 grep -c 无匹配时会打印 0 但返回 1，不能直接接 `|| echo 0`（会输出两行）。
count() {
  local n
  n=$(grep -c "$1" "$SO" 2>/dev/null | head -1)
  echo "${n:-0}"
}

VERSION="$("$FLUTTER_BIN" --version 2>/dev/null | head -1 | tr -d '\r')"
ENGINE_REV="$(cat "$FLUTTER_ROOT/bin/internal/engine.version" 2>/dev/null | tr -d '\r\n')"
echo "引擎：$VERSION · android-$ABI-release"
echo "      engine ${ENGINE_REV:-未知}（bin/internal/engine.version）"
echo

adpf=$(count 'APerformanceHint')
if [ "$adpf" -eq 0 ]; then
  echo "ADPF                : 无（APerformanceHint 0 处）"
  echo "                      → 没有开关可开。上游 PR #192582（API 35+ / AWorkDuration）尚未合并"
else
  echo "ADPF                : 有（APerformanceHint $adpf 处）→ 找 flutter_tools 里的开关键"
fi

hcpp=$(count 'ASurfaceTransaction')
if grep -q "enableHcpp" "$FLUTTER_ROOT/packages/flutter_tools/lib/src/commands/run.dart" 2>/dev/null; then
  echo "HCPP                : 支持（--enable-hcpp / 清单 io.flutter.embedding.android.EnableHcpp）"
  echo "                      ASurfaceTransaction $hcpp 处；需 API 34+ 与 Vulkan 后端"
else
  echo "HCPP                : 工具链里没有 enableHcpp（引擎 ASurfaceTransaction $hcpp 处）"
fi

if grep -q "needsCompositeFrame" "$FLUTTER_ROOT/packages/flutter/lib/src/rendering/binding.dart" 2>/dev/null; then
  echo "脏视图合成          : 有（框架里有 needsCompositeFrame）"
else
  echo "脏视图合成          : 无（drawFrame 仍遍历全部 renderViews；只对多视图有意义）"
fi

echo "Impeller / Vulkan   : $(count 'Vulkan') 处 Vulkan 字样（着色器/后端存在，不代表走 Vulkan）"
