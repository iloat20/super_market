#!/usr/bin/env bash
# 探测本项目全部业务端点是否支持 Brotli（Content-Encoding: br）。
#
# 背景：dart:io 的 HttpClient 默认发 `Accept-Encoding: gzip`，且只会自动
# 解压 gzip（见 dart-sdk/lib/_http/http_impl.dart 的 _getCompressionState
# 与 http.dart 的 autoUncompress 文档）。有人提议手动加 `br` 再省 15–20%，
# 前提是「服务端真的会回 br」。本脚本用真网端点验证这个前提。
#
# 每个端点发 4 种 Accept-Encoding：
#   identity    —— 基线：不压缩时的线上字节数
#   gzip        —— 现状：dart:io 默认发的头，也是当前 App 实际拿到的
#   br          —— 假设：只声明 br，看服务端会不会回 Content-Encoding: br
#   br, gzip    —— 真实客户端会发的协商头，看降级行为
# curl 不加 --compressed，所以 size_download 就是**线上字节数**，不是解压后。
#
# 对照自证：cloudflare.com 必须回 Content-Encoding: br。若连它都探不到，
# 说明探针或当前网络环境失效，「0 个端点支持 br」的结论不可信，exit 2。
#
# 用法：bash tool/probe_brotli.sh（手动跑，不进 CI；需要联网，约 1–2 分钟）
# 说明：只读取响应头与字节数，不解码响应体，因此不依赖 curl 是否编译了 brotli。

set -uo pipefail

UA='Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36'
CONTROL_URL='https://www.cloudflare.com/'
# 用 POSIX /tmp 下的固定路径：Git Bash 的 `mktemp -d` 会返回带盘符的混合路径，
# 某些沙箱的 safe-delete 包装会拒绝清理那种路径。
TMP="/tmp/probe_brotli.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

# 真实自选（AppConfig.stocks，2026-11-06 快照）与公开源上限 30 只的批量串
SINA5='sz000651,sz000933,rt_hk01378,sz000792,gb_pdd'
TX5='sz000651,sz000933,hk01378,sz000792,usPDD.OQ'
SINA30='sh600519,sh601318,sh600036,sh601899,sh600900,sh601012,sh600030,sh601166,sh600276,sh600887,sh601288,sh601398,sh600009,sh600031,sh601888,sz000001,sz000651,sz000858,sz000333,sz002594,sz300750,sz002415,sz000725,sz300059,sz002475,sz000063,sz300124,sz002230,sh601127,sh600104'
TX30="$SINA30"

# name|url|referer（'-' 表示不发 Referer）
ENDPOINTS=(
  "新浪报价·默认5只|https://hq.sinajs.cn/list=$SINA5|https://finance.sina.com.cn"
  "新浪报价·上限30只|https://hq.sinajs.cn/list=$SINA30|https://finance.sina.com.cn"
  "腾讯报价·默认5只|https://qt.gtimg.cn/q=$TX5|https://gu.qq.com"
  "腾讯报价·上限30只|https://qt.gtimg.cn/q=$TX30|https://gu.qq.com"
  '东财美股补位|https://push2.eastmoney.com/api/qt/ulist.np/get?fltt=2&invt=2&secids=105.AAPL,105.PDD,106.BABA&fields=f2,f3,f4,f5,f6,f12,f13,f15,f16,f17,f18,f124|-'
  '东财搜索建议|https://searchapi.eastmoney.com/api/suggest/get?input=%E8%8C%85%E5%8F%B0&type=14&token=D43BF722C8E33BDC906FB84D85E326E8&count=10|https://quote.eastmoney.com/'
  '新浪目录页num=100|https://vip.stock.finance.sina.com.cn/quotes_service/api/json_v2.php/Market_Center.getHQNodeData?page=1&num=100&sort=symbol&asc=1&node=hs_a&symbol=&_s_r_a=page|-'
  '腾讯目录页count=200|https://proxy.finance.qq.com/cgi/cgi-bin/rank/hs/getBoardRankList?board_code=aStock&sort_type=price&direct=down&offset=0&count=200|https://gu.qq.com'
  '新浪日线80根|https://quotes.sina.cn/cn/api/openapi.php/CN_MarketDataService.getKLineData?symbol=sh600519&scale=240&datalen=80|https://finance.sina.com.cn'
  '腾讯日线80根|https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=sh600519,day,,,80,qfq|https://gu.qq.com'
  '腾讯分时|https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=sh600519|https://gu.qq.com'
)

# probe <url> <referer> <accept-encoding> -> "<http> <content-encoding|-> <bytes>"
probe() {
  local url=$1 ref=$2 enc=$3
  local h="$TMP/h" b="$TMP/b" out http ce bytes
  local args=(--noproxy '*' -sS -m 12 -D "$h" -o "$b"
              -w '%{http_code} %{size_download}' -H "User-Agent: $UA")
  if [ "$ref" != '-' ]; then args+=(-H "Referer: $ref"); fi
  args+=(-H "Accept-Encoding: $enc" "$url")
  out=$(curl "${args[@]}" 2>/dev/null) || out='000 0'
  http=$(printf '%s' "$out" | awk '{print $1}')
  bytes=$(printf '%s' "$out" | awk '{print $2}')
  ce=$(tr -d '\r' < "$h" 2>/dev/null | grep -i '^content-encoding:' \
       | head -1 | cut -d: -f2- | tr -d ' \t\r\n')
  printf '%s %s %s' "$http" "${ce:--}" "${bytes:-0}"
}

# ---- 对照自证 ----
read -r c_http c_ce c_bytes <<< "$(probe "$CONTROL_URL" '-' 'br')"
if [ "$c_ce" != 'br' ] || [ "${c_bytes:-0}" -le 0 ]; then
  echo "✗ 对照 $CONTROL_URL 未返回 br（http=$c_http ce=$c_ce bytes=$c_bytes）。" >&2
  echo "  探针或网络环境失效，本次「不支持 br」的结论不可信。" >&2
  exit 2
fi
echo "✓ 探针自证通过：$CONTROL_URL 回 Content-Encoding: br（$c_bytes B）"
echo "  说明 curl / 网络 / 响应头解析都能识别 br；以下为本项目端点。"
echo

# 对照域名的三种编码体积：用来量化「若服务端支持，br 相对 gzip 能省多少」
read -r _ ci_ce ci_bytes <<< "$(probe "$CONTROL_URL" '-' 'identity')"
read -r _ cg_ce cg_bytes <<< "$(probe "$CONTROL_URL" '-' 'gzip')"
if [ "$cg_bytes" -gt 0 ] 2>/dev/null; then
  pct=$(awk -v g="$cg_bytes" -v b="$c_bytes" 'BEGIN{printf "%.1f", (g-b)*100/g}')
  echo "对照域名理论收益：identity ${ci_bytes}B($ci_ce) / gzip ${cg_bytes}B($cg_ce) / br ${c_bytes}B → br 比 gzip 省 ${pct}%"
  echo
fi

printf '%-22s %11s %15s %15s %15s  %s\n' \
  '端点' 'identity' 'gzip(现状)' 'br' 'br,gzip' '判定'
printf '%.0s-' {1..104}; echo

br_count=0
gzip_count=0
sum_gzip=0
sum_negotiated=0
for entry in "${ENDPOINTS[@]}"; do
  IFS='|' read -r name url ref <<< "$entry"
  read -r h0 e0 n0 <<< "$(probe "$url" "$ref" 'identity')"
  read -r h1 e1 n1 <<< "$(probe "$url" "$ref" 'gzip')"
  read -r h2 e2 n2 <<< "$(probe "$url" "$ref" 'br')"
  read -r h3 e3 n3 <<< "$(probe "$url" "$ref" 'br, gzip')"

  verdict='无压缩'
  if [ "$e1" = 'gzip' ]; then
    gzip_count=$((gzip_count + 1))
    verdict='仅 gzip'
  fi
  if [ "$e2" = 'br' ] && [ "${n2:-0}" -lt "${n0:-1}" ] 2>/dev/null; then
    br_count=$((br_count + 1))
    verdict='✓ 支持 br'
  fi
  sum_gzip=$((sum_gzip + ${n1:-0}))
  sum_negotiated=$((sum_negotiated + ${n3:-0}))

  printf '%-22s %6sB(%s) %7sB(%s) %7sB(%s) %7sB(%s)  %s\n' \
    "$name" "${n0:-0}" "$h0" "${n1:-0}" "$e1" "${n2:-0}" "$e2" \
    "${n3:-0}" "$e3" "$verdict"
done

echo
echo "统计：${#ENDPOINTS[@]} 个业务端点中，${gzip_count} 个支持 gzip（= 当前 App 已自动享受），"
echo "      ${br_count} 个在只声明 br 时真正返回 br。"
echo "      全部端点「gzip」合计 ${sum_gzip}B；「br,gzip」协商合计 ${sum_negotiated}B。"
if [ "$br_count" -eq 0 ]; then
  echo "结论：0 个端点支持 br → 手动加 Accept-Encoding: br 的收益为 0，"
  echo "      且会顶掉 dart:io 默认的 gzip 头（失去现有的压缩），故不做。"
else
  echo "结论：有端点支持 br → 此时才值得评估 brotli 解码依赖的体积 / 兼容性成本。"
fi
