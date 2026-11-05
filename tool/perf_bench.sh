#!/usr/bin/env bash
# 真机性能 / 内存基线（针对 ColorOS 类 ROM 调整过）。
#
# 用法：
#   ./tool/perf_bench.sh              # 跑全套基线
#   ./tool/perf_bench.sh --trim       # 触发 onTrimMemory，看 didHaveMemoryPressure 是否生效
#   ./tool/perf_bench.sh --kill-cause # 判定后台是被 LMK 杀还是被系统冻结
#
# 需要：手机已连 adb、已安装 release 包。
set -u

ADB="${ADB:-/c/Android/sdk/platform-tools/adb.exe}"
PKG="${PKG:-com.example.super_market}"
ACT="$PKG/.MainActivity"
APK="build/app/outputs/flutter-apk/app-release.apk"

if ! "$ADB" get-state >/dev/null 2>&1; then
  echo "✗ 没有设备（adb devices 为空）"
  exit 1
fi

say() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

case "${1:-}" in
  --kill-cause)
    say "进程状态（frozen=true 说明被 ColorOS 冻结，不是被 LMK 杀）"
    "$ADB" shell dumpsys activity processes | tr -d '\r' | grep -A3 "$PKG" | head -12
    say "系统事件里的杀进程记录（am_kill / am_proc_died）"
    "$ADB" logcat -b events -d 2>/dev/null | tr -d '\r' | grep -E "am_kill|am_proc_died" | grep -i "$PKG" | tail -10
    say "内存压力历史"
    "$ADB" shell dumpsys meminfo | tr -d '\r' | grep -E "Free RAM|Used RAM|Lost RAM|ZRAM" | head -6
    exit 0
    ;;
  --trim)
    say "触发 onTrimMemory(RUNNING_LOW) → 期望走 didHaveMemoryPressure"
    "$ADB" shell am send-trim-memory "$PKG" RUNNING_LOW 2>&1 | tr -d '\r'
    sleep 2
    "$ADB" logcat -d -s flutter 2>/dev/null | tr -d '\r' | grep -iE "memory|trim" | tail -5
    exit 0
    ;;
esac

say "设备"
"$ADB" shell getprop ro.product.model | tr -d '\r'
printf 'Android '; "$ADB" shell getprop ro.build.version.release | tr -d '\r'
printf 'SDK '; "$ADB" shell getprop ro.build.version.sdk | tr -d '\r'
"$ADB" shell dumpsys display 2>/dev/null | tr -d '\r' | grep -o "fps=[0-9.]*" | head -1

say "冷启动（3 次：TotalTime 越小越好）"
for i in 1 2 3; do
  "$ADB" shell am force-stop "$PKG"
  sleep 1
  "$ADB" shell am start -W -n "$ACT" | tr -d '\r' | grep -E "TotalTime|WaitTime" | tr '\n' ' '
  echo
done

say "内存（启动后静置 5s）"
"$ADB" shell am start -n "$ACT" >/dev/null 2>&1
sleep 5
"$ADB" shell dumpsys meminfo "$PKG" | tr -d '\r' \
  | grep -E "TOTAL PSS|TOTAL RSS|Java Heap|Native Heap|Graphics|GL mtrack" | head -8

say "后台 5 分钟后（判断常驻是否稳定）"
"$ADB" shell input keyevent KEYCODE_HOME
sleep 300
"$ADB" shell dumpsys meminfo "$PKG" | tr -d '\r' | grep -E "TOTAL PSS|TOTAL RSS" | head -2
"$ADB" shell dumpsys activity processes | tr -d '\r' | grep -A2 "$PKG" | grep -E "frozen|procState" | head -3

say "滑动帧耗时（不在本脚本采）"
echo "Flutter 自绘：dumpsys gfxinfo 恒为 0 帧（HWUI 统计不到 raster 线程），"
echo "SurfaceFlinger --latency 在部分 ROM 上缓冲区也是空的。"
echo "请用 ./tool/measure_frames.sh  ← profile 包 + PERF_LOG 的 FrameTiming 探针"

say "APK 体积"
ls -l "$APK" | awk '{printf "%.2f MB\n", $5/1048576}'
