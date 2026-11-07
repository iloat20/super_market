@echo off
rem ===========================================================================
rem 已废弃（2026-11-07）：根目录的旧 Windows 构建脚本，保留只为「用错时当场拦住」。
rem
rem 它开 --obfuscate、不跑 tool\verify_apk.py、不设国内镜像——误用会得到一个
rem 崩溃栈只有 a.b.c()、且没人校验过的包。所以它不再构建任何东西。
rem
rem 请在 Git Bash 里跑：./tool/build_apk.sh
rem 需要混淆：        ./tool/build_apk.sh --obfuscate
rem ===========================================================================
echo [!] 这个脚本已废弃，不会再构建任何东西。
echo     请在 Git Bash 里跑：./tool/build_apk.sh
echo     需要混淆：./tool/build_apk.sh --obfuscate
exit /b 1
