#!/usr/bin/env bash
# ============================================================================
# Widget Previews 环境（Flutter 3.47 起转正）—— 本项目的唯一入口
#
# 用法：
#   ./tool/preview.sh               启动预览面板（默认用 Chrome；没有 Chrome 会报错）
#   ./tool/preview.sh --web-server  只起本地 web 服务并打印 URL（不依赖浏览器）
#   ./tool/preview.sh --clean       删除 .widget_preview 脚手架（清缓存）
#   ./tool/preview.sh --help        显示帮助
#
# 为什么要包一层：flutter 不在 PATH；本机代理会拦本地端口；引擎与包要走镜像。
# 这三件事和 tool/build_apk.sh 完全一样，不重复踩第二遍。
#
# 缓存（3.47 的新东西）：首次启动把脚手架生成到 .widget_preview/，并写
# preview_manifest.json（Dart SDK 版本 + 每个 pubspec 的 MD5）。之后只要这两样
# 没变，就跳过 `flutter create` 与 pub get，启动明显更快。改过 pubspec 会自动重建。
# .widget_preview/ 已在 .gitignore 里，不要入库。
# ============================================================================
set -euo pipefail

usage() {
  cat <<'EOF'
用法：./tool/preview.sh [--web-server | --clean]

  （无参数）      启动预览面板，默认交给 Chrome 打开
  --web-server    只用 web-server 设备起服务，打印 URL，不拉起浏览器
  --clean         删除 .widget_preview 脚手架（下次启动重新生成）
  -h, --help      显示本帮助
EOF
}

MODE=start
WEB_SERVER=0
for arg in "$@"; do
  case "$arg" in
    --web-server) WEB_SERVER=1 ;;
    --clean) MODE=clean ;;
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

# 代理会拦 127.0.0.1 的预览服务；引擎与包走国内镜像（与 build_apk.sh 同口径）。
unset http_proxy https_proxy all_proxy ALL_PROXY
export NO_PROXY=localhost,127.0.0.1
export HTTP_PROXY=
export HTTPS_PROXY=
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export PUB_HOSTED_URL=https://pub.flutter-io.cn

if [ "$MODE" = clean ]; then
  echo "==> 清理预览脚手架"
  "$FLUTTER" widget-preview clean
  exit 0
fi

ARGS=(widget-preview start)
if [ "$WEB_SERVER" -eq 1 ]; then
  ARGS+=(--web-server)
  echo "==> 启动 Widget Preview（web-server 模式，URL 见下方输出）"
else
  echo "==> 启动 Widget Preview（默认浏览器；没有 Chrome 就加 --web-server）"
fi

# 首次启动会生成 .widget_preview（约 1–2 分钟）；之后走 manifest 缓存直接起。
exec "$FLUTTER" "${ARGS[@]}"
