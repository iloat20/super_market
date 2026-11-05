import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/pages/quote_list_page.dart';
import 'package:super_market/services/kline_loader.dart';
import 'package:super_market/services/local_store.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/services/symbol_directory.dart';
import 'package:super_market/widgets/hit_target.dart';
import 'package:super_market/widgets/quote_detail_sheet.dart';
import 'package:super_market/widgets/watchlist_sheet.dart';

import 'fake_feed.dart';

/// A01：7 类小控件的 48dp 触控目标。
///
/// 采用「零视觉变化」方案：用 [HitTarget] 只放宽命中区，不撑大布局占位。
/// 断言分两层：
/// 1. 组件级行为 —— 越界 4dp 仍能命中，且 child 尺寸逐字节不变（golden 不变）；
/// 2. 装配级不变量 —— 每一处控件都必须被 [HitTarget] 包住，minSize ≥48。
/// 第 2 层在装配前会逐条变红，去掉任一处 HitTarget 也会立刻红。

Finder _hitOf(Finder child) =>
    find.ancestor(of: child, matching: find.byType(HitTarget));

void _expectHit(
  WidgetTester tester,
  Finder child,
  String label, {
  bool compact = true,
}) {
  final Finder hit = _hitOf(child);
  expect(hit, findsOneWidget, reason: '$label 必须被 HitTarget 包住');
  final HitTarget w = tester.widget<HitTarget>(hit);
  expect(w.minSize.width, greaterThanOrEqualTo(48), reason: '$label 命中宽');
  expect(w.minSize.height, greaterThanOrEqualTo(48), reason: '$label 命中高');

  // 零视觉变化的核心证据：命中区扩到 48，但布局占位仍是原来的小尺寸。
  // 这条把「平台标准撑高」方案直接钉死——它一定会让 getRect 变 48。
  final double height = tester.getRect(hit).height;
  if (compact) {
    expect(height, lessThan(48), reason: '$label 布局占位不得被撑到 48（实际 $height）');
  } else {
    expect(height, lessThan(56), reason: '$label 布局占位不得增长（实际 $height）');
  }
}

Widget _probe({required bool wrapped, required VoidCallback onTap}) {
  final Widget child = GestureDetector(
    key: const Key('probe'),
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: const SizedBox(width: 28, height: 28),
  );
  return MaterialApp(
    home: Center(child: wrapped ? HitTarget(child: child) : child),
  );
}

const StockConfig _kStock = StockConfig(
  code: '600519',
  name: '贵州茅台',
  region: 'SH',
);

const String _kSuggest =
    '{"QuotationCodeTable":{"Data":[{"Code":"600519","Name":"贵州茅台",'
    '"MarketType":"1"}],"Status":0}}';

const String _kIntraday = '''
{"result":{"status":{"code":0},"data":[
 {"day":"2026-11-03 09:30:00","open":"1450","high":"1450","low":"1450","close":"1450","volume":"165000","amount":"239250000"},
 {"day":"2026-11-03 09:31:00","open":"1450","high":"1451","low":"1436","close":"1436","volume":"162000","amount":"233109222"},
 {"day":"2026-11-03 10:44:00","open":"1440","high":"1450","low":"1439","close":"1446.30","volume":"120000","amount":"173000000"}]}}''';

const String _kDaily = '''
{"result":{"status":{"code":0},"data":[
 {"day":"2026-10-30","open":"1363.000","high":"1393.370","low":"1352.980","close":"1392.050","volume":"5992729"},
 {"day":"2026-11-02","open":"1410.000","high":"1447.000","low":"1395.020","close":"1439.100","volume":"8269122"}]}}''';

SymbolDirectory _directory() => SymbolDirectory(
  store: MemoryKeyValueStore(),
  httpGet: (Uri uri, Map<String, String> headers) async =>
      const HttpJsonResponse(statusCode: 200, body: '[]'),
  httpGetBytes: (Uri uri, Map<String, String> headers) async =>
      HttpRawResponse(statusCode: 200, body: utf8.encode(_kSuggest)),
);

KlineLoader _loader() => KlineLoader(
  httpGet: (Uri uri, Map<String, String> headers) async {
    final bool daily = uri.queryParameters['scale'] == '240';
    return HttpRawResponse(
      statusCode: 200,
      body: utf8.encode(daily ? _kDaily : _kIntraday),
    );
  },
);

Future<void> _openWatchlist(WidgetTester tester, {String query = ''}) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: nav,
      home: const Scaffold(body: SizedBox.expand()),
    ),
  );
  unawaited(
    showWatchlistSheet(
      nav.currentContext!,
      stocks: const <StockConfig>[
        StockConfig(code: '000001', name: '平安银行', region: 'SZ'),
      ],
      directory: _directory(),
      quota: 3,
    ),
  );
  await tester.pumpAndSettle();

  if (query.isNotEmpty) {
    await tester.enterText(find.byType(TextField), query);
    await tester.pump(
      AppConfig.searchDebounce + const Duration(milliseconds: 1),
    );
    await tester.pumpAndSettle();
  }
}

Future<void> _openDetail(WidgetTester tester) async {
  final ValueNotifier<Quote> quote = ValueNotifier<Quote>(
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
  addTearDown(quote.dispose);

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
                    quote: quote,
                    loader: _loader(),
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

Future<void> _openListWithError(WidgetTester tester) async {
  late NoopFeed feed;
  await tester.pumpWidget(
    MaterialApp(
      home: QuoteListPage(
        // 必须钉死时钟：页头太极在交易时段会 `AnimationController.repeat()`
        // 自转，`pumpAndSettle` 于是永远收不了敛（10 分钟虚拟时间后超时）。
        // 这条用例以前只在非交易时段跑过，所以一直没暴露——16:00 是收盘后。
        clock: () => DateTime(2026, 11, 5, 16, 0),
        serviceBuilder: (onQuotes) {
          feed = NoopFeed(onQuotes);
          return feed;
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  feed.lastError.value = '行情源暂时不可用';
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('HitTarget：越界 4dp 仍命中，child 占位仍为 28×28', (
    WidgetTester tester,
  ) async {
    int hits = 0;
    await tester.pumpWidget(_probe(wrapped: true, onTap: () => hits++));
    final Rect r = tester.getRect(find.byKey(const Key('probe')));
    expect(r.width, 28.0, reason: '命中区扩展不得改变 child 宽度');
    expect(r.height, 28.0, reason: '命中区扩展不得改变 child 高度');

    await tester.tapAt(r.center + const Offset(0, 18));
    await tester.pump();
    expect(hits, 1, reason: '下边界外 4dp 应落进 48dp 命中区');
  });

  testWidgets('对照：不包 HitTarget 时同一位置不命中', (WidgetTester tester) async {
    int hits = 0;
    await tester.pumpWidget(_probe(wrapped: false, onTap: () => hits++));
    final Rect r = tester.getRect(find.byKey(const Key('probe')));
    await tester.tapAt(r.center + const Offset(0, 18));
    await tester.pump();
    expect(hits, 0, reason: '同一越界点在改造前不该触发回调');
  });

  testWidgets('订阅弹层：完成按钮有 48dp 命中区', (WidgetTester tester) async {
    await _openWatchlist(tester);
    _expectHit(tester, find.text('完成'), '完成按钮');
  });

  testWidgets('订阅弹层：清空按钮有 48dp 命中区', (WidgetTester tester) async {
    await _openWatchlist(tester, query: '茅台');
    _expectHit(tester, find.byTooltip('清空'), '清空按钮');
  });

  testWidgets('订阅弹层：删除按钮有 48dp 命中区', (WidgetTester tester) async {
    await _openWatchlist(tester);
    _expectHit(tester, find.byTooltip('删除 平安银行'), '删除按钮');
  });

  testWidgets('订阅弹层：搜索结果行有 48dp 命中区', (WidgetTester tester) async {
    await _openWatchlist(tester, query: '茅台');
    // 结果行整行本来就约 52dp 高，本来就达标；这里只钉住它不许再长高。
    _expectHit(tester, find.text('贵州茅台'), '搜索结果行', compact: false);
  });

  testWidgets('详情弹层：分时 / 日K 切换有 48dp 命中区', (WidgetTester tester) async {
    await _openDetail(tester);
    _expectHit(tester, find.text('分时'), '分时 tab');
    _expectHit(tester, find.text('日K'), '日K tab');
  });

  testWidgets('列表页：错误条重试按钮有 48dp 命中区', (WidgetTester tester) async {
    await _openListWithError(tester);
    _expectHit(tester, find.text('重试'), '重试按钮');
  });
}
