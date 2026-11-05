/// 视觉预览 harness：生成 / 比对 `test/preview/goldens/*.png`。
///
/// ## 为什么放在 `test/` 而不是 `tool/`
///
/// 旧的 harness 在 `tool/preview/app_preview_test.dart`，而 `flutter test`
/// 默认只扫 `test/`——它从来不在门禁里跑，所以脚本被删掉后没人发现，
/// 六张 `docs/preview/*.png` 静默过期（A13）。放在 `test/` 下，它和
/// 单元测试一样每次 `flutter test` 都会被执行，过期会立刻变红。
///
/// ## 复现性约定（任何一条破了，基线就不再是基线）
///
/// 1. **全注入**：行情、目录、走势、存档全部替身，零网络、零磁盘；
/// 2. **钉死时钟**：`2026-11-05 15:05`（周四，A 股已收盘 / 港股仍在盘中）——
///    时段角标按订阅市场并集显示「交易中」、页头秒表固定；太极由行情 tick
///    驱动而假 feed 只在 `connect()` 推一帧，所以仍不自转，任意一帧可复现；
/// 3. **钉死视口**：390×844 逻辑像素 @ dpr 2（输出 780×1688）；
/// 4. **真字体**：Inter（仓库内资产）+ SimHei（中文回退）+ MaterialIcons，
///    否则中文和图标会渲染成方框；
/// 5. **固定随机源**：K 线与分时用自带的 LCG，不依赖 `dart:math` 的
///    `Random` 实现（跨 Dart 版本不保证稳定）；
/// 6. **不使用 `pumpAndSettle`**：它按 100ms 步进推进假时钟，30s 周期定时器
///    会在中途触发，步数随实现变化。这里改用固定次数的 `pump`。
///
/// ## 已知的保真度边界
///
/// `flutter_tester` 不支持 Impeller（`ImageFilter.isShaderFilterSupported`
/// 为 false），玻璃走的是 BackdropFilter 降级路径，与真机 premium 档的
/// 折射/边缘光不完全一致。因此这套基线对**布局、字号、颜色、信息层次**
/// 有决定性，对**玻璃光学的像素级还原**没有——真机观感仍需人工走查。
///
/// ## 更新基线
///
/// ```bash
/// flutter test test/preview/app_preview_test.dart --update-goldens
/// ```
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/kline.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/pages/quote_list_page.dart';
import 'package:super_market/services/kline_loader.dart';
import 'package:super_market/services/local_store.dart';
import 'package:super_market/services/quote_feed.dart';
import 'package:super_market/services/source/kline_source.dart';
import 'package:super_market/services/symbol_directory.dart';
import 'package:super_market/services/watchlist_repository.dart';
import 'package:super_market/widgets/taiji_mark.dart';

// ============================ 常量 ============================

/// 逻辑分辨率：主流 Android 竖屏（390×844 ≈ 6.1"）
const Size _kScreen = Size(390, 844);

/// 2 倍图：文本边缘足够锐利，单张体积约为 3 倍图的 45%
const double _kDpr = 2;

/// 钉死的「现在」：2026-11-05 周四 15:05，A 股收盘后 5 分钟。
///
/// 订阅里有港股（01378 中国宏桥，交易到 16:10），所以页头角标按**订阅市场
/// 并集**口径显示「交易中」；卡片是否标「快照」只看行情时间戳有多旧，两者
/// 互不干涉（见 `utils/quote_freshness.dart`）。
/// 太极由行情 tick 驱动，而 `_PreviewFeed` 只在 connect 推一帧固定报价，
/// 即便时段判为「交易中」也不会自转——截图依旧可复现。
final DateTime _kNow = DateTime(2026, 11, 5, 15, 5);

/// 行情时间戳：最后一笔成交 14:59:03（与详情「更新时间」一致）
final DateTime _kQuoteTime = DateTime(2026, 11, 5, 14, 59, 3);

// ============================ 固定行情 ============================

const List<Quote> _kQuotes = <Quote>[
  // 跌：绿 —— 格力电器
  Quote(
    code: '000651',
    region: 'SZ',
    price: 38.71,
    change: -0.25,
    changePercent: -0.64,
    previousClose: 38.96,
    open: 38.90,
    high: 39.19,
    low: 38.52,
    volume: 10327200,
    turnover: 400120000.00,
  ),
  // 跌：绿 —— 长鑫科技（科创板，688 开头）
  Quote(
    code: '688825',
    region: 'SH',
    price: 40.88,
    change: -0.84,
    changePercent: -2.01,
    previousClose: 41.72,
    open: 40.90,
    high: 41.30,
    low: 40.50,
    volume: 2604417,
    turnover: 106470000.00,
  ),
  // 涨：红 —— 神火股份
  Quote(
    code: '000933',
    region: 'SZ',
    price: 25.97,
    change: 0.31,
    changePercent: 1.21,
    previousClose: 25.66,
    open: 25.70,
    high: 26.10,
    low: 25.60,
    volume: 40123000,
    turnover: 1038000000.00,
  ),
  // 涨：红 —— 中国宏桥（港股，5 位代码）
  Quote(
    code: '01378',
    region: 'HK',
    price: 21.02,
    change: 0.68,
    changePercent: 3.34,
    previousClose: 20.34,
    open: 20.40,
    high: 21.10,
    low: 20.30,
    volume: 18234000,
    turnover: 381200000.00,
  ),
];

/// 订阅列表：与 [AppConfig.stocks] 一致，跑的是「没有存档时用默认列表」这条路
List<Quote> _quotesAt(DateTime time) => _kQuotes
    .map(
      (Quote q) => Quote(
        code: q.code,
        region: q.region,
        price: q.price,
        change: q.change,
        changePercent: q.changePercent,
        previousClose: q.previousClose,
        open: q.open,
        high: q.high,
        low: q.low,
        volume: q.volume,
        turnover: q.turnover,
        timestamp: time,
      ),
    )
    .toList();

// ============================ 确定性随机 ============================

int _rngState = 0;

void _seedRng(int seed) => _rngState = seed & 0xFFFFFFFF;

/// 线性同余：写死算法，不用 `Random`——后者的序列不保证跨 Dart 版本稳定
double _rng() {
  _rngState = (_rngState * 1664525 + 1013904223) & 0xFFFFFFFF;
  return _rngState / 4294967296.0;
}

// ============================ 走势数据 ============================

/// 当日分时：09:30–11:30 + 13:00–15:00，共 242 个点。
///
/// 价格从 1499.00 漂到 1486.00，叠加两个正弦波（做出「有波动但趋势向下」的
/// 观感）与小幅噪声，全部夹在当日最高/最低之间。
List<IntradayPoint> _intradayPoints() {
  _seedRng(20261105);
  final List<IntradayPoint> points = <IntradayPoint>[];
  final DateTime day = DateTime(2026, 11, 5);
  double cumVolume = 0;
  double cumAmount = 0;

  void emit(int minuteOfDay) {
    final double progress = points.length / 241.0;
    final double drift = 38.90 + (38.71 - 38.90) * progress;
    final double wave =
        0.14 * math.sin(points.length / 11.0) +
        0.055 * math.sin(points.length / 3.7);
    final double noise = (_rng() - 0.5) * 0.04;
    final double price = (drift + wave + noise)
        .clamp(38.52, 39.19)
        .toDouble();
    final double volume = 8000 + _rng() * 26000;
    cumVolume += volume;
    cumAmount += volume * price;
    points.add(
      IntradayPoint(
        time: DateTime(
          day.year,
          day.month,
          day.day,
          minuteOfDay ~/ 60,
          minuteOfDay % 60,
        ),
        price: price,
        avgPrice: cumAmount / cumVolume,
        volume: volume,
      ),
    );
  }

  for (int m = 0; m <= 120; m++) {
    emit(9 * 60 + 30 + m);
  }
  for (int m = 0; m <= 120; m++) {
    emit(13 * 60 + m);
  }
  return points;
}

/// 240 根日线（约一年）：先生成完整序列，再按 [count] 取末尾。
///
/// 必须先全量生成再截断——否则不同 count 会是两条走势不同的曲线，
/// 看起来像换了一只股票。`count` 仍是数据层能力（[KlineLoader] 可指定根数），
/// 只是 UI 不再提供翻页入口。
List<Kline> _dailyBars(int count) {
  _seedRng(4321);
  final List<DateTime> days = <DateTime>[];
  DateTime cursor = DateTime(2026, 11, 4);
  while (days.length < 240) {
    if (cursor.weekday != DateTime.saturday &&
        cursor.weekday != DateTime.sunday) {
      days.add(cursor);
    }
    cursor = cursor.subtract(const Duration(days: 1));
  }
  final List<DateTime> ordered = days.reversed.toList();

  final List<Kline> bars = <Kline>[];
  // 尺度跟着「详情预览点开的那只票」（AppConfig.stocks.first 格力电器 38.71）走：
  // 图上的 K 线必须和头部大数字同量级，否则预览图会显得像两张图拼在一起。
  double close = 33.00;
  for (int i = 0; i < ordered.length; i++) {
    final double drift = 33.00 + (38.71 - 33.00) * (i / (ordered.length - 1));
    final double wave = 0.62 * math.sin(i / 9.0) + 0.34 * math.sin(i / 3.1);
    final double target = drift + wave;
    final double open = close;
    final double high = math.max(open, target) + 0.10 + _rng() * 0.22;
    final double low = math.min(open, target) - 0.10 - _rng() * 0.22;
    bars.add(
      Kline(
        time: ordered[i],
        open: open,
        high: high,
        low: low,
        close: target,
        volume: 1200000 + _rng() * 2400000,
      ),
    );
    close = target;
  }

  final int n = math.max(1, math.min(count, bars.length));
  return bars.sublist(bars.length - n);
}

// ============================ 替身 ============================

/// 不联网的行情：`connect()` 立刻推一帧固定报价
class _PreviewFeed implements QuoteFeed {
  _PreviewFeed(this._onQuotes);

  final ValueChanged<List<Quote>> _onQuotes;

  @override
  final ValueNotifier<FeedStatus> status = ValueNotifier<FeedStatus>(
    FeedStatus.connected,
  );

  @override
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  @override
  List<StockConfig> get stocks => AppConfig.stocks;

  @override
  String get sourceLabel => '新浪财经';

  @override
  void connect() => _onQuotes(_quotesAt(_kQuoteTime));

  @override
  void pause() {}

  @override
  void resume() {}

  @override
  void reconnectNow() => _onQuotes(_quotesAt(_kQuoteTime));

  @override
  void updateStocks(List<StockConfig> next) {}

  @override
  void dispose() {
    status.dispose();
    lastError.dispose();
  }

  static QuoteFeed builder(ValueChanged<List<Quote>> onQuotes) =>
      _PreviewFeed(onQuotes);
}

/// 目录替身：已经是「已加载」状态，本地/远端搜索都返回固定一条。
///
/// 用子类而不是重写接口：`SymbolDirectory` 的搜索逻辑（本地命中 + 远端合并）
/// 是产品行为，预览要拍的是**它的结果怎么显示**，不是把逻辑复制一份。
class _PreviewDirectory extends SymbolDirectory {
  _PreviewDirectory() : super(store: MemoryKeyValueStore());

  static const List<StockConfig> _results = <StockConfig>[
    StockConfig(code: '600519', name: '贵州茅台', region: 'SH'),
  ];

  @override
  bool get isLoaded => true;

  @override
  Future<void> ensureLoaded({bool force = false}) async {}

  @override
  Future<List<StockConfig>?> searchRemote(String raw) async =>
      raw.trim().isEmpty ? const <StockConfig>[] : _results;

  @override
  List<StockConfig> search(String raw, {int limit = 12}) =>
      raw.trim().isEmpty ? const <StockConfig>[] : _results;
}

/// 走势替身：直接返回固定数据，绕过主备切换与缓存（预览不需要那两条路径）
class _PreviewKlineLoader extends KlineLoader {
  _PreviewKlineLoader() : super(chain: const <KlineSource>[], now: () => _kNow);

  @override
  Future<KlineResult<Kline>> loadDaily(StockConfig stock, {int? count}) async {
    final int n = math.max(
      1,
      math.min(count ?? KlineSource.defaultDailyCount, KlineSource.maxDailyCount),
    );
    return KlineResult<Kline>(items: _dailyBars(n), sourceId: 'sina');
  }

  @override
  Future<KlineResult<IntradayPoint>> loadIntraday(StockConfig stock) async {
    return KlineResult<IntradayPoint>(
      items: _intradayPoints(),
      sourceId: 'sina',
    );
  }
}

// ============================ 字体 ============================

Future<ByteData> _fileBytes(String path) async {
  final File file = File(path);
  if (!file.existsSync()) {
    throw StateError('预览字体缺失：$path');
  }
  return ByteData.sublistView(await file.readAsBytes());
}

Future<void> _register(String family, List<String> paths) async {
  final FontLoader loader = FontLoader(family);
  for (final String path in paths) {
    loader.addFont(_fileBytes(path));
  }
  await loader.load();
}

/// Flutter SDK 根目录：从 `flutter_tester` 可执行文件往上找 `bin/cache`
String _flutterRoot() {
  final String? fromEnv = Platform.environment['FLUTTER_ROOT'];
  if (fromEnv != null && fromEnv.isNotEmpty) {
    return fromEnv;
  }
  Directory dir = File(Platform.resolvedExecutable).parent;
  for (int i = 0; i < 8; i++) {
    if (Directory('${dir.path}/bin/cache/artifacts').existsSync()) {
      return dir.path;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) {
      break;
    }
    dir = parent;
  }
  throw StateError('找不到 Flutter SDK（试过 FLUTTER_ROOT 与可执行文件路径）');
}

/// 中文回退字体：仓库里没有中文字体（生产靠系统回退），预览必须显式加载，
/// 否则所有中文都是方框。可用 `PREVIEW_CJK_FONT` 覆盖。
String _cjkFontPath() {
  final List<String> candidates = <String>[
    Platform.environment['PREVIEW_CJK_FONT'] ?? '',
    'C:/Windows/Fonts/simhei.ttf',
    'C:/Windows/Fonts/msyh.ttc',
    '/System/Library/Fonts/STHeiti Medium.ttc',
    '/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc',
  ];
  for (final String path in candidates) {
    if (path.isNotEmpty && File(path).existsSync()) {
      return path;
    }
  }
  throw StateError(
    '找不到中文字体，试过：\n${candidates.where((String p) => p.isNotEmpty).join('\n')}\n'
    '可用环境变量 PREVIEW_CJK_FONT 指定。',
  );
}

Future<void> _loadFonts() async {
  // Inter：仓库内资产，与生产完全一致（四个字重）
  await _register('Inter', <String>[
    'assets/fonts/inter-latin-400.ttf',
    'assets/fonts/inter-latin-500.ttf',
    'assets/fonts/inter-latin-600.ttf',
    'assets/fonts/inter-latin-700.ttf',
  ]);
  await _register('SimHei', <String>[_cjkFontPath()]);
  // 图标字体不在仓库里，只有 SDK 缓存有一份；`uses-material-design: true`
  // 只是把它打进 APK，测试进程不会自动加载，必须显式注册。
  await _register('MaterialIcons', <String>[
    '${_flutterRoot()}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ]);
}

// ============================ 装配 ============================

/// 与 `lib/main.dart` 同构：wrap 的 theme 必须一致，否则玻璃参数（frost /
/// paraxial / rim）全变，拍出来的不是生产观感。
ThemeData _previewTheme() => ThemeData(
  useMaterial3: true,
  brightness: Brightness.light,
  colorSchemeSeed: const Color(0xFFE03A2F),
  fontFamily: 'Inter',
  // 生产靠 Android 系统字体逐字符回退；测试进程没有系统字体，显式指定
  fontFamilyFallback: const <String>['SimHei'],
  scaffoldBackgroundColor: Colors.transparent,
  splashFactory: NoSplash.splashFactory,
);

final GlobalKey _kRootKey = GlobalKey();

Widget _previewApp() {
  return LiquidGlassWidgets.wrap(
    theme: const GlassThemeData.ios27(),
    brightnessResolver: Theme.maybeBrightnessOf,
    child: RepaintBoundary(
      key: _kRootKey,
      child: MaterialApp(
        title: '超级市场',
        debugShowCheckedModeBanner: false,
        theme: _previewTheme(),
        builder: (BuildContext context, Widget? child) =>
            Material(type: MaterialType.transparency, child: child),
        home: QuoteListPage(
          serviceBuilder: _PreviewFeed.builder,
          watchlistRepository: WatchlistRepository(MemoryKeyValueStore()),
          symbolDirectory: _PreviewDirectory(),
          klineLoader: _PreviewKlineLoader(),
          clock: () => _kNow,
        ),
      ),
    ),
  );
}

/// 固定次数的帧推进（不用 `pumpAndSettle`，理由见文件头）
Future<void> _frames(WidgetTester tester, [int count = 8]) async {
  for (int i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _pumpHome(WidgetTester tester) async {
  tester.view.physicalSize = _kScreen * _kDpr;
  tester.view.devicePixelRatio = _kDpr;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(_previewApp());
  // 首帧 → postFrameCallback 里的 _bootstrap（读存档 → connect）→ 报价落到
  // notifier → 再一帧才画出价格
  await _frames(tester, 10);
}

/// 统一包装：平台覆盖与树卸载必须在**测试体内**完成。
///
/// `debugDefaultTargetPlatformOverride` 是 foundation 调试变量，
/// `TestWidgetsFlutterBinding` 在测试体结束时立刻校验它已复原，
/// 放在 `tearDown` 里已经太晚（会报 "foundation debug variable was changed"）。
/// 同理，页头秒表 / 时段角标 / 太极的三个周期定时器必须在体内卸载，
/// 否则会被判 "A Timer is still pending"。
void _previewTest(
  String description,
  Future<void> Function(WidgetTester tester) body,
) {
  testWidgets(description, (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await body(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

Future<void> _openDetail(WidgetTester tester) async {
  // 点的是列表里真实存在的那张卡——详情弹层的报价来自它自己的 notifier
  await tester.tap(find.text(AppConfig.stocks.first.name));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await _frames(tester, 10);
}

Future<void> _expectGolden(WidgetTester tester, String name) async {
  await expectLater(
    find.byKey(_kRootKey),
    matchesGoldenFile('goldens/$name.png'),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(_loadFonts);

  _previewTest('page：首页（A 股收盘后 / 港股盘中，固定报价）', (
    WidgetTester tester,
  ) async {
    await _pumpHome(tester);
    await _expectGolden(tester, 'page');
  });

  _previewTest('scroll：上滑 160 后的页头渐隐', (WidgetTester tester) async {
    await _pumpHome(tester);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -160));
    await _frames(tester, 10);
    await _expectGolden(tester, 'scroll');
  });

  _previewTest('detail：详情弹层（分时）', (WidgetTester tester) async {
    await _pumpHome(tester);
    await _openDetail(tester);
    await _expectGolden(tester, 'detail');
  });

  _previewTest('detail-daily：详情弹层（日 K，一页 80 根）', (
    WidgetTester tester,
  ) async {
    await _pumpHome(tester);
    await _openDetail(tester);
    await tester.tap(find.text('日K'));
    await tester.pump(const Duration(milliseconds: 200));
    await _frames(tester, 10);
    await _expectGolden(tester, 'detail-daily');
  });

  _previewTest('watchlist：订阅管理（已输入「茅台」，含搜索结果）', (
    WidgetTester tester,
  ) async {
    await _pumpHome(tester);
    await tester.tap(find.byType(TaijiMark));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _frames(tester, 8);

    await tester.enterText(find.byType(TextField), '茅台');
    // 250ms 防抖 + 一次异步「远端搜索」
    await tester.pump(const Duration(milliseconds: 300));
    await _frames(tester, 10);
    await _expectGolden(tester, 'watchlist');
  });
}
