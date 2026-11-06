import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'config/app_dependencies.dart';
import 'config/app_theme.dart';
import 'pages/quote_list_page.dart';
import 'services/quote_feeds.dart';
import 'utils/app_log.dart';
import 'utils/error_hooks.dart';
import 'utils/exit_diagnostics.dart';
import 'utils/perf_probe.dart';

/// 全局玻璃质量档：**开启自适应，但把它的降档自由度全部关掉**。
///
/// `adaptiveQuality: true` 会在根插入 `GlassAdaptiveScope`，而它是全局质量
/// **上限**——连 `quote_tile.dart` / `watchlist_sheet.dart` 里显式写的
/// `quality: GlassQuality.premium` 也会被压下去（见包内 `glass_theme_helpers.dart`
/// 的解析优先级注释）。默认配置有三段降档路径：Phase 1 静态探针（无 shader
/// 支持 → minimal）、Phase 2 约 180 帧预热基准、Phase 3 运行时 P95 迟滞。
/// 本机常态可用内存约 300MB、`erm_reclaimd` 常驻 20~30% CPU，落进降档区间的
/// 概率不低；一旦降档，轻量 2D 着色器不画 frost / rim light / 3D 折射，
/// `kGlassSurface` 那 15 个按 iOS 27 premium 逐项调出来的参数会整体失效。
///
/// 四个值一起钉死：
/// - min/max 同为 premium：Phase 1 的 forced 值与 Phase 3 的 stepDown 都会被
///   `_floorQuality(..., minQuality)` 兜回 premium；
/// - initialQuality = premium：首帧即 premium，且跳过约 3 秒的 Phase 2 预热
///   窗口（包内 `start()` 遇到非 null 的 initialQuality 直接进 Phase 3）；
/// - allowStepUp: false：不再有升档回调。
///
/// 代价说清楚：这等于把开关打开但不让它改变画质，仍多一个根 InheritedWidget
/// 和每帧一次的 timings 回调；也覆盖了包对「无 shader 支持设备」的保护阀。
/// 这是「必须开 adaptiveQuality」与「premium 观感不能退」两条约束的交集，
/// 升级玻璃包时按 docs/dep-liquid-glass.md 第四节重新验一次。
const GlassAdaptiveScopeConfig kGlassAdaptiveConfig = GlassAdaptiveScopeConfig(
  minQuality: GlassQuality.premium,
  maxQuality: GlassQuality.premium,
  initialQuality: GlassQuality.premium,
  allowStepUp: false,
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 全局错误钩子放在**所有业务代码之前**：它要盖住 main 里剩下这几行，
  // 也要盖住 runApp 之后的一切。两个钩子缺一不可（见 error_hooks.dart 的注释）。
  installErrorHooks();

  // 帧耗时探针：只在 --dart-define=PERF_LOG=true 的构建里注册
  installFrameProbe();

  // 退出归因：首帧之后读一次「上次进程怎么死的」（Android 17 的
  // MemoryLimiter 只会留一条 ApplicationExitInfo，不产生崩溃堆栈）。
  // 必须放在 runApp 之前注册、但实际执行在首帧之后——不占冷启动关键路径。
  installExitDiagnostics();

  // 日志前缀跟着数据源走，避免「日志说 iTick、实际连别家」
  AppLog.tag = QuoteFeeds.label;

  // 全屏铺满：玻璃要能透出状态栏/导航栏后面的极光背景
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark, // Android：深色图标
      statusBarBrightness: Brightness.light, // iOS 语义
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );

  // 液态玻璃（liquid_glass_widgets）：启动时把 shader 预热进显存，
  // 避免第一帧玻璃闪白。非阻塞 IO，不拖慢启动。
  //
  // R-01（review-2026-11-05）：初始化必须兜底——第三方库若在预热时抛错
  // （着色器编译失败、设备不支持等），裸 await 会让 main 中断，App 永远
  // 白屏。最多退化为「无预热」，绝不能挡住 runApp。
  try {
    await LiquidGlassWidgets.initialize();
  } on Object catch (e, st) {
    AppLog.e('玻璃预热失败，按无预热继续: $e\n$st');
  }

  // 组合根（A11 最小版）：数据层对象只在这里创建一次并显式下发。
  // 页面仍保留 ?? 兜底，测试直接 new QuoteListPage 不需要全套依赖。
  final AppDependencies deps = AppDependencies.production();

  runApp(
    LiquidGlassWidgets.wrap(
      // 对标 iOS 27 的 glassEffect(.regular)：frost 14 + paraxial 透镜 +
      // 顶部受光 + rimShade/rimLight，premium 档
      theme: const GlassThemeData.ios27(),
      // MaterialApp 必须显式传：否则暗色系统 + 亮色 App 时阴影/描边会消失
      brightnessResolver: Theme.maybeBrightnessOf,
      // 设备性能自适应：开着，但质量档被 kGlassAdaptiveConfig 钉死在 premium
      adaptiveQuality: true,
      adaptiveConfig: kGlassAdaptiveConfig,
      child: SuperMarketApp(dependencies: deps),
    ),
  );
}

class SuperMarketApp extends StatelessWidget {
  const SuperMarketApp({super.key, required this.dependencies});

  final AppDependencies dependencies;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '超级市场',
      debugShowCheckedModeBanner: false,
      // 主题抽到 config/app_theme.dart：Widget Previews 必须和真机共用同一份，
      // 否则预览会显示一个"和手机上不一样"的效果（见该文件注释）。
      theme: buildSuperMarketTheme(),
      // 液态玻璃包是 Material-free 的：不垫一层透明 Material，
      // 它的文字/图标没有 Material 祖先会按裸 widgets 渲染
      builder: (BuildContext context, Widget? child) {
        return Material(type: MaterialType.transparency, child: child);
      },
      home: QuoteListPage(
        watchlistRepository: dependencies.watchlistRepository,
        symbolDirectory: dependencies.symbolDirectory,
        klineLoader: dependencies.klineLoader,
      ),
    );
  }
}
