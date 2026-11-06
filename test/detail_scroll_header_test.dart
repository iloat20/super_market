import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/services/kline_loader.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/widgets/glass.dart';
import 'package:super_market/widgets/quote_detail_sheet.dart';

/// 详情弹层「滚动时的头部表现」。
///
/// 弹层内容超过 86% 屏高时是可滚动的，但原来整块内容（含拖拽条与标题）
/// 一起滚走，滚到指标区时头部没有东西接住 —— 内容直接贴着玻璃边缘过去，
/// 既读不出「这是一块有顶边的玻璃」，也没有 iOS 那种内容从栏下滑过的层次。
///
/// 这两条断言同时守住性能：静止时**不能多画任何一层**（golden 必须零变化），
/// 滚动时玻璃面板本身不能被重建（否则每帧重跑一次 sigma=18 的模糊）。
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

KlineLoader _loader() => KlineLoader(
  httpGet: (Uri uri, Map<String, String> headers) async =>
      HttpRawResponse(statusCode: 200, body: utf8.encode(_intraday)),
);

Quote _quote() => Quote(
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
);

Future<void> _openSheet(WidgetTester tester) async {
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
}

void main() {
  testWidgets('静止不画磨砂带；内容上滑后顶部出现玻璃分隔且不重建玻璃面板', (WidgetTester tester) async {
    // 刻意用小屏：保证详情内容真的超过 86% 屏高、可滚动
    tester.view.physicalSize = const Size(360, 440);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _openSheet(tester);

    const Key scrimKey = Key('detailHeaderScrim');
    expect(
      find.byKey(scrimKey),
      findsNothing,
      reason:
          'offset=0 时必须零额外图层，否则 detail / detail-daily 两份 '
          'golden 会无端变化',
    );

    final GlassPanel panelBefore = tester.widget<GlassPanel>(
      find.byType(GlassPanel),
    );
    final double beforeY = tester.getTopLeft(find.text('今开')).dy;

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.text('今开')).dy,
      lessThan(beforeY),
      reason: '测试面必须小到内容确实滚动了，否则下面的断言会假绿/假红',
    );
    expect(
      find.byKey(scrimKey),
      findsOneWidget,
      reason:
          '内容滑到头部底下时，顶部应浮出一条磨砂玻璃带，'
          '把「栏」和「可滚动内容」分开',
    );
    expect(
      identical(
        panelBefore,
        tester.widget<GlassPanel>(find.byType(GlassPanel)),
      ),
      isTrue,
      reason:
          '滚动只该重建隔离层里的一小条 overlay；'
          '若 GlassPanel 被重建，每帧都要重跑一次 sigma=18 的全面板模糊',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
