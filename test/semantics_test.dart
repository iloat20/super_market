import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/services/kline_loader.dart';
import 'package:super_market/services/local_store.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/services/symbol_directory.dart';
import 'package:super_market/widgets/quote_detail_sheet.dart';
import 'package:super_market/widgets/quote_tile.dart';
import 'package:super_market/widgets/watchlist_sheet.dart';

/// A09（S3a）：语义层覆盖 + A04 的 hint 矛盾。
///
/// 用纯 `Semantics` / `ExcludeSemantics` 断言，零可见文字变化。
/// 红态预期：图表无任何语义节点、八宫格颜色无文字等价物、搜索框只有
/// hintText（输入后即消失）、结果行没有 button 语义、卡片 hint 仍写「双击」。

const StockConfig _kStock = StockConfig(
  code: '600519',
  name: '贵州茅台',
  region: 'SH',
);

const String _kSuggest =
    '{"QuotationCodeTable":{"Data":[{"Code":"600519","Name":"贵州茅台",'
    '"MarketType":"1"}],"Status":0}}';

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

bool _hasLabel(WidgetTester tester, Pattern pattern) => find
    .byWidgetPredicate(
      (Widget w) =>
          w is Semantics && (w.properties.label ?? '').contains(pattern),
    )
    .evaluate()
    .isNotEmpty;

bool _hasHint(WidgetTester tester, Pattern pattern) => find
    .byWidgetPredicate(
      (Widget w) =>
          w is Semantics && (w.properties.hint ?? '').contains(pattern),
    )
    .evaluate()
    .isNotEmpty;

/// 必须返回合法分时数据：502 会让图表区显示「走势暂不可用」，
/// KlineChart 根本不渲染，语义断言就测不到被测组件（假绿）。
KlineLoader _fakeLoader() => KlineLoader(
      httpGet: (Uri uri, Map<String, String> headers) async {
        const String intraday = '''
{"result":{"status":{"code":0},"data":[
 {"day":"2026-11-03 09:30:00","open":"1450","high":"1450","low":"1450","close":"1450","volume":"165000","amount":"239250000"},
 {"day":"2026-11-03 10:44:00","open":"1440","high":"1450","low":"1439","close":"1446.30","volume":"120000","amount":"173000000"}]}}''';
        return HttpRawResponse(statusCode: 200, body: utf8.encode(intraday));
      },
    );

SymbolDirectory _fakeDirectory() => SymbolDirectory(
      store: MemoryKeyValueStore(),
      httpGet: (Uri uri, Map<String, String> headers) async =>
          const HttpJsonResponse(statusCode: 200, body: '[]'),
      httpGetBytes: (Uri uri, Map<String, String> headers) async =>
          HttpRawResponse(statusCode: 200, body: utf8.encode(_kSuggest)),
    );

/// 必须让 KlineChart 真的渲染（见 _fakeLoader 注释），否则图表语义断言
/// 测的是「走势暂不可用」占位符，属假覆盖。
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
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('详情弹层：自绘图表有概述语义', (WidgetTester tester) async {
    await _openDetail(tester);
    expect(_hasLabel(tester, '走势图'), isTrue,
        reason: 'CustomPaint 自绘图表对读屏完全不可见，必须有概述语义');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('详情弹层：八宫格方向有文字等价语义', (WidgetTester tester) async {
    await _openDetail(tester);
    expect(_hasLabel(tester, '高于昨收'), isTrue,
        reason: '今开/最高/最低只靠红绿上色，需要文字等价物');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('订阅弹层：搜索框持久 label + 结果行 button 语义', (
    WidgetTester tester,
  ) async {
    final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    unawaited(showWatchlistSheet(
      nav.currentContext!,
      stocks: const <StockConfig>[
        StockConfig(code: '000001', name: '平安银行', region: 'SZ'),
      ],
      directory: _fakeDirectory(),
      quota: 3,
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '茅台');
    await tester.pump(AppConfig.searchDebounce + const Duration(milliseconds: 1));
    await tester.pumpAndSettle();

    expect(_hasLabel(tester, '搜代码或名称'), isTrue,
        reason: 'hintText 输入后消失，读屏聚焦时需要持久字段名');
    expect(
      find
          .byWidgetPredicate(
            (Widget w) =>
                w is Semantics &&
                w.properties.button == true &&
                (w.properties.label ?? '').contains('添加'),
          )
          .evaluate()
          .isNotEmpty,
      isTrue,
      reason: '结果行要能读成「添加 贵州茅台」，而不是一段散碎文字',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('A04：行情卡 hint 与单击手势一致', (WidgetTester tester) async {
    final ValueNotifier<Quote> q = ValueNotifier<Quote>(_quote());
    addTearDown(q.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuoteTile(stock: _kStock, quote: q, onTap: () {}),
        ),
      ),
    );
    await tester.pump();
    expect(_hasHint(tester, '双击'), isFalse,
        reason: 'InkWell 是 onTap 单击，hint 不能写「双击」');
    expect(_hasHint(tester, '单击'), isTrue,
        reason: '修正后应明确写成单击');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
