import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/services/kline_loader.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/widgets/kline_chart.dart';
import 'package:super_market/widgets/quote_detail_sheet.dart';

/// 详情弹层的**绘制分层**：玻璃不参与跳价重建，内容自带图层，静态的日 K
/// 不被"只有成交额变了"的报文重新栅格化。
///
/// 和 `test/paint_isolation_test.dart` 对列表卡片守的是同一组不变量。
/// v15 起详情弹层的玻璃从自绘 `GlassPanel` 换成 `GlassContainer.card`
/// + `kGlassSurface` premium，断言对象也跟着换成 `GlassContainer`：
/// 守的是「玻璃在监听器外面 / 内容不是玻璃子节点 / 内容自带
/// RepaintBoundary」这条**结构**，不是某个具体 Widget 类名。
/// 为什么必须是断言：一旦回退，表现只是"每 3 秒卡一下"，肉眼很难归因。

const StockConfig _maotai = StockConfig(
  code: '600519',
  name: '贵州茅台',
  region: 'SH',
);

const String _intraday = '''
{"result":{"status":{"code":0},"data":[
 {"day":"2026-11-03 09:30:00","open":"1450","high":"1450","low":"1450","close":"1450","volume":"165000","amount":"239250000"},
 {"day":"2026-11-03 09:31:00","open":"1450","high":"1451","low":"1436","close":"1436","volume":"162000","amount":"233109222"},
 {"day":"2026-11-03 10:44:00","open":"1440","high":"1450","low":"1439","close":"1446.30","volume":"120000","amount":"173000000"}]}}''';

const String _daily = '''
{"result":{"status":{"code":0},"data":[
 {"day":"2026-10-30","open":"1363.000","high":"1393.370","low":"1352.980","close":"1392.050","volume":"5992729"},
 {"day":"2026-11-02","open":"1410.000","high":"1447.000","low":"1395.020","close":"1439.100","volume":"8269122"}]}}''';

KlineLoader _loader() => KlineLoader(
  httpGet: (Uri uri, Map<String, String> headers) async {
    final bool isDaily = uri.queryParameters['scale'] == '240';
    return HttpRawResponse(
      statusCode: 200,
      body: utf8.encode(isDaily ? _daily : _intraday),
    );
  },
);

Quote _quote({double turnover = 3658010435}) => Quote(
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
  turnover: turnover,
  timestamp: DateTime(2026, 11, 3, 10, 45),
);

Future<ValueNotifier<Quote>> _openSheet(WidgetTester tester) async {
  final ValueNotifier<Quote> notifier = ValueNotifier<Quote>(_quote());
  addTearDown(notifier.dispose);

  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showQuoteDetailSheet(
                context,
                stock: _maotai,
                quote: notifier,
                loader: _loader(),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return notifier;
}

void main() {
  testWidgets('跳价不重建玻璃，内容不是玻璃子节点且自带独立图层', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<Quote> notifier = await _openSheet(tester);

    final Finder glass = find.byType(GlassContainer);
    expect(
      glass,
      findsOneWidget,
      reason: '详情弹层的玻璃背景层必须是 GlassContainer.card（v15）',
    );
    final GlassContainer before = tester.widget<GlassContainer>(glass);

    // 只有成交额变了：界面上看起来什么都没动
    notifier.value = _quote(turnover: 9999999999);
    await tester.pump();

    final GlassContainer after = tester.widget<GlassContainer>(glass);
    expect(
      identical(before, after),
      isTrue,
      reason: '玻璃必须在监听器外面：否则每 3 秒一次跳价都会重建 premium '
          '玻璃的背景捕获与折射着色（与 quote_tile.dart 的做法对齐）',
    );

    final Finder content = find.text('今开');
    expect(
      find.ancestor(of: content, matching: glass),
      findsNothing,
      reason: '内容画进玻璃子树 = 每次跳价都要重跑背景捕获与折射着色；'
          'v15 的 Stack 分层要求两者平级',
    );
    expect(
      find.ancestor(of: content, matching: find.byType(RepaintBoundary)),
      findsWidgets,
      reason: '内容层需要自己的 RepaintBoundary，跳价才只重绘文字层',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('日 K：只有成交额变化时，bars 必须是同一个 List 实例', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<Quote> notifier = await _openSheet(tester);

    await tester.tap(find.text('日K'));
    await tester.pumpAndSettle();

    final KlineChart before = tester.widget<KlineChart>(find.byType(KlineChart));
    expect(before.mode, ChartMode.daily);
    expect(before.bars.length, 3, reason: '2 根历史 + 1 根由实时报价拼出的今日');

    // OHLC / 量 / 时间戳全部不变，只有成交额变（真实盘口的常态）
    notifier.value = _quote(turnover: 9999999999);
    await tester.pump();

    final KlineChart after = tester.widget<KlineChart>(find.byType(KlineChart));
    expect(
      identical(before.bars, after.bars),
      isTrue,
      reason: '日 K 外面套着 RepaintBoundary，但 shouldRepaint 用的是 identical：'
          '每次 tick 新建 List 会让 240~480 根蜡烛全量重新栅格化',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
