#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""校验构建产物：架构、R8 保留类、包里到底是哪套数据源。

为什么需要它：改完配置忘记重新打包，是「改了没生效」最常见的原因；
而 R8 把 FlutterJNI 混淆掉，则会得到一个「装得上但一启动就崩」的包。
这两件事都没法靠肉眼发现，只能解包查。

关于数据源检查：Dart 的 AOT 编译从 `main()` 做全程序树摇，没被任何可达路径
引用到的类（连同它的字符串常量）会被整个删掉。所以查 `libapp.so` 里有没有
某个域名，等价于查「这套数据源的代码还在不在运行时里」——
这正是「切源到底有没有真的打进去」最硬的证据，比看源码可靠。

用法：
    python tool/verify_apk.py [apk 路径]
默认检查 build/app/outputs/flutter-apk/app-release.apk
"""

from __future__ import annotations

import os
import re
import sys
import zipfile

DEFAULT_APK = "build/app/outputs/flutter-apk/app-release.apk"
CONFIG = "lib/config/app_config.dart"

# 目标 API 等级：37 = Android 17。
#
# 钉成常量而不是「取最新」：升 targetSdk 不只是改个数字，它会把大屏方向、
# 局域网权限、证书透明度这些行为变更一起打开。所以「谁在什么时候把它
# 降回去了」必须当场暴露——最典型的事故是某次 Flutter 升级后有人把
# `targetSdk` 改回 `flutter.targetSdkVersion`（默认仍是 36），编译一切正常，
# 只有这个检查看得出来。
EXPECT_TARGET_SDK = 37

OK = "✓"
BAD = "✗"


def _candidate_sdks() -> list[str]:
    """候选 SDK 根目录，按可信度排序。

    `android/local.properties` 排第一：那是**本项目实际在用**的 SDK。
    本机上 `ANDROID_SDK_ROOT` 指向的是另一个残缺目录（只有 platforms，
    没有 build-tools），先查环境变量会得到一个「找不到 aapt2」的假结论。
    """
    out: list[str] = []
    if os.path.exists("android/local.properties"):
        with open("android/local.properties", encoding="utf-8") as f:
            for line in f:
                if line.startswith("sdk.dir="):
                    # 常见写法 C://Android//sdk，双斜杠在 join 后会变成怪路径
                    out.append(line.split("=", 1)[1].strip().replace("//", "/"))
                    break
    for env in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        value = os.environ.get(env)
        if value:
            out.append(value.replace("\\", "/").replace("//", "/"))
    return out


def _find_aapt2() -> str | None:
    """找 aapt2：PATH → local.properties → ANDROID_HOME/ANDROID_SDK_ROOT。"""
    import shutil

    hit = shutil.which("aapt2")
    if hit:
        return hit

    for sdk in _candidate_sdks():
        build_tools = os.path.join(sdk, "build-tools")
        if not os.path.isdir(build_tools):
            continue
        for version in reversed(sorted(os.listdir(build_tools))):  # 取最高版本那套
            for exe in ("aapt2.exe", "aapt2"):
                path = os.path.join(build_tools, version, exe)
                if os.path.exists(path):
                    return path
    return None


def read_target_sdk(apk: str) -> int | None:
    """读 APK 的 targetSdkVersion。

    APK 里的 AndroidManifest.xml 是二进制 AXML，标准库解析不了，只能借
    aapt2。找不到 aapt2 时返回 None —— 由调用方决定是警告还是失败，不让
    「工具缺失」冒充「检查通过」。
    """
    import subprocess

    aapt2 = _find_aapt2()
    if aapt2 is None:
        return None
    try:
        out = subprocess.run(
            [aapt2, "dump", "badging", apk],
            capture_output=True,
            text=True,
            timeout=120,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.search(r"targetSdkVersion:'(\d+)'", out)
    return int(m.group(1)) if m else None


def _read_cleartext_policy(apk: str, res_entries: list[str]) -> str | None:
    """读出包里那份 network security config 的 cleartextTrafficPermitted 取值。

    资源路径会被 AGP 缩短（res/xml/network_security_config.xml → res/8G.xml），
    靠文件名找必然失效；所以先按字符串池定位候选，再用 aapt2 解出真实取值。
    返回 "true" / "false" / None（读不到，例如缺 aapt2）。
    """
    import subprocess

    aapt2 = _find_aapt2()
    if aapt2 is None:
        return None
    for entry in res_entries:
        try:
            out = subprocess.run(
                [aapt2, "dump", "xmltree", "--file", entry, apk],
                capture_output=True,
                text=True,
                timeout=120,
            ).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        m = re.search(r"cleartextTrafficPermitted=[\"']?(\w+)", out)
        if m:
            return m.group(1)
    return None


def read_config_token() -> str:
    """从 app_config.dart 里读当前 Token，避免在脚本里硬编码密钥。"""
    try:
        with open(CONFIG, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return ""
    m = re.search(r"static const String token\s*=\s*'([^']*)'", text)
    return m.group(1) if m else ""


def main(argv: list[str]) -> int:
    apk = argv[1] if len(argv) > 1 else DEFAULT_APK
    if not os.path.exists(apk):
        print(f"{BAD} 找不到 {apk}，先跑 tool/build_apk.sh")
        return 1

    z = zipfile.ZipFile(apk)
    names = z.namelist()
    failed: list[str] = []
    warned: list[str] = []

    size_mb = os.path.getsize(apk) / 1048576
    raw_mb = sum(i.file_size for i in z.infolist()) / 1048576
    print(f"包体   : {apk}")
    print(f"        {size_mb:.2f} MB（解压后 {raw_mb:.2f} MB）")

    # ---- 1. 架构：必须只有 64 位 ----
    abis = sorted({n.split("/")[1] for n in names if n.startswith("lib/")})
    expect = ["arm64-v8a"]
    ok = abis == expect
    print(f"\n架构   : {OK if ok else BAD} {abis}")
    if not ok:
        failed.append(f"架构应为 {expect}，实际 {abis}（32 位会让包大 12MB 以上）")

    # ---- 2. 目标 API 等级：必须是 Android 17 ----
    target_sdk = read_target_sdk(apk)
    if target_sdk is None:
        print(f"\n目标   : ! 读不到 targetSdkVersion（没找到 aapt2），跳过")
        warned.append("未能校验 targetSdkVersion —— 确认 android/app/build.gradle.kts")
    else:
        ok = target_sdk == EXPECT_TARGET_SDK
        print(
            f"\n目标   : {OK if ok else BAD} targetSdk {target_sdk}"
            f"（期望 {EXPECT_TARGET_SDK} = Android 17）"
        )
        if not ok:
            failed.append(
                f"targetSdk 是 {target_sdk}，期望 {EXPECT_TARGET_SDK}："
                "检查 android/app/build.gradle.kts 是否被改回 flutter.targetSdkVersion"
            )

    # ---- 3. R8 是否真的执行 ----
    dex = z.read("classes.dex") if "classes.dex" in names else b""
    dex_kb = len(dex) / 1024
    r8_ok = dex_kb < 1500  # 未压缩的原始 dex 若超过 1.5MB，基本上是没开 R8
    print(
        f"R8     : {OK if r8_ok else BAD} classes.dex {dex_kb:.0f} KB"
        f"（未开 R8 约 6000 KB）"
    )
    if not r8_ok:
        failed.append("dex 过大，R8 可能没生效：检查 isMinifyEnabled / isShrinkResources")

    # ---- 3a. ADPF 会话代码必须在包里 ----
    #
    # `lib/utils/adpf.dart` + `AdpfSession.kt` 是应用层自己接的 ADPF（引擎 3.47.9
    # 还没有，见 README 二·四十六）。Dart 侧完全靠通道，平台侧被剥掉的话只会拿到
    # `MissingPluginException` 然后**静默降级**——不崩、不报错、看起来一切正常。
    # R8 不会重命名系统类，所以类名字符串在不在 dex 里就是「代码还在不在」的证据。
    adpf_ok = b"PerformanceHintManager" in dex
    print(
        f"ADPF   : {OK if adpf_ok else BAD} "
        f"性能提示会话{'已打进包' if adpf_ok else '不在包里（Dart 侧会静默降级）'}"
    )
    if not adpf_ok:
        failed.append(
            "dex 里找不到 PerformanceHintManager：AdpfSession 被 R8 剥掉了，"
            "ADPF 会静默降级成「没接」"
        )

    # ---- 3b. Baseline Profile 必须在包里，自己写的那几条得活过 R8 ----
    #
    # 依赖 AAR 自带的 profile 由 AGP 自动合并（本项目只有依赖时实测 926 B），
    # `android/app/src/main/baseline-prof.txt` 是我们补的 Flutter 胶水层
    # （FlutterActivity / FlutterEngine / FlutterLoader / FlutterJNI / DartExecutor）。
    # 少了它，冷启动那几十个 Java 方法只能走解释执行。
    prof_name = "assets/dexopt/baseline.prof"
    prof = z.read(prof_name) if prof_name in names else b""
    print(f"Profile: {OK if prof else BAD} baseline.prof {len(prof)} B（仅依赖时为 926 B）")
    if not prof:
        failed.append(f"包里没有 {prof_name}：Baseline Profile 没打进去")

    combined = os.path.join(
        "build", "app", "intermediates", "combined_art_profile",
        "release", "compileReleaseArtProfile", "baseline-prof.txt",
    )
    if os.path.exists(combined):
        with open(combined, encoding="utf-8", errors="replace") as f:
            profile_text = f.read()
        kept = "Lio/flutter/embedding/android/FlutterActivity;" in profile_text
        print(
            f"        {OK if kept else BAD} 自写规则经 R8 改写后仍在（FlutterActivity）"
        )
        if not kept:
            failed.append(
                "自写的 baseline-prof.txt 经 R8 后一条不剩：方法签名可能随 Flutter "
                "版本变了，按新的 dex 重新取签名"
            )

    # ---- 3b. 编译器元数据不该出现在包里 ----
    #
    # `kotlin/*.kotlin_builtins` 是给编译器/IDE 读的声明文件，运行期没有任何
    # 代码加载它；R8 只剔 class，不剔这类资源，所以要靠 packaging.resources
    # 点名排除。剔漏了不会崩，只是白占 53KB —— 正是最容易默默回退的一类。
    junk_names = {
        "kotlin-tooling-metadata.json",
        "DebugProbesKt.bin",
    }
    junk = [
        i for i in z.infolist()
        if i.filename.startswith("kotlin/") or i.filename in junk_names
    ]
    junk_kb = sum(i.file_size for i in junk) / 1024
    print(
        f"冗余   : {OK if not junk else BAD} 编译器元数据 {junk_kb:.0f} KB"
        f"（{len(junk)} 项）"
    )
    if junk:
        failed.append(
            "包里带着 kotlin/*.kotlin_builtins 等编译期资源：检查 "
            "android/app/build.gradle.kts 的 packaging.resources.excludes"
        )

    # ---- 3c. 传输层：清单必须挂 networkSecurityConfig，且配置里真的禁了明文 ----
    #
    # 为什么查二进制清单而不是查源码：源码写了但没挂到 <application> 上，
    # 编译一样过、装上也一样跑，只有这里看得出来。资源路径会被 AGP 缩短
    # （res/xml/network_security_config.xml → res/4B.xml），所以不能按文件名找，
    # 只能在清单字符串池和 res/*.xml 里找属性名。
    # 注意：这份配置只管原生 HTTP 栈，管不到 dart:io 的行情请求 —— 那层由
    # lib/services/rest_client.dart 的 requireHttps() 强制（见 transport_security_test）。
    manifest_raw = z.read("AndroidManifest.xml")
    nsc_in_manifest = "networkSecurityConfig".encode("utf-16-le") in manifest_raw
    cleartext_attr = "cleartextTrafficPermitted"
    nsc_resources: list[str] = []
    for n in names:
        if not (n.startswith("res/") and n.endswith(".xml")):
            continue
        body = z.read(n)
        if (
            cleartext_attr.encode("utf-8") in body
            or cleartext_attr.encode("utf-16-le") in body
        ):
            nsc_resources.append(n)
    policy = _read_cleartext_policy(apk, nsc_resources)

    if policy is None:
        tls_ok = None  # 读不出取值：不冒充通过，降级为警告
    else:
        tls_ok = nsc_in_manifest and policy == "false"

    print(
        f"传输   : {OK if tls_ok else (BAD if tls_ok is False else '?')} 禁明文配置"
        f"（清单{'已挂' if nsc_in_manifest else '未挂'}，"
        f"cleartext={policy or '未检出'}）"
    )
    if not nsc_in_manifest:
        failed.append(
            "清单没有 networkSecurityConfig —— 检查 "
            "android/app/src/main/AndroidManifest.xml 的 <application> 属性"
        )
    elif not nsc_resources:
        failed.append(
            "清单挂了 networkSecurityConfig 但包里找不到对应资源："
            "检查 res/xml/network_security_config.xml 是否被 shrinkResources 剔掉"
        )
    elif policy == "true":
        failed.append(
            "network security config 允许了明文（cleartextTrafficPermitted=true）"
        )
    elif policy is None:
        warned.append(
            "未能校验 cleartextTrafficPermitted 的取值（缺 aapt2？）——"
            "源码侧由 test/transport_security_test.dart 守着"
        )

    # ---- 4. JNI 关键类必须被保留，否则 release 包启动即崩 ----
    for cls in (
        b"Lio/flutter/embedding/engine/FlutterJNI;",
        b"Lio/flutter/embedding/android/FlutterActivity;",
    ):
        ok = cls in dex
        print(f"       : {OK if ok else BAD} {cls.decode().strip('L;').replace('/', '.')}")
        if not ok:
            failed.append(
                f"{cls.decode()} 被 R8 移除/重命名 —— release 包会启动崩溃，"
                "检查 android/app/proguard-rules.pro"
            )

    # ---- 5. Dart 侧：包里到底装的是哪套数据源 ----
    so_name = next((n for n in names if n.endswith("arm64-v8a/libapp.so")), None)
    if so_name is None:
        print(f"\n{BAD} 找不到 arm64-v8a/libapp.so")
        return 1
    so = z.read(so_name)
    so_mb = len(so) / 1048576
    print(f"Dart   : libapp.so {so_mb:.2f} MB")

    # 必须在包里：当前主力（新浪）+ 备份（腾讯）的地址，被树摇掉就等于白打包
    checks: list[tuple[str, bool, str]] = [
        (
            "新浪行情域 hq.sinajs.cn",
            b"hq.sinajs.cn" in so,
            "主力源没打进包，等于切源没生效",
        ),
        (
            "新浪 Referer finance.sina.com.cn",
            b"finance.sina.com.cn" in so,
            "缺 Referer 新浪会回 403（空响应），行情全丢",
        ),
        (
            "新浪目录接口 Market_Center.getHQNodeData",
            b"Market_Center.getHQNodeData" in so,
            "「换股票」拉不到目录",
        ),
        (
            "腾讯备用域 qt.gtimg.cn",
            b"qt.gtimg.cn" in so,
            "备用内核没打进包，新浪一挂就没有兜底",
        ),
        (
            "走势日线端点 quotes.sina.cn",
            b"quotes.sina.cn" in so,
            "详情页的分时/日K不会出图（数据层被摇掉了）",
        ),
        (
            "走势备用端点 web.ifzq.gtimg.cn",
            b"web.ifzq.gtimg.cn" in so,
            "走势的备用内核没打进包，新浪 K 线一挂图就空",
        ),
        (
            "目录总数端点 getHQNodeStockCount",
            b"Market_Center.getHQNodeStockCount" in so,
            "少了它就只能串行翻页，目录下载从 7s 变回 70s",
        ),
        (
            "搜索端点 searchapi.eastmoney.com",
            b"searchapi.eastmoney.com" in so,
            "「换股票」的输入即搜不可用，只能等目录下完",
        ),
        (
            "美股补位域 push2.eastmoney.com",
            b"push2.eastmoney.com" in so,
            "美股补位源没打进包：新浪一挂，美股卡就只剩最后一张快照",
        ),
        (
            "美股补位批量端点 ulist.np",
            b"ulist.np" in so,
            "端点被树摇/改坏：补位请求打到一个不存在的路径上，静默全失败",
        ),
        (
            "iTick 推送链已树摇（api-free.itick.org 不在包里）",
            b"api-free.itick.org" not in so,
            "release 包里还有 iTick 代码 —— 若确实要切回它，请同步更新本脚本和 README",
        ),
    ]

    # 只提示不失败：token 常量是 const，只要 `hasToken` 被页面引用着就会留在二进制里。
    # 它已经不参与运行（iTick 链路整个被树摇），但确实是包里的死数据。
    token = read_config_token()
    if token and not token.startswith("<") and token.encode() in so:
        warned.append(
            f"内置 Token 仍留在包里（{token[:6]}…{token[-4:]}）："
            "iTick 代码已被树摇，它不参与运行，属于死数据"
        )

    print()
    for label, ok, why in checks:
        print(f"数据源 : {OK if ok else BAD} {label}")
        if not ok:
            failed.append(f"{label} —— {why}")

    for msg in warned:
        print(f"提示   : ! {msg}")

    # ---- 结论 ----
    print()
    if failed:
        print(f"{BAD} 校验未通过，{len(failed)} 个问题：")
        for i, msg in enumerate(failed, 1):
            print(f"  {i}. {msg}")
        return 1

    print(
        f"{OK} 全部通过：64 位单架构、targetSdk {EXPECT_TARGET_SDK}（Android 17）、"
        "R8 生效且保留了 JNI 类、ADPF 会话在包里、新浪主力 + 腾讯备份 + 美股补位已打进包、"
        "iTick 推送链不在运行时"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
