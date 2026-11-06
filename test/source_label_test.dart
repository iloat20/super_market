/// 详情页脚的来源名必须读**运行期**的 feed，而不是编译期常量。
///
/// 背景：`QuoteFeed.sourceLabel` 的接口注释写着「界面上显示的来源名
/// （轮询可能随主备切换而变）」，实现也确实是 `_chain[_activeIndex]`，
/// 但全仓没有任何生产消费点——页脚取的是 `QuoteFeeds.label`，等于
/// 把「主力源是谁」在编译期写死。主源连败 3 次切到备源后，同一屏里
/// 走势图标注「腾讯」、页脚还写「新浪财经」。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/kline.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/services/kline_loader.dart';
import 'package:super_market/services/source/kline_source.dart';
import 'package:super_market/widgets/quote_detail_sheet.dart';

const StockConfig _kStock = StockConfig(
  code: '600519',
  name: '贵州茅台',
  region: 'SH',
);

final DateTime _kNow = DateTime(2026, 11, 5, 10, 0, 0);

Quote _quote(double price, DateTime stamp) => Quote(
  code: '600519',
  region: 'SH',
  price: price,
  change: 0,
  changePercent: 0,
  previousClose: 1498.30,
  open: 1499.00,
  high: 1502.50,
  low: 1478.10,
  timestamp: stamp,
);

/// 不联网的走势取数器：这块图与本用例无关
class _EmptyLoader extends KlineLoader {
  _EmptyLoader()
    : super(chain: const <KlineSource>[], now: () => DateTime(2026, 11, 5, 15));

  @override
  Future<KlineResult<Kline>> loadDaily(StockConfig stock, {int? count}) async =>
      KlineResult<Kline>(items: <Kline>[], sourceId: 'sina');

  @override
  Future<KlineResult<IntradayPoint>> loadIntraday(StockConfig stock) async =>
      KlineResult<IntradayPoint>(items: <IntradayPoint>[], sourceId: 'sina');
}

void main() {
  testWidgets('页脚来源名跟着 feed 变：切到备源后不再写死「新浪财经」', (
    WidgetTester tester,
  ) async {
    String label = '新浪财经';
    final ValueNotifier<Quote> notifier = ValueNotifier<Quote>(
      _quote(1486.00, _kNow.subtract(const Duration(seconds: 3))),
    );
    addTearDown(notifier.dispose);

    await tester.pumpWidget(
      MaterialApp(
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
                      quote: notifier,
                      loader: _EmptyLoader(),
                      // getter：每次 build 现取，而不是打开瞬间的快照
                      sourceLabel: () => label,
                      now: () => _kNow,
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

    expect(find.textContaining('轮询更新 · 新浪财经'), findsOneWidget);

    // 主备切换：feed 的 sourceLabel 变了，弹层还开着
    label = '腾讯财经';
    notifier.value = _quote(1487.00, _kNow.subtract(const Duration(seconds: 1)));
    await tester.pump();

    expect(
      find.textContaining('腾讯财经'),
      findsOneWidget,
      reason: '页脚必须读运行期来源名；写死常量会让同一屏里 '
          '走势图说「腾讯」、页脚说「新浪」',
    );
    expect(find.textContaining('新浪财经'), findsNothing);
  });
}
