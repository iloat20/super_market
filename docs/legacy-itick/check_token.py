#!/usr/bin/env python3
"""不装 APK 也能验证 iTick Token 是否可用。

⚠️ 已退役（2026-11-05，review-2026-11-05 E-03）：iTick 通道已于 2026-11-04
从代码中整体删除（树摇证据见 tool/verify_apk.py 的 iTick 断言），当前数据源是
新浪 / 腾讯公开接口，**没有 Token 概念**。app_config.dart 里已无
`static const String token`，本脚本现在必然以「配置文件里没找到 token」退出；
它引用的 lib/services/quote_parser.dart 也已不存在。

原样保留在本目录作为「切回 iTick」时的恢复手册：域名探测（免费/付费档）、
Token 探活、逐只代码校验、字段名核对都还有效。恢复步骤：
  1. 把 token 常量加回 lib/config/app_config.dart（或命令行直接传参）；
  2. `python docs/legacy-itick/check_token.py`；
  3. 同步更新 tool/verify_apk.py 的 iTick 断言与 README。

用法（历史原样）：
    python tool/check_token.py                  # 读 lib/config/app_config.dart 里的 token
    python tool/check_token.py <YOUR_TOKEN>     # 或者命令行直接给

它做两件事：
  1. 用 REST 接口拉一遍 AppConfig.stocks 里的股票，确认 token 有效、代码/region 拼对了；
  2. 顺带核对返回字段名，和 lib/services/quote_parser.dart 里的映射是否一致。

为什么要有它：APK 装到手机上才发现「认证失败」，排查成本远高于在这里跑 3 秒。
只依赖 Python 标准库，不需要 pip install 任何东西。
"""

from __future__ import annotations

import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "lib" / "config" / "app_config.dart"
# 免费档和付费档是**两个不同域名**，用错会返回 "Invalid API key"（看起来像 Key 错了）。
# 实测 2026-11：免费档账号在 api.itick.org 上一律 Invalid，在 api-free.itick.org 上正常。
FREE_HOST = "api-free.itick.org"
PAID_HOST = "api.itick.org"
HOSTS = [FREE_HOST, PAID_HOST]


def read_config() -> tuple[str, list[tuple[str, str, str]]]:
    """从 app_config.dart 里抠出 token 与股票列表（不解析 Dart，只做最小正则）。"""
    if not CONFIG.exists():
        sys.exit(f"找不到配置文件：{CONFIG}")

    src = CONFIG.read_text(encoding="utf-8")

    m = re.search(r"static\s+const\s+String\s+token\s*=\s*'([^']*)'", src)
    if not m:
        sys.exit("配置文件里没找到 `static const String token = '...'`")
    token = m.group(1).strip()

    stocks: list[tuple[str, str, str]] = []
    for hit in re.finditer(
        r"StockConfig\(\s*code:\s*'([^']+)'\s*,\s*name:\s*'([^']+)'\s*,\s*region:\s*'([^']+)'",
        src,
    ):
        stocks.append((hit.group(1), hit.group(2), hit.group(3)))

    return token, stocks


def fetch(token: str, code: str, region: str, host: str) -> tuple[bool, dict | str]:
    query = urllib.parse.urlencode({"region": region, "code": code})
    req = urllib.request.Request(
        f"https://{host}/stock/quote?{query}",
        headers={"token": token, "Accept": "application/json"},
    )
    # 显式不用系统代理：这个接口在部分网络环境下走代理反而连不上（会返回空响应）
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=15) as resp:
            return True, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        try:
            return False, json.loads(body)
        except json.JSONDecodeError:
            return False, f"HTTP {e.code}: {body[:200]}"
    except Exception as e:  # 网络不可达 / 超时 / DNS
        return False, f"{type(e).__name__}: {e}"


def main() -> int:
    token, stocks = read_config()
    if len(sys.argv) > 1:
        token = sys.argv[1].strip()

    if not token or token.startswith("<"):
        print("✗ Token 还没填。")
        print(f"  打开 {CONFIG.relative_to(ROOT)}，把 '<YOUR_ITICK_TOKEN>' 换成你的 API Key。")
        print("  获取方式：https://itick.org 注册 → 控制台 → API Key")
        return 2

    print(f"Token : {token[:4]}…{token[-4:]}（长度 {len(token)}）")
    print(f"股票   : {len(stocks)} 只 —— " + "、".join(f"{n}({c}${r})" for c, n, r in stocks))

    # 先用第一只股票探测哪个域名认这个 Key（免费档 / 付费档）
    host = None
    if stocks:
        probe_code, probe_name, probe_region = stocks[0]
        for candidate in HOSTS:
            ok, payload = fetch(token, probe_code, probe_region, candidate)
            if ok and isinstance(payload, dict) and payload.get("code") == 0:
                host = candidate
                break
            if ok and isinstance(payload, dict) and "API key" not in str(payload.get("message", "")):
                # 域名认 Key，但股票代码有问题——先定下域名，让后面的逐只检查报具体错误
                host = candidate
                break
        if host is None:
            print()
            print(f"✗ 两个域名都拒绝了这个 Key（{FREE_HOST} / {PAID_HOST}）。")
            print("  1) 确认 Key 是从 https://itick.org/dashboard 的「API Keys」区块复制的；")
            print("  2) 确认账号已订阅套餐——**连免费套餐也要点一次「立即订阅」**，")
            print("     未订阅时 Key 就是无效的，报错和「Key 写错」完全一样；")
            print("  3) 刚订阅的话等 1~2 分钟再试，服务端开通有延迟。")
            return 1

    tier = "免费档" if host == FREE_HOST else "付费档"
    print(f"域名   : {host}（{tier}）")
    print()

    ok_count = 0
    for code, name, region in stocks:
        ok, payload = fetch(token, code, region, host)
        if not ok:
            if isinstance(payload, dict) and "message" in payload:
                msg = payload["message"]
                print(f"✗ {name} {code}${region}  →  {msg}")
                if "API key" in msg:
                    print("    Token 无效：确认复制完整（含大小写），或控制台里重新生成。")
                    return 1
            else:
                print(f"✗ {name} {code}${region}  →  {payload}")
                print(f"    网络层问题：确认能访问 {host}（公司网络/代理常拦这类域名）。")
                return 1
            continue

        data = payload.get("data") if isinstance(payload, dict) else None
        rcode = payload.get("code") if isinstance(payload, dict) else None
        if rcode not in (0, None) or not data:
            print(f"✗ {name} {code}${region}  →  服务端 code={rcode}，原始响应：{json.dumps(payload, ensure_ascii=False)[:300]}")
            print("    多半是 code/region 不对：A 股 region 只能是 SH 或 SZ，代码保留前导零、不带后缀。")
            continue

        row = data[0] if isinstance(data, list) and data else data
        last = row.get("ld")
        chp = row.get("chp")
        prev = row.get("p")
        stamp = row.get("t")
        flag = "✓" if last is not None else "?"
        if last is not None:
            ok_count += 1
        print(f"{flag} {name} {code}${region}  最新 {last}  涨跌 {chp}%  昨收 {prev}  t={stamp}")

    print()
    if ok_count == len(stocks) and stocks:
        print(f"全部 {ok_count} 只都拿到数据 —— Token 可用。")
        print(f"AppConfig.wsUrl 应为：wss://{host}/stock")
        print("下一步：./tool/build_apk.sh（64 位 + R8，构建后自动校验）")
        # 顺手核对字段名，避免 parser 与实际报文对不上
        ok, payload = fetch(token, stocks[0][0], stocks[0][2], host)
        if ok and isinstance(payload, dict) and payload.get("data"):
            sample = payload["data"][0] if isinstance(payload["data"], list) else payload["data"]
            keys = set(sample)
            wanted = {"s": "代码", "ld": "最新价", "ch": "涨跌额", "chp": "涨跌幅", "p": "昨收", "t": "时间戳"}
            missing = [f"{k}({v})" for k, v in wanted.items() if k not in keys]
            print(f"\n实际返回字段：{', '.join(sorted(keys))}")
            if missing:
                print(f"⚠ 解析器期望但本次未返回：{', '.join(missing)}")
                print("  非致命——REST 与 WebSocket 报文字段可能不同，以 WebSocket 为准。")
            else:
                print("✓ parser 期望的字段都在，字段映射没问题。")
        return 0

    print(f"只成功 {ok_count}/{len(stocks)} 只。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
