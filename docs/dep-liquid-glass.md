# 依赖台账 · liquid_glass_widgets（上游策略）

> review-2026-11-05 路线图「长期」项的落地。原则与 `tool/verify_apk.py` 钉
> targetSdk 37 相同：**谁动了它，必须当场暴露，并留下走查记录。**

## 一、当前状态（2026-11-05 核对）

| 项 | 值 |
| --- | --- |
| pubspec 约束 | `^1.16.1`（`pubspec.yaml`） |
| lock 锁定 | `1.16.1`（`pubspec.lock`，已入库；sha256 `959da060…`） |
| 上游最新 | **1.16.1**（2026-11-05 与 pub.dev 核对，6 天前发布——当前即在最新版） |
| 上游仓库 | https://github.com/sdegenaar/liquid_glass_widgets （MIT） |
| SDK 约束 | Flutter ≥ 3.41 / Dart ≥ 3.5（本机 3.47.9，满足） |
| 自身依赖 | **零**第三方包（纯 Flutter SDK + GLSL shader） |

## 二、为什么选它（不换的理由）

1. **视觉不可替代**：iOS 27 液态玻璃的 premium 档（完整折射 + rim + 色散）
   是自绘 CustomPaint 付不起的成本（着色器工程量大，且真机观感已验证）；
2. **干净**：MIT、零第三方依赖、六平台；标准档（standard 2D）刻意不用——
   它不画 frost/rim/3D 折射（见 `lib/widgets/glass.dart` 的踩坑记录）；
3. **已知取舍**：小众包（上游单人维护），API 稳定性靠本台账的钉子兜住。

## 三、API 使用面 = 升级时的回归清单

全库只有 5 个文件引用它，升级后**逐符号**确认行为不变：

| 文件 | 符号 | 用法要点 |
| --- | --- | --- |
| `lib/main.dart` | `LiquidGlassWidgets.initialize()` | 启动 shader 预热；已包 try/catch（R-01），升级后验证失败降级路径仍不白屏 |
| `lib/main.dart` | `LiquidGlassWidgets.wrap` + `GlassThemeData.ios27()` + `brightnessResolver` + `adaptiveQuality`/`GlassAdaptiveScopeConfig` | 全局玻璃主题；MaterialApp 必须显式传 brightness，否则暗色系统下阴影消失；自适应开关与质量档钉子见下方补充 |
| `lib/pages/quote_list_page.dart` | `GlassBackdropGroup` | 列表玻璃共享一次背景读取（Impeller 下每块 BackdropFilter 切断 render pass，组化是掉帧防线） |
| `lib/widgets/glass.dart` | `LiquidGlassSettings.ios27Light.copyWith(…)` → `kGlassSurface` | 参数：saturation/glassColor/frostOpacity/blur/thickness/refractiveIndex/lightIntensity/fresnelStrength/lightAngle/rimLight/rimShade/rimShadeEnds/edgeAbsorption/bodyShade/glowIntensity/chromaticAberration——v6 曾把白光全清零只留光学形变，v10 请回斜向 rimLight，v20（2026-11-07）再补白纱/霜/模糊加一档，但 **v21（同日用户拍板「玻璃要是透明玻璃」）整组撤销**：`glassColor` 全透明、`frost`/`frostOpacity`/`blur` 全 0、`bodyMode: GlassBodyMode.clear`（Apple Glass.clear），卡身原样透出背景，玻璃感全部由边缘光学承担并把光学再推一档；v22 曾把 `rimShade` / `rimShadeEnds` / `edgeAbsorption` / `shadow` / `shadowElevation` 全部清零去灰边，但纯色背景下折射本就不可见，清掉暗部后只剩加色亮线 = 白边、丢失玻璃感，**已按用户要求整体回退到 v21**；当前生效值即 v21（调参史见该文件注释；`lightAngle` 自 2026-11-06 起为左上 3π/4，与自绘面板的 `kGlassLightFrom` 同一方向） |
| `lib/widgets/quote_tile.dart` | `GlassContainer.card(useOwnLayer, quality: GlassQuality.premium, shape: LiquidRoundedSuperellipse, settings: kGlassSurface, surfaceStyle: glass)` | premium 档是「边缘像玻璃」的唯一路径；standard 2D 轻量着色器不画 frost/rim。2026-11-06 起从普通 `GlassContainer` 换成非废弃的 `.card` 预设，光学参数逐项保留 |
| `lib/widgets/watchlist_sheet.dart` | `GlassContainer(useOwnLayer, quality: GlassQuality.premium, shape: LiquidRoundedRectangle, settings: kSheetGlassSurface)`（玻璃作背景层，内容平级） | 2026-11-06 起订阅弹层也走包的着色器玻璃（真模糊/rim/色散）；升级时确认 `LiquidRoundedRectangle` 仍在 |

> **2026-11-06 补充 · 自适应开关为什么是「开着但钉死」**
>
> 全局初始化清单要求 `adaptiveQuality: true`，但直接裸开会让 root
> `GlassAdaptiveScope` 成为**全局质量上限**——包内 `glass_theme_helpers.dart`
> 明说显式 `quality: GlassQuality.premium` 也照样被压。默认配置三段降档
> 路径（Phase 1 静态探针 / Phase 2 约 180 帧预热 / Phase 3 运行时 P95 迟滞）
> 在本机（常态可用内存约 300MB、`erm_reclaimd` 20~30% CPU）很容易触发，
> 一旦降到 standard，`kGlassSurface` 那 15 个按 iOS 27 premium 调的参数
> 会整体失效。因此 `main.dart` 里的 `kGlassAdaptiveConfig` 把
> `minQuality` / `maxQuality` / `initialQuality` 全设为 premium、
> `allowStepUp: false`：首帧即 premium、跳过 3 秒预热、Phase 3 的
> `stepDown` 被 `_floorQuality(..., minQuality)` 兜回。
>
> 代价：覆盖了包对「无 shader 支持设备」的保护阀，且仍多一个根
> `InheritedWidget` 与每帧一次的 timings 回调。`test/glass_quality_pin_test.dart`
> 用 2 条源码钉子 + 2 条行为刻画守着它，其中「对照组」实测裸开时第二帧
> 质量上限就从 premium 掉下去了。**升级包时必须重跑这组用例**：
> 只要上游不再让 `minQuality` 兜住静态探针，钉子会当场变红。

> **2026-11-06 补充 · 卡片 Widget 口径（第二步）**
>
> 上游 1.16.1 把 **`GlassCard` 标为废弃**（`glass_card.dart:99`
> `@Deprecated('Use GlassContainer.card instead. Will be removed in 2.0.0.')`，
> CHANGELOG「Deprecations」第一条），非废弃替代是 `GlassContainer.card`。
> 实测在工程里引用一次 `GlassCard`，`flutter analyze` 立刻报
> `deprecated_member_use`，破坏「analyze 0 issue」门禁。
> 另外**包里从来没有 `GlassPanel`**（`lib/`、CHANGELOG、`0.15.0` 字样
> 均零命中）：本工程的 `GlassPanel` 是 `lib/widgets/glass.dart` 自绘的
> `BackdropFilter + CustomPaint + GlassRim`，不受包版本废弃影响，
> **不做迁移**（迁移会丢掉刚修好的零 saveLayer / 零 MaskFilter 实现，
> 并破坏对比度与绘制分层测试）。
>
> 因此 `QuoteTile` 改用 `GlassContainer.card`，逐项保留
> `quality: premium` / `settings: kGlassSurface` / `useOwnLayer` / 28 圆角 /
> 「玻璃只当背景层、内容在 Stack 另一层」，另加两条：
> `padding: EdgeInsets.zero`（预设默认 16，但本处玻璃无内容）与
> `surfaceStyle: GlassSurfaceStyle.glass`（台账已预告 2.0.0 默认翻成 solid，
> 先钉住）。golden 7/7 全绿 = 视觉零变化。
> `test/glass_card_api_test.dart` 三条钉子守住：禁止出现 `GlassCard(`、
> 卡片预设的光学参数不得丢、`GlassPanel` 必须仍是本地自绘类。

## 四、升级 SOP（2.0.0 或任何 1.16.x+）

> ⚠️ **已知 breaking 预告**：上游 README 明示 2.0.0 起默认材质从 `glass`
> 变为 `solid`。升 2.0 必须逐调用点显式声明材质/quality（上面第三节的每个
> 符号），否则视觉会静默退化成白板。

1. `flutter pub upgrade liquid_glass_widgets` → `test/dependency_pin_test.dart`
   **当场变红**（这是设计好的，不是坏了）；
2. 读上游 CHANGELOG，对照第三节 API 面逐符号确认签名与语义；
3. `flutter analyze` 0 issues + `flutter test` 全绿（golden 仍全跑，本地）；
4. **真机玻璃走查**（不可省）：flutter_tester 无 Impeller，玻璃走 BackdropFilter
   降级路径，premium 档的折射/rim/色散只有真机能验——首页卡片、详情弹层、
   订阅弹层三处过一遍；
5. 改 `test/dependency_pin_test.dart` 里的 `_pinnedLiquidGlass` 常量为新版本，
   连同走查结论写进本台账的「版本履历」；
6. commit + push（CI 只跑逻辑测试，玻璃观感以第 4 步为准）。

**回滚**：`git revert` 该次 commit 即可（pubspec.yaml / pubspec.lock / 常量 /
履历同 commit 进出）。

> **升级 Flutter 引擎时同样要跑这一套**，外加静置探针采样（docs/
> PERF-BASELINE-2026-11-05.md 第八节）：引擎的 Impeller 对 backdrop filter
> 的缓存/部分重绘机制在持续演进，静置 raster p50 基线 12.5ms 显著下降
> （<5ms）即引擎改进落地——玻璃光学与性能数字都算升级的验收项。

## 五、锁定决策

| 选项 | 结论 |
| --- | --- |
| 保持 `^1.16.1` + lock 入库 + 守门测试钉 lock（**选定**） | 有意升级改一处常量即可；`pub upgrade` 的任何漂移当场被测试拦下 |
| 精确约束 `1.16.1` | 更硬，但升级要改两处（pubspec + 常量），且单包应用没有下游，收益为零 |
| 放任（无钉子） | `pub upgrade` 悄悄升版 → 玻璃光学变化只有真机能发现 → 正是本策略要堵的洞 |

## 六、版本履历

| 版本 | 日期 | 动作 / 走查结论 |
| --- | --- | --- |
| 1.16.1 | 2026-11-05 | 建档（= 上游最新版）；当前生产无升级动作；2.0.0 发布时按第四节 SOP 单执行 |
| 1.16.1 | 2026-11-06 | 尝试 `GlassModalSheet.show(morphFromRect:)` 做详情液态形变，真机三处不达标（形变无感 / detent 定高压住页脚 / 按住拉伸变大），**当日回退**。沉淀：包的弹层是页面式模型；`detents:{medium}`+`gradual`+`fillThreshold 1.0` 可关掉实心化；`ScrollControllerProvider` 必须接管内容滚动。见 README 二·三十五 |
| 1.16.1 | 2026-11-06 | 全局初始化补 `adaptiveQuality: true`（按清单），并用 `kGlassAdaptiveConfig` 把质量档钉死在 premium，避免静默降级；详情底部弹层加滚动感应的磨砂玻璃带（自绘，未新增依赖、未新增页面）。验收：`flutter analyze` 0 issue、404 逻辑用例全绿、7 个 golden 全绿（静止态像素零变化）。**真机 A/B 未做**：本轮 `adb devices` 无设备接入，见 README 待办 |
| 1.16.1 | 2026-11-06 | 第二步「卡片实现」口径复核：`GlassCard` 才是 1.16.1 已废弃（2.0.0 移除）的组件，包内无 `GlassPanel`（本工程的是自绘类，不迁移）。`QuoteTile` 改用非废弃的 `GlassContainer.card` 并显式钉住 `surfaceStyle: glass`，premium / kGlassSurface / 分层结构全保留。analyze 0 issue、407 逻辑用例、7 golden 全绿，视觉零变化；新增 `test/glass_card_api_test.dart` 防误迁移 |
