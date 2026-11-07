#!/usr/bin/env bash
# 探测行情端点是否宣告 HTTP/3（QUIC），供「要不要上 cronet_http」的判断使用。
#
# 两条独立证据：
#   1. 真实业务路径响应头里的 Alt-Svc: h3=":443"
#   2. DNS HTTPS RR（TYPE65）里的 alpn="h3..."
# 附带 openssl ALPN 看 HTTP/2，因为 dart:io 的 HttpClient 只说 HTTP/1.1。
#
# 本机 curl 是 Windows Schannel 构建，没有 --http3，无法直连 QUIC，
# 所以只能靠服务端的「宣告」判断，不能测 QUIC 实际连通性。
# 用 cloudflare.com 做对照：若它都探不到 h3，说明探针或网络环境失效，
# 本次「不支持」的结论不可信，脚本直接 exit 2。
#
# 用法：bash tool/probe_http3.sh（手动跑，不进 CI；需要联网，约 30s）

set -uo pipefail

DOH='https://dns.alidns.com/resolve'
CONTROL='cloudflare.com'
CONTROL_URL="https://$CONTROL/"
REFERER='https://finance.sina.com.cn'

# host|真实业务路径（带 path 很重要：CDN 可能只对特定路径回 Alt-Svc）
ENDPOINTS=(
  'hq.sinajs.cn|https://hq.sinajs.cn/list=sh600519'
  'qt.gtimg.cn|https://qt.gtimg.cn/q=sh600519'
  'push2.eastmoney.com|https://push2.eastmoney.com/api/qt/ulist.np/get?fltt=2&invt=2&secids=105.AAPL&fields=f2,f3'
  'searchapi.eastmoney.com|https://searchapi.eastmoney.com/api/suggest/get?input=%E8%8C%85%E5%8F%B0&type=14&count=5'
  'quotes.sina.cn|https://quotes.sina.cn/cn/api/jsonp_v2.php/x/CN_MarketDataService.getKLineData?symbol=sh600519&scale=240&datalen=5'
)

fetch_headers() {
  curl --noproxy '*' -sS -m 12 -D - -o /dev/null \
    -H 'User-Agent: Mozilla/5.0' -H "Referer: $REFERER" "$1" 2>/dev/null
}

https_rr() {
  curl --noproxy '*' -sS -m 10 -H 'accept: application/dns-json' \
    "$DOH?name=$1&type=HTTPS" 2>/dev/null
}

alpn_h2() {
  echo | timeout 12 openssl s_client -alpn h2 \
    -connect "$1:443" -servername "$1" 2>/dev/null \
    | grep -i 'ALPN protocol' | head -1 | sed 's/.*: //'
}

has_h3() {
  printf '%s' "$1" | grep -qi 'h3'
}

# ---- 对照自证 ----
control_hdr=$(fetch_headers "$CONTROL_URL")
control_as=$(printf '%s' "$control_hdr" | tr -d '\r' | grep -i '^alt-svc:' | head -1)
control_rr=$(https_rr "$CONTROL")
if ! has_h3 "$control_as$control_rr"; then
  echo "✗ 对照域名 $CONTROL 没探到 h3：探针或当前网络环境失效，本次结论不可信。" >&2
  echo "  Alt-Svc=[$control_as] HTTPS-RR=[$(printf '%s' "$control_rr" | head -c 160)]" >&2
  exit 2
fi
echo "✓ 探针自证通过（$CONTROL: $(printf '%s' "$control_as" | tr -d '\r')，"
echo "  HTTPS RR 含 alpn=h3）。以下为本项目端点："
echo

printf '%-26s %-9s %-12s %-12s %-8s %s\n' \
  '端点' 'HTTP' 'Alt-Svc(h3)' 'HTTPS-RR(h3)' 'ALPN' '判定'
printf '%.0s-' {1..88}; echo

h3_count=0
for entry in "${ENDPOINTS[@]}"; do
  host=${entry%%|*}
  url=${entry#*|}
  hdr=$(fetch_headers "$url")
  ver=$(printf '%s' "$hdr" | tr -d '\r' | grep -i '^HTTP/' | head -1 | awk '{print $1}')
  as=$(printf '%s' "$hdr" | tr -d '\r' | grep -i '^alt-svc:' | head -1)
  rr=$(https_rr "$host")
  a2=$(alpn_h2 "$host")

  as_h3='—'; rr_h3='—'
  if has_h3 "$as"; then as_h3='h3'; h3_count=$((h3_count + 1)); fi
  if printf '%s' "$rr" | grep -qi 'alpn=\\?"[^\\"]*h3'; then rr_h3='h3'; fi
  # 有 Alt-Svc 或有 HTTPS RR 任一宣告即算支持
  if [ "$as_h3" = '—' ] && [ "$rr_h3" = 'h3' ]; then h3_count=$((h3_count + 1)); fi

  alpn=${a2:-'—'}
  verdict='HTTP/1.1 only'
  if [ "$as_h3" = 'h3' ] || [ "$rr_h3" = 'h3' ]; then verdict='支持 h3'; fi

  printf '%-26s %-9s %-12s %-12s %-8s %s\n' \
    "$host" "${ver:-无响应}" "$as_h3" "$rr_h3" "$alpn" "$verdict"
done

echo
if [ "$h3_count" -eq 0 ]; then
  echo "结论：0/${#ENDPOINTS[@]} 个端点宣告 HTTP/3 → cronet_http 的 h3 路径当前无对象。"
  echo "且常规 3s 轮询复用同一条 TCP/TLS 连接（README 二·五十一 DNS 小节实测），"
  echo "没有握手可省；QUIC 的 0-RTT 只在新建连接时才有意义。"
else
  echo "结论：$h3_count 个端点宣告 h3 → 此时才值得做真机弱网同源 A/B 再评估。"
fi
