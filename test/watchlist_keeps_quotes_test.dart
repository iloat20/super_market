import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/pages/quote_list_page.dart';
import 'package:super_market/services/local_store.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/services/source/symbol_catalog.dart';
import 'package:super_market/services/symbol_directory.dart';
import 'package:super_market/services/watchlist_repository.dart';
import 'package:super_market/widgets/taiji_mark.dart';

import 'fake_feed.dart';

/// 改订阅列表**不能**把没动过的标的的报价清掉。
///
/// ## 这条用例守的是什么
///
/// `_syncNotifiers` 曾经无条件调用 `_buildNotifiersFor(_stocks)`：连"保留下来的"
/// 标的也会被换成新的 `ValueNotifier(Quote.empty(...))`。于是用户每加一只股票，
/// 整屏卡片的价格全部变成 `--`，要等下一轮轮询才恢复——而那 100~300ms 里，
/// 界面在说"我没有这个价"，事实上它刚刚有过。
///
/// 断言必须卡在**新报价回来之前**：只要 pump 一帧、价格仍在，就说明 notifier
/// 被保留了；如果实现又退回"全部重建"，这一帧里必然是 `--`。

/// 钉死「已收盘」时刻（周一 16:30）：秒表/角标/太极都不产生新帧，
/// `pumpAndSettle` 才收敛得了。
DateTime Function() _testClock = () => DateTime(2026, 11, 2, 16, 30);

/// 空目录源：不联网，本地搜索恒空，让"按代码添加"这条路径可预测。
class _EmptyCatalog implements SymbolCatalog {
  @override
  String get id => 'empty';

  @override
  String get displayName => 'Empty';

  @override
  List<String> get markets => const <String>['SZ', 'SH'];

  @override
  Future<List<StockConfig>> fetchSymbols({required HttpGetJson httpGet}) async =>
      const <StockConfig>[];
}

/// 远端联想接口离线：直接 503，`searchRemote` 返回 null，不发真网请求。
Future<HttpRawResponse> _offline(
  Uri uri,
  Map<String, String> headers,
) async =>
    const HttpRawResponse(statusCode: 503, body: <int>[]);

Quote _quote({
  required String code,
  required String region,
  required double price,
}) => Quote(
  code: code,
  region: region,
  price: price,
  change: 0.3,
  changePercent: 0.5,
  previousClose: price - 0.3,
  open: price,
  high: price,
  low: price,
  volume: 100000,
  turnover: 1000000,
  timestamp: DateTime(2026, 11, 2, 15, 0),
);

Widget _host(Widget child) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: child,
);

void main() {
  testWidgets('改订阅列表后，未改动标的的报价必须原样保留', (WidgetTester tester) async {
    final MemoryKeyValueStore store = MemoryKeyValueStore();
    late ValueChanged<List<Quote>> pushQuotes;

    await tester.pumpWidget(
      _host(
        QuoteListPage(
          serviceBuilder: (ValueChanged<List<Quote>> onQuotes) {
            pushQuotes = onQuotes;
            return NoopFeed(onQuotes);
          },
          watchlistRepository: WatchlistRepository(store),
          symbolDirectory: SymbolDirectory(
            source: _EmptyCatalog(),
            store: store,
            httpGetBytes: _offline,
          ),
          clock: _testClock,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    // 首屏推两条价：默认列表的前两只（名字/代码都从 AppConfig 取，
    // 避免「改了默认列表就红一片」这种假失败）
    final StockConfig first = AppConfig.stocks[0];
    final StockConfig second = AppConfig.stocks[1];
    pushQuotes(<Quote>[
      _quote(code: first.code, region: first.region, price: 11.24),
      _quote(code: second.code, region: second.region, price: 1486),
    ]);
    await tester.pump();

    expect(find.text('11.24'), findsOneWidget);
    expect(find.text('1486.00'), findsOneWidget);

    // 打开订阅管理，用「按代码添加」加一只新股
    await tester.tap(find.byType(TaijiMark));
    await tester.pumpAndSettle();
    expect(find.text('订阅管理'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '600036');
    await tester.pump(AppConfig.searchDebounce + const Duration(milliseconds: 1));
    await tester.pumpAndSettle();

    await tester.tap(find.text('按代码添加'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    // 关键断言：这一帧里**还没有**任何新报价回来
    expect(
      find.text('1486.00'),
      findsOneWidget,
      reason: '改订阅不该清空未改动标的的价格：notifier 必须按 key 复用，'
          '而不是整体重建（quote_list_page.dart:_syncNotifiers）',
    );
    expect(find.text('11.24'), findsOneWidget);

    // 新加的那只还没有报价，显示占位——顺便证明列表结构确实更新了
    // （名称与代码都是 '600036'，所以是两处）
    expect(find.text('600036'), findsWidgets);
    expect(find.text('--'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
