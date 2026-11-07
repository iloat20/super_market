import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/services/kline_loader.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/widgets/quote_detail_sheet.dart';
import 'package:super_market/widgets/taiji_mark.dart';

/// A07：响应系统「减少动态效果」（S2 / B8 + B10）。
///
/// 三条断言的分工：
/// 1. 开关打开 + **行情到达** → 太极必须不动（红态：门控缺失时会转一格）；
/// 2. 开关关闭 + **行情到达** → 太极**仍要转**（防误改默认态，与
///    `header_taiji_test.dart` 的排帧断言同向）；
/// 3. 开关打开 → 分时/日K 的 AnimatedContainer 过渡归零（红态：当前 160ms）。
///
/// 注意两条太极用例都必须**主动推一个 tick**：太极自 P1-5 起由数据驱动，
/// 不推 tick 的话它本来就不动，断言会退化成"什么都没发生也是绿"。
///
/// 默认态渲染像素零变化：门控只在系统开关打开时生效。

const StockConfig _kStock = StockConfig(
  code: '600519',
  name: '贵州茅台',
  region: 'SH',
);

Widget _host(Widget child, {required bool reduce}) {
  return MaterialApp(
    builder: (BuildContext context, Widget? inner) {
      return MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
        child: inner ?? const SizedBox.shrink(),
      );
    },
    home: Scaffold(body: child),
  );
}

Future<ValueNotifier<int>> _pumpMark(
  WidgetTester tester, {
  required bool reduce,
  bool tick = true,
}) async {
  final ValueNotifier<int> ticks = ValueNotifier<int>(0);
  addTearDown(ticks.dispose);
  await tester.pumpWidget(
    _host(
      TaijiMark(
        now: () => DateTime(2026, 11, 2, 14, 0), // 周一 14:00，A 股交易中
        regions: const <String>['SH'],
        ticks: ticks,
      ),
      reduce: reduce,
    ),
  );
  await tester.pump();
  // 推一格：太极只在「有行情到达」时才动，不推就永远静止，
  // 那样这条用例会退化成「什么都没发生也是绿」
  if (tick) {
    ticks.value++;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
  }
  return ticks;
}

KlineLoader _fakeLoader() => KlineLoader(
      httpGet: (Uri uri, Map<String, String> headers) async =>
          const HttpRawResponse(statusCode: 502, body: <int>[]),
    );

void main() {
  testWidgets('减少动效开启：行情到达也不转', (WidgetTester tester) async {
    await _pumpMark(tester, reduce: true);
    expect(tester.binding.hasScheduledFrame, isFalse,
        reason: '系统要求减少动效时，装饰性旋转必须停');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('默认态（未开减少动效）：行情到达仍然转一格', (
    WidgetTester tester,
  ) async {
    await _pumpMark(tester, reduce: false);
    expect(tester.binding.hasScheduledFrame, isTrue,
        reason: '默认态不能被门控误伤');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('减少动效开启：分时/日K 切换无过渡动画', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<Quote> q = ValueNotifier<Quote>(
      Quote(
        code: '600519',
        region: 'SH',
        price: 1451.01,
        change: 11.91,
        changePercent: 0.83,
        previousClose: 1439.1,
        open: 1450,
        high: 1458,
        low: 1435,
        volume: 2532700,
        turnover: 3658010435,
        timestamp: DateTime(2026, 11, 3, 10, 45),
      ),
    );
    addTearDown(q.dispose);

    await tester.pumpWidget(
      _host(
        Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {
                  unawaited(showQuoteDetailSheet(
                    context,
                    stock: _kStock,
                    quote: q,
                    loader: _fakeLoader(),
                  ));
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
        reduce: true,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final AnimatedContainer container = tester.widget<AnimatedContainer>(
      find.byType(AnimatedContainer).first,
    );
    expect(container.duration, Duration.zero,
        reason: '减少动效下 tab 切换过渡应归零（当前 160ms）');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
