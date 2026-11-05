@echo off
rem 超级市场 release 构建脚本。
rem
rem 必须带这些参数，理由：
rem  - --target-platform android-arm64：只打 64 位引擎（三 ABI 混包 48.9MB → 16.6MB）
rem  - --obfuscate + --split-debug-info：混淆 Dart 代码并把符号表分离到
rem    build\debug-info\（还原混淆堆栈时用它，别删）
rem
rem 产物：build\app\outputs\flutter-apk\app-release.apk（flutter 固定名）
rem       gradle 的 copySuperMarketApk 会复制为
rem       build\app\outputs\supermarket\super market.apk
cd /d "%~dp0"
where flutter >nul 2>nul
if errorlevel 1 (
  echo [!] PATH 里找不到 flutter，请改用完整路径或先配置环境变量
  exit /b 1
)
flutter build apk --release --target-platform android-arm64 --obfuscate --split-debug-info=build/debug-info
if errorlevel 1 (
  echo [!] 构建失败
  exit /b 1
)
echo.
echo [OK] 产物：build\app\outputs\supermarket\super market.apk
