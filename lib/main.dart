import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'config/app_dependencies.dart';
import 'pages/quote_list_page.dart';
import 'services/quote_feeds.dart';
import 'utils/app_log.dart';
import 'utils/error_hooks.dart';
import 'utils/perf_probe.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 全局错误钩子放在**所有业务代码之前**：它要盖住 main 里剩下这几行，
  // 也要盖住 runApp 之后的一切。两个钩子缺一不可（见 error_hooks.dart 的注释）。
  installErrorHooks();

  // 帧耗时探针：只在 --dart-define=PERF_LOG=true 的构建里注册
  installFrameProbe();

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
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorSchemeSeed: const Color(0xFFE03A2F),
        // 数字/拉丁走 Inter（SF Pro 的开源近似，OFL 许可可打包安卓），
        // 中文逐字符回退系统字体（MIUI/鸿蒙黑体）——引擎自动完成
        fontFamily: 'Inter',
        // 页面自己画背景，Scaffold 不能盖一层不透明底
        scaffoldBackgroundColor: Colors.transparent,
        splashFactory: NoSplash.splashFactory,
      ),
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
