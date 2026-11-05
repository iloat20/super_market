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

全库只有 4 个文件引用它，升级后**逐符号**确认行为不变：

| 文件 | 符号 | 用法要点 |
| --- | --- | --- |
| `lib/main.dart` | `LiquidGlassWidgets.initialize()` | 启动 shader 预热；已包 try/catch（R-01），升级后验证失败降级路径仍不白屏 |
| `lib/main.dart` | `LiquidGlassWidgets.wrap` + `GlassThemeData.ios27()` + `brightnessResolver` | 全局玻璃主题；MaterialApp 必须显式传 brightness，否则暗色系统下阴影消失 |
| `lib/pages/quote_list_page.dart` | `GlassBackdropGroup` | 列表玻璃共享一次背景读取（Impeller 下每块 BackdropFilter 切断 render pass，组化是掉帧防线） |
| `lib/widgets/glass.dart` | `LiquidGlassSettings.ios27Light.copyWith(…)` → `kGlassSurface` | 14 个参数：saturation/glassColor/frostOpacity/thickness/refractiveIndex/lightIntensity/fresnelStrength/rimLight/rimShade/rimShadeEnds/edgeAbsorption/bodyShade/glowIntensity/chromaticAberration——白光全清零、只留光学形变（调参史见该文件注释） |
| `lib/widgets/quote_tile.dart` | `GlassContainer(useOwnLayer, quality: GlassQuality.premium, shape: LiquidRoundedSuperellipse, settings)` | premium 档是「边缘像玻璃」的唯一路径；standard 2D 轻量着色器不画 frost/rim |

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
