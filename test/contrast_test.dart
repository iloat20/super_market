/// A05（S2 · B15+B18）：小字对比度必须达到 WCAG AA 的 4.5:1。
///
/// ## 为什么不写「#8B94A3 对 #F8F6F5 = 2.84」这种静态断言
///
/// 那个数字只对**不透明**的页面背景成立。详情/订阅弹层的实际背景是
/// 「遮罩压暗的页面 → 高斯模糊 → 半透明白渐变」，是一张**合成**出来的
/// 中灰面；任何静态取色都会高估对比度。所以这里直接把弹层渲染出来，
/// 从 `RenderRepaintBoundary` 取真实像素，再按 WCAG 公式算。
///
/// ## 采样点为什么在文字左侧 4dp
///
/// 被测对象是「文字 vs 它自己的背景」。取整块面板的最暗值会误伤那些
/// 压在浅色胶囊上的文字（胶囊比面板更亮），取整块最亮值又会放过暗角。
/// 文字包围盒左侧 4dp 一定还在它所在的那一层背景里：正文是面板内边距，
/// 胶囊里是胶囊自身的底色，且不会压到字形上。
///
/// ## 这条用例红过
///
/// 改动前实测：面板最暗 #BBBDC4（L=0.51），`inkMute` 对比度 1.7:1，
/// `inkSoft` 3.4:1 —— 连「次要文字」这一层都不达标。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/kline.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/services/kline_loader.dart';
import 'package:super_market/services/local_store.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/services/source/kline_source.dart';
import 'package:super_market/services/symbol_directory.dart';
import 'package:super_market/widgets/quote_detail_sheet.dart';
import 'package:super_market/widgets/watchlist_sheet.dart';

// ============================ WCAG ============================

/// WCAG 2.x 相对亮度（sRGB → 线性 → Rec.709 加权）
double relativeLuminance(Color c) {
  double channel(double v) =>
      v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) +
      0.7152 * channel(c.g) +
      0.0722 * channel(c.b);
}

/// WCAG 对比度，1..21
double contrastRatio(Color fg, Color bg) {
  final double a = relativeLuminance(fg);
  final double b = relativeLuminance(bg);
  final double hi = math.max(a, b);
  final double lo = math.min(a, b);
  return (hi + 0.05) / (lo + 0.05);
}

String hex(Color c) =>
    '#${(c.r * 255).round().toRadixString(16).padLeft(2, '0')}'
            '${(c.g * 255).round().toRadixString(16).padLeft(2, '0')}'
            '${(c.b * 255).round().toRadixString(16).padLeft(2, '0')}'
        .toUpperCase();

// ============================ 取样 ============================

/// 一帧真实像素
class _Frame {
  _Frame(this.width, this.height, this.bytes);

  final int width;
  final int height;
  final ByteData bytes;

  Color at(int x, int y) {
    final int i = (y * width + x) * 4;
    return Color.fromARGB(
      bytes.getUint8(i + 3),
      bytes.getUint8(i),
      bytes.getUint8(i + 1),
      bytes.getUint8(i + 2),
    );
  }
}

Future<_Frame> _capture(WidgetTester tester, GlobalKey key) async {
  final RenderRepaintBoundary boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final ui.Image? image = await tester.runAsync(
    () => boundary.toImage(pixelRatio: 1),
  );
  final ByteData? data = await tester.runAsync<ByteData?>(
    () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  expect(data, isNotNull, reason: '拿不到像素，后面的对比度计算全部作废');
  return _Frame(image!.width, image.height, data!);
}

/// 采样背景色：文字左边缘外 4dp 的上下 3 个像素取最暗（最不利）的一个。
///
/// 取最暗而不是平均：深色字压在浅底上时，背景越暗对比度越低，
/// 按最暗的那一个判，才不会被平均掉。
Color _backdropBehind(_Frame f, Rect rect) {
  final int x = (rect.left - 4).round();
  final int cy = rect.center.dy.round();
  Color worst = f.at(x, cy);
  for (final int dy in <int>[-2, 2]) {
    final int y = (cy + dy).clamp(0, f.height - 1);
    final Color c = f.at(x.clamp(0, f.width - 1), y);
    if (relativeLuminance(c) < relativeLuminance(worst)) {
      worst = c;
    }
  }
  return worst;
}

/// 找出所有「小字」：显式 fontSize ≤ 13 且颜色可解析（继承色跳过，
/// 因为拿不到实际颜色就没法算）。
List<Text> _smallTexts(WidgetTester tester, Finder scope) {
  final Iterable<Element> all = scope.evaluate();
  final List<Text> out = <Text>[];
  for (final Element e in all) {
    void visit(Element element) {
      final Widget w = element.widget;
      if (w is Text && w.data != null && w.style?.fontSize != null) {
        if (w.style!.fontSize! <= 13 && w.style!.color != null) {
          out.add(w);
        }
      }
      element.visitChildren(visit);
    }

    visit(e);
  }
  return out;
}

// ============================ 数据替身 ============================

const StockConfig _kStock = StockConfig(
  code: '600519',
  name: '贵州茅台',
  region: 'SH',
);

class _FakeLoader extends KlineLoader {
  _FakeLoader()
    : super(chain: const <KlineSource>[], now: () => DateTime(2026, 11, 5, 15));

  @override
  Future<KlineResult<Kline>> loadDaily(StockConfig stock, {int? count}) async {
    return KlineResult<Kline>(
      items: <Kline>[
        Kline(
          time: DateTime(2026, 11, 3),
          open: 1470,
          high: 1500,
          low: 1460,
          close: 1498.3,
          volume: 1000,
        ),
        Kline(
          time: DateTime(2026, 11, 4),
          open: 1498.3,
          high: 1510,
          low: 1480,
          close: 1486,
          volume: 1000,
        ),
      ],
      sourceId: 'sina',
    );
  }

  @override
  Future<KlineResult<IntradayPoint>> loadIntraday(StockConfig stock) async {
    return KlineResult<IntradayPoint>(
      items: <IntradayPoint>[
        IntradayPoint(
          time: DateTime(2026, 11, 5, 9, 30),
          price: 1499,
          avgPrice: 1499,
          volume: 100,
        ),
        IntradayPoint(
          time: DateTime(2026, 11, 5, 10, 42),
          price: 1502.5,
          avgPrice: 1500,
          volume: 100,
        ),
        IntradayPoint(
          time: DateTime(2026, 11, 5, 14, 36),
          price: 1478.1,
          avgPrice: 1490,
          volume: 100,
        ),
      ],
      sourceId: 'sina',
    );
  }
}

Quote _quote({TradingStatus status = TradingStatus.normal}) => Quote(
  code: '600519',
  tradingStatus: status,
  region: 'SH',
  price: 1486.00,
  change: -12.30,
  changePercent: -0.82,
  previousClose: 1498.30,
  open: 1499.00,
  high: 1502.50,
  low: 1478.10,
  volume: 21349,
  turnover: 3170000000,
  timestamp: DateTime(2026, 11, 5, 14, 59, 3),
);

SymbolDirectory _directory() => SymbolDirectory(
  store: MemoryKeyValueStore(),
  httpGet: (Uri uri, Map<String, String> headers) async =>
      const HttpJsonResponse(statusCode: 200, body: '[]'),
  httpGetBytes: (Uri uri, Map<String, String> headers) async =>
      const HttpRawResponse(statusCode: 200, body: <int>[]),
);

// ============================ 用例 ============================

/// 打开详情弹层（每次调用都重新 pump 一棵树，保证背景是干净的）
Future<void> _pumpDetail(
  WidgetTester tester,
  GlobalKey root,
  Quote quote,
) async {
  final ValueNotifier<Quote> q = ValueNotifier<Quote>(quote);
  addTearDown(q.dispose);
  await tester.pumpWidget(
    RepaintBoundary(
      key: root,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: (BuildContext context, Widget? child) =>
            Material(type: MaterialType.transparency, child: child),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {
                  unawaited(
                    showQuoteDetailSheet(
                      context,
                      stock: _kStock,
                      quote: q,
                      loader: _FakeLoader(),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// 逐条小字量对比度，返回最差值 + 不达标清单
({
  int samples,
  double worst,
  String worstLabel,
  List<String> failures,
})
_audit(WidgetTester tester, GlobalKey root, _Frame frame) {
  final List<Text> texts = _smallTexts(tester, find.byKey(root));
  final List<String> failures = <String>[];
  double worst = 99;
  String worstLabel = '';
  for (final Text t in texts) {
    final Rect r = tester.getRect(find.byWidget(t));
    if (r.left < 4 || r.width < 4) {
      continue; // 贴着画布左缘/零宽，取不到左侧背景
    }
    final Color bg = _backdropBehind(frame, r);
    final double ratio = contrastRatio(t.style!.color!, bg);
    if (ratio < worst) {
      worst = ratio;
      worstLabel = '${t.data} ${t.style!.fontSize}px';
    }
    if (ratio < 4.5) {
      failures.add(
        '「${t.data}」${t.style!.fontSize}px ${hex(t.style!.color!)} '
        '压在 ${hex(bg)} 上 = ${ratio.toStringAsFixed(2)}:1',
      );
    }
  }
  return (
    samples: texts.length,
    worst: worst,
    worstLabel: worstLabel,
    failures: failures,
  );
}

void main() {
  testWidgets('详情弹层：所有 ≤13px 文字都达到 4.5:1', (WidgetTester tester) async {
    // 520 而不是 390：flutter_test 默认字体是 Ahem（每字符 1em 方块），
    // 34px 的价格 + 13px 的涨跌在 326dp 的正文宽里会撑破 _Header。
    // 这是测试字体的度量问题，不是布局 bug；换宽视口只为让测量继续。
    tester.view.physicalSize = const Size(520, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final GlobalKey root = GlobalKey();

    // 正常 + 停牌两种状态：状态胶囊的琥珀色是另一套配色，不能只测常见路径
    for (final Quote quote in <Quote>[
      _quote(),
      _quote(status: TradingStatus.suspended),
    ]) {
      await _pumpDetail(tester, root, quote);
      final _Frame frame = await _capture(tester, root);
      final ({int samples, double worst, String worstLabel, List<String> failures})
      r = _audit(tester, root, frame);
      expect(r.samples, greaterThan(10), reason: '取样样本太少，结论不可信');
      // ignore: avoid_print
      print(
        '[A05] 详情/${quote.tradingStatus.label} 最差 '
        '${r.worst.toStringAsFixed(2)}:1（${r.worstLabel}），样本 ${r.samples}',
      );
      expect(
        r.failures,
        isEmpty,
        reason:
            'WCAG 1.4.3：小于 18pt 的正文需 4.5:1。不达标的文字：\n'
            '${r.failures.join('\n')}',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('订阅弹层：所有 ≤13px 文字都达到 4.5:1', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final GlobalKey root = GlobalKey();
    final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      RepaintBoundary(
        key: root,
        child: MaterialApp(
          navigatorKey: nav,
          debugShowCheckedModeBanner: false,
          builder: (BuildContext context, Widget? child) =>
              Material(type: MaterialType.transparency, child: child),
          home: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );
    unawaited(
      showWatchlistSheet(
        nav.currentContext!,
        stocks: const <StockConfig>[_kStock],
        directory: _directory(),
        quota: 30,
      ),
    );
    await tester.pumpAndSettle();

    final _Frame frame = await _capture(tester, root);
    final ({int samples, double worst, String worstLabel, List<String> failures})
    r = _audit(tester, root, frame);
    expect(r.samples, greaterThan(5), reason: '取样样本太少，结论不可信');
    // ignore: avoid_print
    print(
      '[A05] 订阅 最差 ${r.worst.toStringAsFixed(2)}:1（${r.worstLabel}），'
      '样本 ${r.samples}',
    );
    expect(
      r.failures,
      isEmpty,
      reason:
          'WCAG 1.4.3：小于 18pt 的正文需 4.5:1。不达标的文字：\n'
          '${r.failures.join('\n')}',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('WCAG 公式自检：黑白 21:1、同色 1:1', () {
    expect(
      contrastRatio(const Color(0xFF000000), const Color(0xFFFFFFFF)),
      closeTo(21, 0.01),
    );
    expect(
      contrastRatio(const Color(0xFF8B94A3), const Color(0xFF8B94A3)),
      closeTo(1, 0.001),
    );
  });
}
