#!/usr/bin/env python3
"""探测「增量 K 线：只拉最新 1 根再本地拼接」的可行性。

用法：python tool/probe_kline_delta.py   （需联网，约 30s，不进 CI）

必须回答的四个问题（缺一个都不能下"可以做增量"的结论）：

1. count=1 在**两个真实源**上是否都返回 1 根，而不是报错/忽略参数/给默认 80 根；
2. 这 1 根与同一时刻 count=80 响应的**最后一根是否逐字段相同**——
   腾讯走 qfq 前复权，复权基准若随返回根数变化，拼接会留下 79 根旧价 +
   1 根新价，图上直接出现一个人造跳空；
3. 是否「同源可比」：主备两条链的当日 bar 口径不同（新浪不含当日、
   腾讯含当日且实时更新），跨源拼接会静默混进两种语义；
4. 究竟省多少字节 —— 收益要拿真网响应量，不要拿"感觉"估。

对照自证：每个端点都同时取 count=2/3，若 count 参数被服务端忽略
（三次响应字节数/根数相同），说明本探针与结论一起失效，脚本 exit 2。
"""

from __future__ import annotations

import json
import subprocess
import sys
import urllib.parse

UA = "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36"


def fetch(url: str, headers: dict[str, str]) -> tuple[int, bytes]:
    cmd = ["curl", "--noproxy", "*", "-sS", "-m", "15", "-w", "\n%{http_code}"]
    for k, v in headers.items():
        cmd += ["-H", f"{k}: {v}"]
    cmd.append(url)
    out = subprocess.run(cmd, capture_output=True, check=False)
    if out.returncode != 0:
        return 0, b""
    raw = out.stdout
    body, _, code = raw.rpartition(b"\n")
    try:
        return int(code.strip()), body
    except ValueError:
        return 0, body


def sina_url(symbol: str, n: int) -> str:
    q = urllib.parse.urlencode(
        {"symbol": symbol, "scale": "240", "datalen": str(n)}
    )
    return "https://quotes.sina.cn/cn/api/openapi.php/CN_MarketDataService.getKLineData?" + q


def tencent_url(symbol: str, n: int) -> str:
    q = urllib.parse.urlencode({"param": f"{symbol},day,,,{n},qfq"})
    return "https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?" + q


def sina_rows(body: bytes) -> list[object]:
    try:
        obj = json.loads(body.decode("utf-8", "replace"))
    except (ValueError, UnicodeError):
        return []
    data = obj.get("result", {}).get("data")
    return data if isinstance(data, list) else []


def tencent_rows(body: bytes) -> list[object]:
    try:
        obj = json.loads(body.decode("utf-8", "replace"))
    except (ValueError, UnicodeError):
        return []
    if obj.get("code") not in (0, None):
        return []
    data = obj.get("data")
    if not isinstance(data, dict):
        return []
    for node in data.values():
        if not isinstance(node, dict):
            continue
        rows = node.get("qfqday") or node.get("day")
        if isinstance(rows, list):
            return rows
    return []


def day_of(row: object) -> str:
    if isinstance(row, dict):
        return str(row.get("day", "?"))[:10]
    if isinstance(row, list) and row:
        return str(row[0])[:10]
    return "?"


CASES = [
    # (标签, 源, 代码, url 构造, 请求头, 行解析)
    (
        "新浪 A股 sh600519",
        "sina",
        "sh600519",
        sina_url,
        {"User-Agent": UA},
        sina_rows,
    ),
    (
        "腾讯 A股 sh600519",
        "tencent",
        "sh600519",
        tencent_url,
        {"Referer": "https://gu.qq.com", "User-Agent": UA},
        tencent_rows,
    ),
    (
        "腾讯 指数 sh000001",
        "tencent",
        "sh000001",
        tencent_url,
        {"Referer": "https://gu.qq.com", "User-Agent": UA},
        tencent_rows,
    ),
    (
        "腾讯 美股 usAAPL.OQ",
        "tencent",
        "usAAPL.OQ",
        tencent_url,
        {"Referer": "https://gu.qq.com", "User-Agent": UA},
        tencent_rows,
    ),
    (
        "腾讯 港股 hk00700",
        "tencent",
        "hk00700",
        tencent_url,
        {"Referer": "https://gu.qq.com", "User-Agent": UA},
        tencent_rows,
    ),
]


def main() -> int:
    failed_control = 0
    print("增量 K 线探针：count=80 / 3 / 2 / 1 同源同时抓取")
    print("=" * 96)
    for label, source, symbol, url_of, headers, rows_of in CASES:
        got: dict[int, tuple[int, int, list[object]]] = {}
        for n in (80, 3, 2, 1):
            status, body = fetch(url_of(symbol, n), headers)
            rows = rows_of(body)
            got[n] = (status, len(body), rows)

        s80, b80, r80 = got[80]
        s1, b1, r1 = got[1]
        s2, b2, r2 = got[2]
        _, b3, r3 = got[3]

        print(f"\n■ {label}")
        print(
            "  %-9s %-8s %-10s %s"
            % ("count", "HTTP", "字节", "根数 / 最后一根日期")
        )
        for n in (80, 3, 2, 1):
            st, by, rs = got[n]
            print(f"  {n:<9} {st:<8} {by:<10} {len(rs):<4} {day_of(rs[-1]) if rs else '—'}")

        # 对照自证：count 必须真的生效
        lens = {len(r3), len(r2), len(r1)}
        if b80 == b1 or (len(lens) == 1 and len(r3) != 3):
            print("  ✗ count 参数未生效（响应无差别）：本探针不可信")
            failed_control += 1
            continue

        if not r80 or not r1:
            print("  ✗ 解析失败，无法比较")
            failed_control += 1
            continue

        same_last = r1[-1] == r80[-1]
        anchor_ok = len(r2) >= 2 and r2[0] == r80[-2]
        print(f"  count=1 与 count=80 末根逐字段相同 : {'是' if same_last else '否'}")
        if not same_last:
            print(f"    80末根 = {r80[-1]}")
            print(f"     1末根 = {r1[-1]}")
        print(
            f"  count=2 的首根可作连续性锚点     : {'是' if anchor_ok else '否'}"
            "（判据：等于 80 根响应的倒数第 2 根）"
        )
        saved = b80 - b1
        print(
            f"  单次省流                          : {saved} B "
            f"({b80} → {b1}，{saved * 100 / b80:.1f}%)"
        )
        print(f"  末根日期                          : {day_of(r80[-1])}")

    print("\n" + "=" * 96)
    if failed_control:
        print(f"✗ {failed_control} 个端点探针自证失败，结论不可信。")
        return 2
    print("✓ 所有端点 count 参数生效，以上数据可作为决策依据。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
