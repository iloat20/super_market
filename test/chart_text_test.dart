/// A10 的**方向词部分**：八宫格的今开/最高/最低在颜色之外给出可见文字。
///
/// A10 的「图下区间摘要」已于 2026-11-05 整体移除（见 README 二·三十一）：
/// 用户拍板图下不放文字，图表只留像素。方向词是八宫格的，不依赖摘要。
///
/// 红态（改动前）：
/// - 八宫格的今开/最高/最低只有颜色，没有「高于/低于昨收」的字样
///   （`Semantics` 里有，但那只对读屏可见）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/kline.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/services/kline_loader.dart';
import 'package:super_market/services/source/kline_source.dart';
import 'package:super_market/widgets/kline_chart.dart';
import 'package:super_market/widgets/quote_detail_sheet.dart';

const StockConfig _kStock = StockConfig(
  code: '600519',
  name: '贵州茅台',
  region: 'SH',
);

/// 昨收 1498.30；今开/最高在昨收之上，最低在昨收之下 —— 三个方向词各出现一次。
Quote _quote() => Quote(
  code: '600519',
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

class _FakeLoader extends KlineLoader {
  _FakeLoader()
    : super(chain: const <KlineSource>[], now: () => DateTime(2026, 11, 5, 15));

  @override
  Future<KlineResult<Kline>> loadDaily(StockConfig stock, {int? count}) async {
    return KlineResult<Kline>(
      items: <Kline>[
        Kline(
          time: DateTime(2026, 11, 2),
          open: 1470,
          high: 1490,
          low: 1465,
          close: 1488,
          volume: 1000,
        ),
        Kline(
          time: DateTime(2026, 11, 3),
          open: 1488,
          high: 1500,
          low: 1475,
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
        _pt(9, 30, 1499),
        _pt(10, 42, 1502.5),
        _pt(11, 15, 1493.2),
        _pt(14, 36, 1478.1),
        _pt(15, 0, 1486),
      ],
      sourceId: 'sina',
    );
  }

  static IntradayPoint _pt(int h, int m, double price) => IntradayPoint(
    time: DateTime(2026, 11, 5, h, m),
    price: price,
    avgPrice: price,
    volume: 100,
  );
}

Future<void> _openDetail(WidgetTester tester) async {
  final ValueNotifier<Quote> q = ValueNotifier<Quote>(_quote());
  addTearDown(q.dispose);
  await tester.pumpWidget(
    MaterialApp(
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
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('A10：八宫格有可见方向词（不只是颜色）', (WidgetTester tester) async {
    // 520 而不是 390：Ahem 字体（flutter_test 默认）下，34px 价格 +
    // 13px 涨跌会把 _Header 撑破。那是测试字体度量问题，不是布局 bug。
    tester.view.physicalSize = const Size(520, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _openDetail(tester);
    // 今开 1499.00 > 昨收 1498.30、最高 1502.50 > 昨收 → 两条「高于昨收」
    expect(find.text('高于昨收'), findsNWidgets(2));
    // 最低 1478.10 < 昨收 → 一条「低于昨收」
    expect(find.text('低于昨收'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('A10：方向词随昨收翻转（反向红态，防恒真）', () {
    // 同一组价格，把昨收抬到最高价之上，三条方向词必须整体翻转
    expect(noteFor(1499.00, 1510), '低于昨收');
    expect(noteFor(1502.50, 1510), '低于昨收');
    expect(noteFor(1478.10, 1460), '高于昨收');
    expect(noteFor(1498.30, 1498.30), '与昨收持平');
    expect(noteFor(0, 1498.30), isNull);
  });
}
