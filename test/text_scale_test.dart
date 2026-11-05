import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/pages/quote_list_page.dart';
import 'package:super_market/services/kline_loader.dart';
import 'package:super_market/services/local_store.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/services/symbol_directory.dart';
import 'package:super_market/widgets/quote_detail_sheet.dart';
import 'package:super_market/widgets/quote_tile.dart';
import 'package:super_market/widgets/watchlist_sheet.dart';

import 'fake_feed.dart';

/// 系统字体放大到 3.0 倍时，布局崩不崩、信息丢不丢。
///
/// `layout_robustness_test.dart` 最高只到 2.0x，且没有弹层用例。
///
/// ## 两个验收条件，不是一条
///
/// 「不溢出」只是底线。3.0x 修完溢出之后，八宫格把「1499.00」显示成
/// 「149…」、订阅列表把「贵州茅台」显示成「贵…」——`RenderFlex` 一声不吭，
/// 测试照样全绿，可主要内容已经没了。所以每个弹层用例都跑：
///
/// 1. `takeException()` 为空 —— 没有 RenderFlex 溢出；
/// 2. `_expectNothingTruncated` —— 没有被省略号截断的文字；
/// 3. `_expectNoOverShrink` —— `FittedBox` 兜底的值没有被缩到 75% 以下。
///
/// 第 3 条是补出来的：`FittedBox(scaleDown)` 只缩不截断，`didExceedMaxLines`
/// 永远是 false。只写第 2 条时，把单列判断关掉测试依然全绿（真的假绿过一次）。
///
/// ## 修复方式（2026-11-05）
///
/// 空间不够时**改布局**，不是把字缩回去：
/// - `_Header` 名称/代码、价格/涨跌 → `Wrap`，够宽时单行（1.0x 像素不变）；
/// - 价格、涨跌 → 限 1.3x（`TextScaler.clamp`），保证它是一整个数字；
/// - 八宫格 → 单格装不下一整个价格时改单列；
/// - 订阅列表名称/代码 → 放不下时上下堆叠；
/// - 数据来源、搜索提示、状态胶囊行 → 允许折行 / `Wrap` 重排。
///
/// 1.0x 的 6 张 golden 逐字节不变，是本批的硬约束。
///
/// 注意 flutter_test 默认字体是 Ahem（每字符 = 1em 方块），比真机字体宽
/// 近一倍——这里的宽度结论是**下界**，Ahem 下不溢出则真机更不会。
/// 但「放不下就改布局」的判断阈值是按这个下界定的，真机上会更早触发堆叠。

const double _kScale = 3.0;
const StockConfig _kStock = StockConfig(
  code: '600519',
  name: '贵州茅台',
  region: 'SH',
);

Widget _host(Widget child) {
  return MaterialApp(
    builder: (BuildContext context, Widget? inner) {
      final MediaQueryData data = MediaQuery.of(context);
      return MediaQuery(
        data: data.copyWith(textScaler: TextScaler.linear(_kScale)),
        child: inner ?? const SizedBox.shrink(),
      );
    },
    home: Scaffold(body: child),
  );
}

Quote _quote() => Quote(
  code: '600519',
  region: 'SH',
  price: 1439.10,
  change: 47.05,
  changePercent: 3.38,
  previousClose: 1392.05,
  open: 1410,
  high: 1447,
  low: 1395.02,
  volume: 82691,
  turnover: 11849258015,
  timestamp: DateTime(2026, 11, 3, 7, 52, 10),
);

KlineLoader _fakeLoader() => KlineLoader(
  httpGet: (Uri uri, Map<String, String> headers) async =>
      const HttpRawResponse(statusCode: 502, body: <int>[]),
);

SymbolDirectory _fakeDirectory() => SymbolDirectory(
  store: MemoryKeyValueStore(),
  httpGet: (Uri uri, Map<String, String> headers) async =>
      const HttpJsonResponse(statusCode: 200, body: '[]'),
  httpGetBytes: (Uri uri, Map<String, String> headers) async =>
      const HttpRawResponse(statusCode: 200, body: <int>[]),
);

/// 指标值用 `FittedBox(scaleDown)` 兜底，所以「截断」检测不到它——
/// `didExceedMaxLines` 永远是 false，真正发生的是**字号被缩小**。
/// 缩小本身是可接受的（07:52:10 在 3.0x 下要 372dp，缩到 0.88 无感），
/// 但两列布局下会缩到 0.48，那就不是「放大 3 倍」了。这里把缩放比
/// 也钉住，否则关掉单列判断测试也不会红（曾经真的这样假绿过一次）。
void _expectNoOverShrink(WidgetTester tester, {double minScale = 0.75}) {
  for (final FittedBox box in tester.widgetList<FittedBox>(
    find.byType(FittedBox, skipOffstage: false),
  )) {
    final Widget? child = box.child;
    if (child is! Text || child.style?.fontSize != 15.5) {
      continue; // 只查八宫格的值
    }
    final Size boxSize = tester.getSize(find.byWidget(box));
    final Size textSize = tester.getSize(
      find.descendant(of: find.byWidget(box), matching: find.byType(RichText)),
    );
    final double scale = boxSize.width / textSize.width;
    expect(
      scale,
      greaterThanOrEqualTo(minScale),
      reason:
          '「${child.data}」被缩到 ${(scale * 100).round()}%，'
          '这已经不是「跟随系统字体放大」了；应改布局（单列）而不是继续缩。',
    );
  }
}

/// 「不溢出」不等于「没丢信息」：3.0x 下八宫格曾把「1499.00」省略成
/// 「149…」、订阅列表把「贵州茅台」省略成「贵…」——RenderFlex 一声不吭，
/// 测试全绿，可主要内容已经没了。这里直接查渲染结果。
void _expectNothingTruncated(WidgetTester tester) {
  final List<String> truncated = <String>[];
  for (final RichText rich in tester.widgetList<RichText>(
    find.byType(RichText, skipOffstage: false),
  )) {
    final RenderParagraph p = tester.renderObject<RenderParagraph>(
      find.byWidget(rich),
    );
    if (p.didExceedMaxLines) {
      truncated.add(rich.text.toPlainText());
    }
  }
  expect(
    truncated,
    isEmpty,
    reason:
        '3.0x 下这些文字被省略号截断了（内容丢失，不是布局问题）：'
        '\n${truncated.join('\n')}',
  );
}

void main() {
  testWidgets('3.0x：列表页不溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _host(
        QuoteListPage(
          serviceBuilder: NoopFeed.builder,
          clock: () => DateTime(2026, 11, 2, 16, 30),
        ),
      ),
    );
    await tester.pump();
    expect(
      tester.takeException(),
      isNull,
      reason: '3.0x 下 RenderFlex 溢出会在这里抛 FlutterError',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('3.0x：行情卡不溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final ValueNotifier<Quote> q = ValueNotifier<Quote>(_quote());
    addTearDown(q.dispose);
    await tester.pumpWidget(
      _host(
        Padding(
          padding: const EdgeInsets.all(12),
          child: QuoteTile(
            stock: AppConfig.stocks[1],
            quote: q,
            // 钉住时钟：报价时间 07:52，这里 07:55，差 3 分钟 → 仍算实时。
            // 不注入就会读真实墙钟，「有没有快照角标」随运行日期漂移。
            now: () => DateTime(2026, 11, 3, 7, 55),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('3.0x：详情弹层不溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final ValueNotifier<Quote> q = ValueNotifier<Quote>(_quote());
    addTearDown(q.dispose);
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {
                  unawaited(
                    showQuoteDetailSheet(
                      context,
                      stock: _kStock,
                      quote: q,
                      loader: _fakeLoader(),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    _expectNothingTruncated(tester);
    _expectNoOverShrink(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('3.0x：订阅弹层不溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(const Scaffold(body: SizedBox.expand())));
    final BuildContext context = tester.element(find.byType(Scaffold).first);
    unawaited(
      showWatchlistSheet(
        context,
        stocks: const <StockConfig>[_kStock],
        directory: _fakeDirectory(),
        quota: 3,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    _expectNothingTruncated(tester);
    _expectNoOverShrink(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
