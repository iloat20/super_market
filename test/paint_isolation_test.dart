import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/widgets/quote_tile.dart';

Quote _quote({double price = 39.20, double changePercent = 1.42, double volume = 12345678}) => Quote(
      code: '000001',
      price: price,
      change: price - 38.65,
      changePercent: changePercent,
      previousClose: 38.65,
      open: 38.80,
      high: 39.40,
      low: 38.60,
      volume: volume,
      turnover: 483920000.0,
      timestamp: DateTime(2026, 11, 4, 9, 35, 10),
    );

const StockConfig _stock = StockConfig(code: '000001', name: '平安银行', region: 'SZ');

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xFFF7F8FA),
        body: Center(child: SizedBox(width: 360, child: child)),
      ),
    );

void main() {
  // 为什么用结构断言而不是数 paint 次数：
  // 在 widget 测试的合成器里，图层树的任何更新都会让外层再画一次，paint 计数
  // 因此无法区分「玻璃重绘」和「图层树更新」。真正要守住的因果是：
  // **内容不是玻璃的子节点**——只有这样，文字更新才不可能把玻璃
  // （背景捕获 + 折射着色）拖下水。这是可静态验证、不会被测试环境噪声
  // 影响的不变量。
  testWidgets('卡片内容不能是玻璃的子节点（玻璃只当背景层）', (WidgetTester tester) async {
    final ValueNotifier<Quote> quote = ValueNotifier<Quote>(_quote());
    addTearDown(quote.dispose);

    await tester.pumpWidget(_host(QuoteTile(stock: _stock, quote: quote)));
    await tester.pumpAndSettle();

    final Finder glass = find.byType(GlassContainer);
    expect(glass, findsOneWidget);

    // 价格文本（会每 3 秒变一次的东西）不能在玻璃的子树里
    final Finder price = find.text('39.20');
    expect(price, findsOneWidget);
    expect(
      find.ancestor(of: price, matching: glass),
      findsNothing,
      reason: '价格画进玻璃 = 每次跳价都要重跑背景捕获与折射着色',
    );

    // 内容层必须自带 RepaintBoundary，才能独立重绘
    expect(
      find.ancestor(of: price, matching: find.byType(RepaintBoundary)),
      findsWidgets,
      reason: '内容层需要自己的边界，价格跳动才只重绘文字',
    );
  });

  testWidgets('同值报文不触发重建（ValueNotifier 在 == 处拦下）', (WidgetTester tester) async {
    final ValueNotifier<Quote> quote = ValueNotifier<Quote>(_quote());
    addTearDown(quote.dispose);
    int builds = 0;

    await tester.pumpWidget(
      _host(
        ValueListenableBuilder<Quote>(
          valueListenable: quote,
          builder: (BuildContext context, Quote q, Widget? _) {
            builds++;
            return QuoteTile(stock: _stock, quote: quote);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final int afterFirst = builds;

    // 重放完全相同的值
    quote.value = _quote();
    await tester.pumpAndSettle();

    expect(builds, afterFirst, reason: '内容没变就不该重建');
  });

  testWidgets('内容变化仍然刷新（隔离不能把更新挡掉）', (WidgetTester tester) async {
    final ValueNotifier<Quote> quote = ValueNotifier<Quote>(_quote());
    addTearDown(quote.dispose);

    await tester.pumpWidget(_host(QuoteTile(stock: _stock, quote: quote)));
    await tester.pumpAndSettle();
    expect(find.text('39.20'), findsOneWidget);

    quote.value = _quote(price: 41.08, changePercent: 6.29);
    await tester.pumpAndSettle();

    expect(find.text('41.08'), findsOneWidget);
    expect(find.text('39.20'), findsNothing);
  });
}
