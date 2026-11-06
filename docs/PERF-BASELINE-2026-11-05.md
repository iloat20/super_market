# 性能基线台账 · 2026-11-05（收盘时段采集）

> 补上 PERF-AUDIT-2026-11-05 指出的缺口：「没有当前性能基线」与「前台空闲无
> 有效数据」。判定一律出自 `tool/perf_baseline.dart`（官方帧预算 1000/hz，
> jank 只记录不判定，**无同条件基线不声称更优**）。
> 原始采样与 JSON 归档在 `build/perf/`（不入库）。

## 采集条件

| 项 | 值 |
| --- | --- |
| 设备 | OPPO PLJ110（Find X9）/ Android 17 / 1256×2760，90Hz 档滚动回落 60Hz、滑动投 120Hz |
| 构建 | `release` + `--dart-define=PERF_LOG=true`，arm64 单 ABI，代码 = 审查修复后（commit 62cccef 之后） |
| 口径说明 | 历史滚动基线是 profile 口径；本次改用 **release 口径**（见「工具与踩坑」③）——baselineKey 已含 build 字段，两类记录不可直接比大小 |
| 时段 | 北京周四 22:00–22:12：A/港已收盘，美股盘前（22:30 开盘） |

## 一、冷启动（am start -W，release）

| # | TotalTime |
|---|---|
| 1 | 403 ms |
| 2 | 0（warm start，无效样本，剔除） |
| 3 | 387 ms |
| 4 | 426 ms |
| 5 | 358 ms |

**有效中位 403ms**。历史参照 320ms×3（2026-11-05 09:40，同机 release）——同量级；
另有一组 2919/1845ms 的样本，采于 adb 密集操作期间，判为噪声作废。
目标 ≤1.2s，**达标（余量 ~3×）**。

## 二、列表滚动帧率（scroll-7stocks，连滑 5 次，判定 ✓ 通过）

| 指标 | 值（120Hz，预算 8.33ms） |
|---|---|
| build | p50 1.1 / p90 1.3 / max 2.0，jank 0 |
| **raster** | **p50 4.1 / p90 4.7 / max 5.3，jank 0** |
| 样本 | 87 帧（探针窗口） |

历史参照 4.6ms@120Hz（profile 口径）——同量级，玻璃组共享背景读取的
结构优化仍然成立。

## 三、前台静置空闲（收盘，92s 窗口，判定 ✗ 不合格——但请读解读）

| 指标 | 样本 1 | 样本 2 |
|---|---|---|
| build | p50 3.9 / p90 4.8 | p50 3.8 / p90 4.8 |
| **raster** | **p50 12.3 / p90 13.4 / max 45.6** | **p50 12.5 / p90 13.1 / max 17.4** |
| jank | 34/41 帧 | 39/41 帧 |

**解读（重要，别只看 fail）**：收盘后帧源只剩秒表 1Hz，帧率低到无流畅性
可言；raster ~12.5ms 的含义是**每一帧都在重跑全屏玻璃模糊**——`BackdropFilter`
不缓存，哪怕只重绘秒表文字层，合成时玻璃组的 blur 也要整遍重来。
所以这不是「卡顿」，是**功耗信号**：GPU 每秒被拉起跑 ~12ms，LTPO 面板
无法降频。优化方向（记录，未实施）：空闲帧的玻璃模糊结果可缓存 / 秒表层
与玻璃组做图层隔离复核。

**顺带推翻旧数据**：README 曾记「静置 30s 帧数 0」——那是 gfxinfo 口径
失效（HWUI 统计不到 Flutter 帧）。探针口径下静置 clearly 有帧（41 帧/40s）。

## 四、内存（启动后静置 5s）

| 项 | 值 |
|---|---|
| TOTAL PSS | **112 MB** |
| TOTAL SWAP PSS | 42 MB |
| TOTAL RSS | 174 MB |

历史参照前台 PSS 134MB——同量级。

## 五、盘中持续刷新帧率 —— **缺口（用户指示今晚不等开盘）**

收盘后 `shouldApplyQuote` 拦掉同值快照帧，列表无重绘，「盘中」数据必须
在真实交易时段采。自选含美股（PDD/FISV），两个补采窗口任选：

- **A 股**：交易日 09:30–15:00
- **美股**：北京时间 21:30–次日 04:00（冬令时）

补采命令（手机连 adb、App 前台打开、**不滑动**——纯轮询驱动的帧）：

```bash
ADB=/c/Android/sdk/platform-tools/adb.exe
"$ADB" shell am force-stop supermarket.app
"$ADB" shell am start -n supermarket.app/.MainActivity
sleep 8 && "$ADB" logcat -c && sleep 90
"$ADB" logcat -d -s flutter | grep "\[perf\]" > build/perf/perf-intraday.log
DART=/c/Users/Administrator/Downloads/flutter/bin/dart
"$DART" tool/perf_baseline.dart --device PLJ110 --build release \
  --scenario intraday-polling --input build/perf/perf-intraday.log
```

采到后把数字补进本节，并对照第三节静置数字：预期 build 增量来自卡片
文字层重绘、raster 仍是全屏玻璃模糊的 ~12ms——若盘中 raster 显著高于
12ms 才是新的问题。

## 六、工具与踩坑（本次修复）

1. **包名漂移**：`measure_frames.sh` / `perf_bench.sh` 的 `PKG` 还停在
   `com.example.super_market`（改包名批次漏改）→ 已修为 `supermarket.app`；
2. `measure_frames.sh` 参数化 `BUILD`（profile/release），本次全部用
   release+PERF_LOG 采集；
3. **release 构建会清掉 flutter-apk 下其它 variant 的产物**——profile.apk
   在 release 构建完成后消失，安装脚本拿不到文件；
4. **profile 包是 debug 签名**，无法 `install -r` 覆盖正式签名的装机包
   （强装需卸载 = 丢用户自选数据，已避免）→ 改走 release+PERF_LOG：
   探针输出走 `debugPrint`（release 照样打印，AppLog 注释自证），注册条件
   只看 dart-define，与历史 release 数字同口径；
5. `adb install` 的输出不要 `tail -1` 吞——失败（stat 失败/签名冲突）会被
   静默，后续所有数字测的是旧包。
6. **采前必查设备内存压力**（2026-11-06 新增）：该机常态 `Mem 11.0G/11.3G used`、
   `swap 6.9G`、`erm_reclaimd` 20–30% CPU。此时单轮 `am start -W` 是随机数
   （实测同款构建可差 3 倍：345ms vs 1060ms）。协议：`adb shell top -n 1 -b -m 6 -s 9`
   看到 `erm_reclaimd` / `system_server` 高占用就换时段，或改用「同源 A/B + 交叉轮测」。
7. 冷启动**不要跟历史绝对值比**，只比同时段 A/B——403ms（11-05 收盘）与 345ms
   （11-06 盘中）同为 stored 构建，差异纯属设备状态。

## 七、功耗复核与归因实验（2026-11-06 上午，真机 A/B）

> 针对「空闲帧玻璃模糊缓存 / 图层隔离复核」的优化方向。先复核、后归因、
> 再决策——结论：**无需优化，现状无害**。以下全部为 release+PERF_LOG
> 静置窗口实测（临时改动逐个 revert，未进产品）。

### 复核结论（先于实验成立）

1. **无隐藏高频帧源**：静置唯一活跃帧源是秒表 1Hz（40 帧/39s 数据互证）；
   角标 30s、FreshnessTicker 单次、太极 tick 驱动收盘静止、快照被
   `shouldApplyQuote` 拦——清单逐项核对无遗漏；
2. **图层隔离无缺失**：Aurora / HeaderFade / 页头 / 卡片内容层各有
   RepaintBoundary，玻璃与内容分层有 paint_isolation_test 守着；
3. **GPU 占空比 ≈ 1.25%**（12.5ms / 1000ms × 1Hz）——PERF-AUDIT P1-5
   担心的「空闲功耗」在当前 tick 驱动架构下**实际不存在**。

### 归因实验（每项只改一个变量）

| 实验 | 改动 | 静置 raster p50 | 结论 |
|---|---|---|---|
| 现状 | — | 12.3–12.5 @120Hz / 12.1–12.4 @90Hz | 基线；**成本与面板档位无关**（纯 blur 工作量） |
| ② | `quality: standard` | 12.0–12.1 @90Hz | 成本**不在** premium 着色器——在 `BackdropFilter` 的模糊本身（standard 同样走 blur） |
| ③ | 去掉 `GlassBackdropGroup` | **18.6–19.3** @120Hz | **组省 ~35%**（6 面玻璃共享一次 backdrop 读 + blur 只跑一次）——组必须保留 |
| ④ | 列表层外包 RepaintBoundary | 12.1–12.4 @90Hz | **无效**——存在 `BackdropFilterLayer` 时 Impeller 放弃 partial repaint，全帧重绘 |

包源码佐证（liquid_glass_widgets-1.16.1，`glass_backdrop_group_boundary.dart`）：
共享 backdrop 读是 **per frame** 语义（"Impeller copies a shared backdrop once
per frame"）——**无跨帧缓存**，且 `opensRenderPassBelow` 把 `RenderBackdropFilter`
列为强制独立 render pass 的节点。

### 最终判定

静置/盘中每秒一帧的 ~12ms 是**引擎级机制**（BackdropFilter → 全帧重绘），
Flutter/Dart 层无法消除；占空比 1.25% 无感知、无害 → **推荐：接受现状，
不做改动**（本次未改任何产品代码）。

若未来仍要压（均需先拍板，无一零成本）：

| 路径 | 代价 |
| --- | --- |
| 秒表 1s → 1min 跳 | 产品决策（秒表是既定特性），空闲帧 1Hz→1/60Hz |
| 玻璃改静态缓存模糊（ImageFiltered 用缓存的 ui.Image） | 滚动时背景实时折射消失——重大视觉决策 |
| 跟随 Impeller 上游的 backdrop filter 缓存改进 | 被动，升级时按 dep-liquid-glass 台账 SOP 验证 |

次要发现：实验④ 0 样本假阳性一次——焦点被系统铃声选择器压住（用户在用
手机），App 实际在后台；采集前应先确认 `mCurrentFocus` 是本应用。
