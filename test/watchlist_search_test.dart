import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/services/local_store.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/services/source/symbol_catalog.dart';
import 'package:super_market/services/symbol_directory.dart';
import 'package:super_market/widgets/watchlist_sheet.dart';

/// 真实报文形状（2026-11-03 实测 `searchapi.eastmoney.com`）
String _es(String code, String name, String marketType) =>
    '{"QuotationCodeTable":{"Data":[{"Code":"$code","Name":"$name",'
    '"MarketType":"$marketType"}],"Status":0}}';

/// 可手动放行的搜索 HTTP：用来验证防抖与竞态
class SuggestHttp {
  SuggestHttp({this.bodyFor});

  /// 关键词 → 响应体（不传则用 [_es] 的默认票）
  final String Function(String query)? bodyFor;

  final List<String> queries = <String>[];
  final Map<String, Completer<HttpRawResponse>> _pending =
      <String, Completer<HttpRawResponse>>{};

  /// true 时不自动返回，必须调用 [release]
  bool manual = false;

  Future<HttpRawResponse> get(Uri uri, Map<String, String> headers) {
    final String q = uri.queryParameters['input'] ?? '';
    queries.add(q);
    if (manual) {
      final Completer<HttpRawResponse> c = Completer<HttpRawResponse>();
      _pending[q] = c;
      return c.future;
    }
    return Future<HttpRawResponse>.value(
      HttpRawResponse(statusCode: 200, body: utf8.encode(_body(q))),
    );
  }

  String _body(String q) =>
      bodyFor?.call(q) ?? _es('600519', '贵州茅台', '1');

  void release(String q, {String? body, int statusCode = 200}) {
    final Completer<HttpRawResponse>? c = _pending.remove(q);
    if (c == null) {
      return;
    }
    c.complete(
      HttpRawResponse(
        statusCode: statusCode,
        body: utf8.encode(body ?? _body(q)),
      ),
    );
  }

  bool hasPending(String q) => _pending.containsKey(q);
}

const List<StockConfig> _initial = <StockConfig>[
  StockConfig(code: '000001', name: '平安银行', region: 'SZ'),
];

/// 目录下载的假 HTTP：直接给空目录，避免测试打到真网
Future<HttpJsonResponse> _emptyCatalog(
  Uri uri,
  Map<String, String> headers,
) async =>
    const HttpJsonResponse(statusCode: 200, body: '[]');

Future<GlobalKey<NavigatorState>> _openSheet(
  WidgetTester tester,
  SymbolDirectory directory, {
  int quota = 3,
  List<StockConfig>? stocks,
}) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: SizedBox.expand()),
    ),
  );
  unawaited(
    showWatchlistSheet(
      navKey.currentContext!,
      stocks: stocks ?? _initial,
      directory: directory,
      quota: quota,
    ),
  );
  await tester.pumpAndSettle();
  return navKey;
}

SymbolDirectory _directory(SuggestHttp suggest) => SymbolDirectory(
      store: MemoryKeyValueStore(),
      httpGet: _emptyCatalog,
      httpGetBytes: suggest.get,
    );

/// 把防抖计时推过去，再等远端响应落地
Future<void> _settleSearch(WidgetTester tester) async {
  await tester.pump(AppConfig.searchDebounce + const Duration(milliseconds: 1));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('手输 5 位港股代码：出现「按代码添加」入口', (WidgetTester tester) async {
    // 曾写死 query.length == 6：港股接入后 00700 到不了 _addByCode，
    // 搜索不到又加不进去，成了死角
    final SuggestHttp http = SuggestHttp();
    await _openSheet(tester, _directory(http));

    await tester.enterText(find.byType(TextField), '00700');
    await _settleSearch(tester);

    // 远端搜不到也没关系，「按代码添加」入口必须在
    expect(find.text('按代码添加'), findsOneWidget);
  });

  testWidgets('输入即搜：250ms 后发请求，结果直接出现', (WidgetTester tester) async {
    final SuggestHttp http = SuggestHttp();
    await _openSheet(tester, _directory(http));

    await tester.enterText(find.byType(TextField), '茅台');
    await tester.pump();

    // 防抖还没到点，不该发请求
    expect(http.queries, isEmpty);
    expect(find.text('搜索中…'), findsOneWidget);

    await _settleSearch(tester);

    expect(http.queries, <String>['茅台']);
    expect(find.text('贵州茅台'), findsOneWidget);
    expect(find.text('600519'), findsOneWidget);
  });

  testWidgets('防抖：连打四个字只发最后一次请求', (WidgetTester tester) async {
    final SuggestHttp http = SuggestHttp();
    await _openSheet(tester, _directory(http));

    for (final String q in <String>['贵', '贵州', '贵州茅', '贵州茅台']) {
      await tester.enterText(find.byType(TextField), q);
      // 每次间隔小于防抖窗口（真实输入法就是这个节奏）
      await tester.pump(const Duration(milliseconds: 80));
    }
    await _settleSearch(tester);

    expect(http.queries, <String>['贵州茅台']);
  });

  testWidgets('竞态：先发的慢响应回来不能覆盖后发的结果', (WidgetTester tester) async {
    final SuggestHttp http = SuggestHttp(
      bodyFor: (String q) => q == '茅台'
          ? _es('600519', '贵州茅台', '1')
          : _es('000001', '平安银行', '2'),
    )..manual = true;
    await _openSheet(tester, _directory(http));

    await tester.enterText(find.byType(TextField), '茅台');
    await tester.pump(AppConfig.searchDebounce + const Duration(milliseconds: 1));
    expect(http.hasPending('茅台'), isTrue);

    // 还没等第一次回来，用户又输入了
    await tester.enterText(find.byType(TextField), '平安');
    await tester.pump(AppConfig.searchDebounce + const Duration(milliseconds: 1));
    expect(http.hasPending('平安'), isTrue);

    // 后发的先回来
    http.release('平安');
    await tester.pump();

    // 先发的（已经过期的）后回来
    http.release('茅台');
    await tester.pumpAndSettle();

    expect(
      find.text('贵州茅台'),
      findsNothing,
      reason: '过期的响应必须被丢弃，否则列表会显示上一次搜索的答案',
    );
    // 「平安银行」既是初始订阅又是搜索结果，会出现两处（订阅区 + 结果区）
    expect(find.text('平安银行'), findsNWidgets(2));
  });

  testWidgets('远端失败：明说「检查网络」，不说「没找到」', (WidgetTester tester) async {
    final SuggestHttp http = SuggestHttp()
      ..manual = true;
    await _openSheet(tester, _directory(http));

    await tester.enterText(find.byType(TextField), '茅台');
    await tester.pump(AppConfig.searchDebounce + const Duration(milliseconds: 1));
    http.release('茅台', statusCode: 500);
    await tester.pumpAndSettle();

    expect(find.text('没找到「茅台」'), findsNothing);
    expect(
      find.textContaining('搜索服务暂时不可用'),
      findsOneWidget,
      reason: '断网时说「没找到」，用户会以为这只股票不存在',
    );
  });

  testWidgets('本地目录命中时不必等远端（离线也能加）', (WidgetTester tester) async {
    final SuggestHttp http = SuggestHttp()..manual = true;
    final SymbolDirectory directory = SymbolDirectory(
      store: MemoryKeyValueStore(),
      httpGet: (Uri uri, Map<String, String> headers) async {
        if (uri.path.contains('getHQNodeStockCount')) {
          return const HttpJsonResponse(statusCode: 200, body: '"1"');
        }
        return const HttpJsonResponse(
          statusCode: 200,
          body: '[{"symbol":"sh600519","code":"600519","name":"贵州茅台"}]',
        );
      },
      httpGetBytes: http.get,
    );
    await _openSheet(tester, directory);

    // 等后台目录预热完成
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '茅台');
    await tester.pump();

    // 远端还没回（manual），本地目录已经能命中
    expect(find.text('贵州茅台'), findsOneWidget);
    expect(http.hasPending('茅台'), isFalse, reason: '防抖还没到点');

    http.release('茅台');
    await tester.pumpAndSettle();
    expect(find.text('贵州茅台'), findsOneWidget, reason: '本地与远端不能重复展示');
  });

  testWidgets('清空输入：结果与状态一起复位', (WidgetTester tester) async {
    final SuggestHttp http = SuggestHttp();
    await _openSheet(tester, _directory(http));

    await tester.enterText(find.byType(TextField), '茅台');
    await _settleSearch(tester);
    expect(find.text('贵州茅台'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();

    expect(find.text('贵州茅台'), findsNothing);
    expect(find.text('搜索中…'), findsNothing);
    // 订阅区还在
    expect(find.text('平安银行'), findsOneWidget);
  });

  // ==================== 缓存失效 ====================

  testWidgets('目录后到：同一个 query 在下一次重建时必须命中本地结果', (
    WidgetTester tester,
  ) async {
    // 搜索从「输入即搜」改成按 query 缓存后引入的新风险：
    // 缓存键里若不含「目录版本」，用户打完字、目录刚好加载完成，
    // 界面会永远停在"没搜到"，直到他再动一下输入框。
    final SuggestHttp http = SuggestHttp(
      // 远端这次故意返回空：贵州茅台只能来自本地目录，
      // 否则这条用例会被远端结果蒙混过关
      bodyFor: (String q) => '{"QuotationCodeTable":{"Data":[],"Status":0}}',
    );
    http.manual = true;
    final _LateCatalog catalog = _LateCatalog();
    final SymbolDirectory dir = SymbolDirectory(
      store: MemoryKeyValueStore(),
      httpGet: _emptyCatalog,
      httpGetBytes: http.get,
      source: catalog,
    );

    await _openSheet(tester, dir);
    expect(dir.count, 0, reason: '目录第一次拉取失败，此刻应为空');

    await tester.enterText(find.byType(TextField), '600519');
    await tester.pump(AppConfig.searchDebounce + const Duration(milliseconds: 1));
    expect(find.text('贵州茅台'), findsNothing);

    // 目录到位（模拟网络恢复后又拉了一次）
    catalog.items = const <StockConfig>[
      StockConfig(code: '600519', name: '贵州茅台', region: 'SH'),
    ];
    await dir.ensureLoaded(force: true);
    expect(dir.count, 1);

    // 远端响应落地 → setState → 同一个 query 再算一次
    http.release('600519');
    await tester.pumpAndSettle();

    expect(
      find.text('贵州茅台'),
      findsWidgets,
      reason: '目录变了，按 query 的缓存必须失效，否则搜索结果永远是旧的',
    );
  });

  // C-05（review-2026-11-05）：_add 曾用 StockConfig ==（含 name）判重。
  // 名称会漂移（公司更名、搜索源与目录源不同步）：搜索返回的简称与存档
  // 不一致时，同一 code@region 会被当成「未订阅」再加一次，列表出现
  // 两张同价卡（同一个 notifier，重启后 decode 去重才自愈）。
  // 身份是 code@region，判重必须按 key。
  testWidgets('判重按身份键：搜索返回的名称与存档不一致也拦下', (WidgetTester tester) async {
    const StockConfig archived = StockConfig(
      code: '000651',
      name: '格力电器',
      region: 'SZ',
    );
    final SuggestHttp http = SuggestHttp(
      bodyFor: (String q) => _es('000651', '格力电器（新）', '2'),
    );
    await _openSheet(tester, _directory(http), stocks: <StockConfig>[archived]);

    await tester.enterText(find.byType(TextField), '格力');
    await _settleSearch(tester);

    // 结果区展示的是搜索返回的新名称
    expect(find.text('格力电器（新）'), findsOneWidget);
    await tester.tap(find.text('格力电器（新）'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('已经在订阅列表里了'),
      findsOneWidget,
      reason: '同一 code@region 必须判重，否则出现两张同价卡',
    );
    expect(find.text('当前订阅（1/3）'), findsOneWidget);
  });
}

/// 第一次拉取失败、之后能给出数据的目录源（模拟"目录后到"）。
class _LateCatalog implements SymbolCatalog {
  List<StockConfig>? items;

  @override
  String get id => 'late';

  @override
  String get displayName => 'Late';

  @override
  List<String> get markets => const <String>['SZ', 'SH'];

  @override
  Future<List<StockConfig>> fetchSymbols({required HttpGetJson httpGet}) async {
    final List<StockConfig>? ready = items;
    if (ready == null) {
      throw const SymbolFetchException('目录还没准备好');
    }
    return ready;
  }
}
