#!/usr/bin/env bash
# ============================================================================
# 滑动帧耗时实测（真机）
#
# 为什么不能用 dumpsys gfxinfo：Flutter 自己接管渲染线程，HWUI 统计不到它的
# 帧——reset 之后滑一次，`Total frames rendered: 0`。`SurfaceFlinger --latency`
# 在部分 ROM 上缓冲区也是空的。唯一可靠的数字来自引擎的 FrameTiming。
#
# 这个脚本做五件事：
#   1. 装带探针的 profile 包（--dart-define=PERF_LOG=true）；
#   2. 清 logcat，冷启动，抓 `refresh:` 行（当前档位 + 全部 mode）；
#   3. 连滑 5 次，把 `[perf]` 行落到 build/perf/perf-*.log；
#   4. 用 dumpsys 确认当前 display mode；
#   5. 交给 tool/perf_baseline.dart 判定并归档 JSON（含设备/构建/场景/hz）。
#
# 判定只依据官方帧预算 1000/hz（B47 的 60/120fps、B49 的 16ms@60Hz）：
# raster p90 必须小于动态预算、预算必须与 hz 自洽、同次采集只能有一个刷新率档。
# jank 只记录不判定；没有同条件基线时不声称「更优」。
#
# 退出码：0=通过  1=判定失败/采集条件不全  2=不可测（没采到 [perf] 样本）
#
# 用法：  ./tool/measure_frames.sh
#         SCENARIO=scroll-1screen+ DEVICE=PLJ110 ./tool/measure_frames.sh
# ============================================================================
set -uo pipefail

cd "$(dirname "$0")/.."

ADB="${ADB:-adb}"
DART="${DART:-dart}"
PKG=app.supermarket
BUILD="${BUILD:-profile}"
APK="build/app/outputs/flutter-apk/app-${BUILD}.apk"

SCENARIO="${SCENARIO:-scroll-3stocks}"

if ! "$ADB" get-state >/dev/null 2>&1; then
  echo "✗ 没有设备。先插上手机并确认 USB 调试授权。"
  exit 1
fi

if [ ! -f "$APK" ]; then
  echo "✗ 缺 profile 包：$APK"
  echo "  先跑：flutter build apk --profile --target-platform android-arm64 --dart-define=PERF_LOG=true"
  exit 1
fi

if ! command -v "$DART" >/dev/null 2>&1; then
  echo "✗ 找不到 dart。把 Flutter SDK 的 bin 加进 PATH，或用 DART=/path/to/dart 指定。"
  exit 1
fi

DEVICE="${DEVICE:-$("$ADB" shell getprop ro.product.model | tr -d '\r')}"
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p build/perf
PERF_LOG="build/perf/perf-$STAMP.log"
BASELINE_JSON="build/perf/baseline-$STAMP.json"

echo "==> 采集条件：device=$DEVICE build=$BUILD scenario=$SCENARIO"
echo "    只有 baselineKey（device|build|scenario|hz）完全相同的记录才可比。"

echo "==> 安装 profile 包"
"$ADB" install -r "$APK" | tail -1

echo
echo "==> 冷启动"
"$ADB" shell am force-stop "$PKG"
"$ADB" logcat -c
"$ADB" shell am start -n "$PKG/.MainActivity" >/dev/null
sleep 6

echo "==> 刷新率（原生侧）"
"$ADB" logcat -d -s super_market | grep "refresh:" | tail -5

echo
echo "==> 连滑 5 次，采集帧耗时"
"$ADB" logcat -c
for _ in 1 2 3 4 5; do
  "$ADB" shell input swipe 628 2100 628 900 220
done
sleep 3

"$ADB" logcat -d -s flutter | grep "\[perf\]" > "$PERF_LOG" || true
cat "$PERF_LOG"
echo "样本行数：$(wc -l < "$PERF_LOG" | tr -d ' ')"

echo
echo "==> 滑动期间的帧率投票"
"$ADB" logcat -d -s super_market | grep "refresh: 投票" | tail -8

echo
echo "==> 当前 display mode"
"$ADB" shell dumpsys display | grep -m3 -E "mActiveModeId|renderFrameRate|mActiveMode"

echo
echo "==> 判定与归档（tool/perf_baseline.dart）"
"$DART" tool/perf_baseline.dart \
  --device "$DEVICE" --build "$BUILD" --scenario "$SCENARIO" \
  --input "$PERF_LOG" > "$BASELINE_JSON"
rc=$?
cat "$BASELINE_JSON"
echo
echo "归档：$BASELINE_JSON  （原始日志：$PERF_LOG）"

case "$rc" in
  0)
    echo "✓ 判定通过：raster p90 在动态帧预算内。这是「合格」，不是「更优」。"
    ;;
  2)
    echo "✗ 不可测：没采到 [perf] 样本——列表可能不足一屏（滑动没产生帧），"
    echo "  或 profile 包没带 --dart-define=PERF_LOG=true。不可测 ≠ 合格。"
    exit 2
    ;;
  *)
    echo "✗ 判定失败或采集条件不全，见上面 reasons。"
    exit 1
    ;;
esac
