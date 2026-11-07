import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/widgets/quote_tile.dart';

/// 价格「落地感」的守门（ROADMAP 之外的动效升级，2026-11-06）。
///
/// 三条必须守住的边界，任何一条破了这个动画就该删掉：
/// 1. **阈值**：只有单批变化 ≥ 0.1% 才弹。行情是 3 秒批量轮询，六只票一起到，
///    没有阈值就是整屏节拍器；
/// 2. **不误触**：首帧占位（`--` → 价格）不弹——否则页面一出来六张卡齐弹；
/// 3. **减动优先**：系统开启「减少动态效果」时不动，也不建帧。
///
/// 断言的是 `Transform` 的缩放值，不是像素：这条动画的契约就是"纯绘制变换，
/// 不改布局"，所以只要矩阵回到了 1.0，就说明它没有污染排版。
const StockConfig _stock = StockConfig(
  code: '000651',
  name: '格力电器',
  region: 'SZ',
);

final DateTime _now = DateTime(2026, 11, 6, 10, 30);

Quote _quote(double price) => Quote(
  code: '000651',
  region: 'SZ',
  price: price,
  change: 0.2,
  changePercent: 0.5,
  previousClose: price - 0.2,
  timestamp: _now,
);

Widget _host(Widget child, {bool reduce = false}) {
  return MaterialApp(
    builder: (BuildContext context, Widget? inner) {
      return MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
        child: inner ?? const SizedBox.shrink(),
      );
    },
    home: Scaffold(
      body: Center(child: SizedBox(width: 360, child: child)),
    ),
  );
}

/// 取价格所在 `Transform` 的缩放值。
double _priceScale(WidgetTester tester, String text) {
  final Finder hit = find.ancestor(
    of: find.text(text),
    matching: find.byType(Transform),
  );
  expect(hit, findsWidgets, reason: '价格外面没有 Transform，动画结构变了');
  return tester.widget<Transform>(hit.first).transform.getMaxScaleOnAxis();
}

Future<void> _pumpTile(WidgetTester tester, ValueNotifier<Quote> quote,
    {bool reduce = false}) async {
  await tester.pumpWidget(
    _host(
      QuoteTile(stock: _stock, quote: quote, now: () => _now),
      reduce: reduce,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('价格跳 1%：弹一下，160ms 后回到原尺寸', (WidgetTester tester) async {
    final ValueNotifier<Quote> quote = ValueNotifier<Quote>(_quote(39.20));
    addTearDown(quote.dispose);
    await _pumpTile(tester, quote);

    expect(_priceScale(tester, '39.20'), 1.0, reason: '首帧不该在动');

    quote.value = _quote(39.60); // +1.02%
    await tester.pump();
    expect(
      _priceScale(tester, '39.60'),
      closeTo(1.06, 0.01),
      reason: '过阈值应当从 1.06 起跳',
    );

    await tester.pumpAndSettle();
    expect(_priceScale(tester, '39.60'), 1.0, reason: '动画结束必须回到 1.0，否则排版被污染');
  });

  testWidgets('价格只跳 0.025%：低于阈值，不弹', (WidgetTester tester) async {
    final ValueNotifier<Quote> quote = ValueNotifier<Quote>(_quote(39.20));
    addTearDown(quote.dispose);
    await _pumpTile(tester, quote);

    quote.value = _quote(39.21); // +0.025%，属于轮询抖动
    await tester.pump();
    expect(
      _priceScale(tester, '39.21'),
      1.0,
      reason: '没有阈值的话，六只票每 3 秒会一起弹一次',
    );
  });

  testWidgets('占位 → 有价格：不弹（首帧不齐跳）', (WidgetTester tester) async {
    final ValueNotifier<Quote> quote = ValueNotifier<Quote>(
      Quote.empty('000651', region: 'SZ'),
    );
    addTearDown(quote.dispose);
    await _pumpTile(tester, quote);
    // 价格与涨跌胶囊都会显示 '--'，两处
    expect(find.text('--'), findsWidgets);

    quote.value = _quote(39.20);
    await tester.pump();
    expect(_priceScale(tester, '39.20'), 1.0);
  });

  testWidgets('减少动态效果：不弹，也不建帧', (WidgetTester tester) async {
    final ValueNotifier<Quote> quote = ValueNotifier<Quote>(_quote(39.20));
    addTearDown(quote.dispose);
    await _pumpTile(tester, quote, reduce: true);

    quote.value = _quote(39.90); // +1.8%，肯定过阈值
    await tester.pump();

    expect(_priceScale(tester, '39.90'), 1.0);
    expect(
      tester.binding.hasScheduledFrame,
      isFalse,
      reason: '减动模式下不能有动画在排帧——那还是会耗电',
    );
  });
}
