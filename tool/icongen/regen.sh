#!/usr/bin/env bash
# 重新生成全部启动图标（6 个文件）。
#
# 为什么不用 Gradle 任务：图标是**签入仓库的设计资产**，不是构建产物——
# 换一次图形要人看、要 review diff，不该在每次 assemble 里重算。
#
# 依赖一个 JDK（只需编译期）。本机用的是 C:/build-tools 下的那个；
# 换机器时用 JAVA_HOME 覆盖。
set -euo pipefail
cd "$(dirname "$0")"

JDK="${JAVA_HOME:-C:/build-tools/jdk-21.0.13.0.2+1}"
JAVAC="$JDK/bin/javac"
JAVA="$JDK/bin/java"
for exe in "$JAVAC" "$JAVA"; do
  [ -x "$exe" ] || exe="$exe.exe"
  [ -x "$exe" ] || { echo "找不到 $exe（用 JAVA_HOME 指定 JDK）" >&2; exit 1; }
done

"$JAVAC" -encoding UTF-8 -d . IconGen.java

RES=../../android/app/src/main/res

"$JAVA" IconGen foreground 432 "$RES/drawable-nodpi/ic_launcher_foreground.png"

"$JAVA" IconGen legacy 48  "$RES/mipmap-mdpi/ic_launcher.png"
"$JAVA" IconGen legacy 72  "$RES/mipmap-hdpi/ic_launcher.png"
"$JAVA" IconGen legacy 96  "$RES/mipmap-xhdpi/ic_launcher.png"
"$JAVA" IconGen legacy 144 "$RES/mipmap-xxhdpi/ic_launcher.png"
"$JAVA" IconGen legacy 192 "$RES/mipmap-xxxhdpi/ic_launcher.png"

echo
echo "[OK] 6 个图标已生成；自适应图标（Android 8+）= 白底(@android:color/white) + 镂空前景"
