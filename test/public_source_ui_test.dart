import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/pages/quote_list_page.dart';
import 'package:super_market/services/polling_quote_feed.dart';
import 'package:super_market/services/quote_feed.dart';
import 'package:super_market/services/local_store.dart';
import 'package:super_market/services/quote_feeds.dart';
import 'package:super_market/services/symbol_directory.dart';
import 'package:super_market/services/watchlist_repository.dart';
import 'package:super_market/services/source/polling_source.dart';
import 'package:super_market/services/source/polling_sources.dart';

/// 不联网的通道替身：只用来验证「界面是否按通道能力显示」。
class FakeFeed implements QuoteFeed {
  FakeFeed({
    this.label = '新浪财经',
    FeedStatus initial = FeedStatus.connected,
  }) {
    status.value = initial;
  }

  @override
  String get sourceLabel => label;

  final String label;

  @override
  final ValueNotifier<FeedStatus> status =
      ValueNotifier<FeedStatus>(FeedStatus.disconnected);

  @override
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  @override
  List<StockConfig> get stocks => AppConfig.stocks;

  int connectCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int reconnectCalls = 0;
  List<StockConfig>? lastStocks;

  @override
  void connect() => connectCalls++;

  @override
  void pause() => pauseCalls++;

  @override
  void resume() => resumeCalls++;

  @override
  void reconnectNow() => reconnectCalls++;

  @override
  void updateStocks(List<StockConfig> next) => lastStocks = next;

  @override
  void dispose() {
    status.dispose();
    lastError.dispose();
  }
}

void main() {
  group('默认通道：公开源（不要 Key）', () {
    test('QuoteFeeds 造出来的是轮询通道，且不需要凭证', () {
      final QuoteFeed feed = QuoteFeeds.create(
        onQuotes: (List<Quote> _) {},
      );
      expect(feed, isA<PollingQuoteFeed>());
      expect(QuoteFeeds.label, '新浪财经');
      feed.dispose();
    });

    test('主备顺序：新浪在前、腾讯在后', () {
      final List<String> names = PollingSources.defaultChain
          .map((PollingSource s) => s.displayName)
          .toList();
      expect(names, <String>['新浪财经', '腾讯财经']);
    });
  });

  group('首页按通道能力显示', () {
    testWidgets('公开源：不弹凭证提示、没有配额上限、页脚说明轮询节奏',
        (WidgetTester tester) async {
      final FakeFeed feed = FakeFeed();
      await tester.pumpWidget(
        MaterialApp(
          home: QuoteListPage(
            serviceBuilder: (ValueChanged<List<Quote>> _) => feed,
            // 默认会落磁盘（path_provider 在 widget 测试里没有平台通道），
            // 换成内存实现，页面才不会在 _bootstrap 里读盘失败后连 connect 都跳过
            watchlistRepository:
                WatchlistRepository(MemoryKeyValueStore()),
            symbolDirectory: SymbolDirectory(store: MemoryKeyValueStore()),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.textContaining('未配置'),
        findsNothing,
        reason: '公开源没有 Key，不该提示去填 Key',
      );
      // 页脚来源行与订阅配额卡都已按产品要求移除（订阅入口改到页头太极）
      expect(
        find.text('新浪财经 · 3s 轮询 · 主备切换 · 3 订阅 · 切后台暂停'),
        findsNothing,
      );
      expect(find.text('${AppConfig.stocks.length} 只'), findsNothing);
      expect(
        find.text('${AppConfig.stocks.length} / ${AppConfig.publicSourceMaxStocks}'),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });


    testWidgets('生命周期：切后台暂停通道、回前台恢复', (WidgetTester tester) async {
      final FakeFeed feed = FakeFeed();
      await tester.pumpWidget(
        MaterialApp(
          home: QuoteListPage(
            serviceBuilder: (ValueChanged<List<Quote>> _) => feed,
            // 默认会落磁盘（path_provider 在 widget 测试里没有平台通道），
            // 换成内存实现，页面才不会在 _bootstrap 里读盘失败后连 connect 都跳过
            watchlistRepository:
                WatchlistRepository(MemoryKeyValueStore()),
            symbolDirectory: SymbolDirectory(store: MemoryKeyValueStore()),
          ),
        ),
      );
      await tester.pump();
      expect(feed.connectCalls, 1);

      // Flutter 3.13+ 的生命周期是状态机，不能从 resumed 直接跳 paused，
      // 必须逐级走 resumed → inactive → hidden → paused，否则这次调用会被
      // 静默丢弃，测试会误以为「页面没收到通知」。
      // 注意页面把 hidden 也算作「进后台」，所以 pause 会被调两次以上。
      for (final AppLifecycleState state in <AppLifecycleState>[
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      expect(feed.pauseCalls, greaterThan(0), reason: '进后台必须停掉轮询');

      for (final AppLifecycleState state in <AppLifecycleState>[
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      expect(feed.resumeCalls, 1, reason: '回前台必须立即恢复轮询');
      // 恢复链里会经过 hidden，页面把它也算「进后台」，所以 pause 会再 +1；
      // 这里只确认 pause 没有失控增长（不是每次 pump 都调一次）
      expect(feed.pauseCalls, lessThanOrEqualTo(5));

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
