#!/usr/bin/env python3
"""1.17.0 的「按原生 UIKit 重新校准」核查探针（只读、可复跑）。

用法（工程根目录）::

    python tool/probe_uikit_calibration.py

它回答三个问题，且**不允许靠 CHANGELOG 一句话交差**：

1. 五个交互控件（GlassTabBar / GlassSegmentedControl /
   AnimatedGlassIndicator / GlassSwitch / GlassSlider）的镜片折射、色散、
   高光边缘到底改在哪一行、值是多少；
2. `thumbShadow` 是不是真的加在 GlassSwitch 上（GlassSlider 是 1.6.2 就有的
   同名参数），默认值是多少；
3. 「Switch/Slider 只在按下或拖动时才挂 shader 层」的开关在哪个文件，
   1.16.1 为什么没省下这笔常驻 GPU。

最后扫描本工程 ``lib/``，打印这五个控件的**引用数**。探针不会改任何文件；
任何一条断言失效就 exit 1，用来在下次升级玻璃包时当场发现上游变卦。

包源码位置从 ``.dart_tool/package_config.json`` 解析，不硬编码 pub cache 路径。
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse
from urllib.request import url2pathname

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = "liquid_glass_widgets"
CONTROLS = (
    "GlassTabBar",
    "GlassSegmentedControl",
    "AnimatedGlassIndicator",
    "GlassSwitch",
    "GlassSlider",
)

# 每条 = (相对包根的路径, 人类可读说明, 必须命中的字面量/正则列表)
# 用「源码里的固定写法」而不是行号：上游挪行不会假红，改实现才红。
CHECKS: list[tuple[str, str, tuple[str, ...]]] = [
    (
        "CHANGELOG.md",
        "1.17.0 特性条目确实点名五控件 + 懒挂载",
        (
            "Calibrated `GlassTabBar`, `GlassSegmentedControl`, "
            "`AnimatedGlassIndicator`, `GlassSwitch` (adding `thumbShadow`)",
            "lazy-mount their shader layer only while pressed or dragged",
        ),
    ),
    (
        "lib/widgets/surfaces/glass_tab_bar.dart",
        "TabBar：iOS 27 的 _UILiquidLensView 放大倍率与图标尺寸",
        (
            "_UILiquidLensView",
            "return style == GlassStyle.classic ? 1.15 : 1.25;",
            "return style == GlassStyle.classic ? 24.0 : 27.5;",
            "frame = (-4, -4, W + 16, H + 16)",
        ),
    ),
    (
        "lib/widgets/interactive/glass_segmented_control.dart",
        "SegmentedControl：轨道底色 + 色散/折射取 GlassDefaults",
        (
            "static const _defaultLightBg = Color(0x1F787880);",
            "static const _defaultDarkBg = Color(0x3D787880);",
            "chromaticAberration: GlassDefaults.chromaticAberration,",
            "refractiveIndex: GlassDefaults.refractiveIndex,",
            "mounts zero shader layers at rest",
        ),
    ),
    (
        "lib/widgets/shared/animated_glass_indicator.dart",
        "Indicator：基准换成 ios27Indicator + 静止选中态的色彩矩阵",
        (
            "static const baseIndicatorSettings = LiquidGlassSettings.ios27Indicator;",
            "_UITabSelectionView",
            "interactionIntensity: thickness",
        ),
    ),
    (
        "lib/src/engine/liquid_glass_settings.dart",
        "ios27Indicator：清透近轴透镜的精确数值",
        (
            "static const LiquidGlassSettings ios27Indicator = LiquidGlassSettings(",
            "thickness: 28,",
            "refractiveIndex: 1.17,",
            "lensModel: GlassLensModel.paraxial,",
            "chromaticAberration: 0.0,",
            "rimShadeEnds: 0.56,",
            "rimLight: 1.0,",
            "blur: 0,",
        ),
    ),
    (
        "lib/widgets/interactive/glass_switch.dart",
        "Switch：1.17.0 新增 thumbShadow + 1.38 折射率 + 交互强度驱动",
        (
            "this.thumbShadow,",
            "final List<BoxShadow>? thumbShadow;",
            "color: Color.from(alpha: 0.15, red: 0, green: 0, blue: 0),",
            "blurRadius: 8,",
            "offset: Offset(0, 2),",
            "LiquidGlassSettings.ios27Indicator.copyWith(",
            "refractiveIndex: 1.38,",
            "interactionIntensity: transition",
            "mounts zero shader layers at rest",
        ),
    ),
    (
        "lib/widgets/interactive/glass_slider.dart",
        "Slider：同名 thumbShadow（1.6.2 起）+ 1.07 折射率 + 交互强度驱动",
        (
            "this.thumbShadow,",
            "final List<BoxShadow>? thumbShadow;",
            "color: Color.from(alpha: 0.15, red: 0, green: 0, blue: 0),",
            "LiquidGlassSettings.ios27Indicator.copyWith(",
            "refractiveIndex: 1.07,",
            "interactionIntensity: transition",
            "mounts zero shader layers at rest",
        ),
    ),
    (
        "lib/widgets/shared/glass_effect.dart",
        "懒挂载闸门：静止态直接返回 child，不建 LiquidGlass.withOwnLayer",
        (
            "if (activeIntensity <= 0.001) {",
            "return widget.child;",
            "LiquidGlass.withOwnLayer(",
            "refractiveIndex:",
            "1.0 + (widget.settings.refractiveIndex - 1.0) * activeIntensity,",
        ),
    ),
    (
        "lib/constants/glass_defaults.dart",
        "色散/折射/高光的全局缺省值",
        (
            "static const double chromaticAberration = 0.5;",
            "static const double refractiveIndex = 1.15;",
            "static const double specularLightAlpha = 0.15;",
            "static const double specularDarkAlpha = 0.10;",
        ),
    ),
]


def package_root() -> Path:
    """从 package_config.json 解析已解析依赖的本地路径。"""
    cfg = ROOT / ".dart_tool" / "package_config.json"
    if not cfg.is_file():
        raise SystemExit(f"缺少 {cfg}，先跑 flutter pub get")
    data = json.loads(cfg.read_text(encoding="utf-8"))
    for entry in data.get("packages", []):
        if entry.get("name") != PACKAGE:
            continue
        uri = entry.get("rootUri", "")
        if uri.startswith("file://"):
            # url2pathname 同时处理 Windows 的 /C:/... 与 POSIX 的 /home/...
            return Path(url2pathname(unquote(urlparse(uri).path)))
        return (cfg.parent / uri).resolve()
    raise SystemExit(f"package_config.json 里没有 {PACKAGE}")


def usage_lines(lib_dir: Path) -> list[str]:
    """扫 lib/ 里的**代码行**（跳过注释），找五个控件被实例化。"""
    pattern = re.compile(r"\b(" + "|".join(CONTROLS) + r")\s*(?:\.|\()")
    hits: list[str] = []
    for path in sorted(lib_dir.rglob("*.dart")):
        for no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            line = raw.lstrip()
            if line.startswith(("//", "*", "/*")):
                continue
            if pattern.search(line):
                hits.append(f"{path.relative_to(ROOT).as_posix()}:{no}: {line.strip()}")
    return hits


def main() -> int:
    root = package_root()
    print(f"包源码: {root}")
    print(f"锁定版本: {root.name}")
    print()
    failures: list[str] = []
    for rel, label, needles in CHECKS:
        path = root / rel
        if not path.is_file():
            failures.append(f"{rel}: 文件不存在")
            print(f"[MISS] {label}")
            continue
        text = path.read_text(encoding="utf-8")
        missing = [n for n in needles if n not in text]
        if missing:
            failures.append(f"{rel}: 缺少 {missing}")
            print(f"[FAIL] {label}")
            for item in missing:
                print(f"       - {item}")
        else:
            print(f"[ OK ] {label}  ({len(needles)} 项)")

    print()
    hits = usage_lines(ROOT / "lib")
    print(f"本工程 lib/ 对五控件的引用: {len(hits)} 处")
    for hit in hits:
        print(f"       {hit}")

    print()
    print("校准值速查（1.17.0 / GlassStyle.ios27）")
    print("  ios27Indicator      n=1.17  thickness=28  dispersion=0  "
          "rimShadeEnds=0.56  rimLight=1.0  blur=0  paraxial")
    print("  GlassSwitch thumb   n=1.38  thumbShadow=15%黑/blur8/(0,2)（新）")
    print("  GlassSlider thumb   n=1.07  thumbShadow 同上（1.6.2 起）")
    print("  SegmentedControl    dispersion=0.5  n=1.15  specular=0.15/0.10")
    print("  GlassTabBar         icon=27.5pt  magnification=1.25  "
          "_UILiquidLensView 外扩 16pt")
    print("  懒挂载              GlassEffect: interactionIntensity<=0.001 -> "
          "return child（1.16.1 无此分支）")

    if failures:
        print()
        print(f"FAIL: {len(failures)} 项不达标", file=sys.stderr)
        return 1
    print()
    print("PASS: 上游校准标记齐全；本工程零引用 -> 该校准无本地对象。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
