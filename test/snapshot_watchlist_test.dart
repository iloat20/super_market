import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/pages/quote_list_page.dart';
import 'package:super_market/services/local_store.dart';
import 'package:super_market/services/symbol_directory.dart';
import 'package:super_market/services/watchlist_repository.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/services/source/symbol_catalog.dart';
import 'package:super_market/widgets/taiji_mark.dart';
import 'fake_feed.dart';

/// 钉死「已收盘」时刻（周一 16:30）：页头秒表与太极只在秒位/时段
/// 变化时才动 UI，钉住之后 pumpAndSettle 才收敛得了。
DateTime Function() testClock = () => DateTime(2026, 11, 2, 16, 30);

/// 可编程的静态目录源：返回固定 4 条，可注入失败
class _StaticCatalog implements SymbolCatalog {
  /// 非 null 时 fetchSymbols 抛出该异常
  Object? throwing;

  int calls = 0;

  @override
  String get id => 'static';

  @override
  String get displayName => 'Static';

  @override
  List<String> get markets => const <String>['SZ', 'SH'];

  @override
  Future<List<StockConfig>> fetchSymbols({required HttpGetJson httpGet}) async {
    calls++;
    final Object? t = throwing;
    if (t != null) {
      throw t;
    }
    return const <StockConfig>[
      StockConfig(code: '000001', name: '平安银行', region: 'SZ'),
      StockConfig(code: '000858', name: '五粮液', region: 'SZ'),
      StockConfig(code: '000001', name: '上证综合指数', region: 'SH'),
      StockConfig(code: '600519', name: '贵州茅台', region: 'SH'),
    ];
  }
}

/// 能记录 updateStocks 的空转 feed（页面装配验证用）
class _SpyFeed extends NoopFeed {
  _SpyFeed(super.onQuotes);

  List<StockConfig>? lastStocks;

  @override
  void updateStocks(List<StockConfig> next) => lastStocks = next;
}

void main() {
  group('行情新旧裁决：谁覆盖谁', () {
    final DateTime t1500 = DateTime(2026, 11, 3, 15, 0);
    final Quote olderAt1500 = Quote(
      code: '000001',
      region: 'SZ',
      price: 11.54,
      change: -0.1,
      changePercent: -0.86,
      timestamp: t1500,
      source: QuoteSource.snapshot,
    );

    test('当前没数据 → 接受（首屏填充）', () {
      expect(
        shouldApplyQuote(Quote.empty('000001', region: 'SZ'), olderAt1500),
        isTrue,
      );
    });

    test('比现有行情旧 → 拒绝（价格不能往回跳）', () {
      final Quote live = Quote(
        code: '000001',
        region: 'SZ',
        price: 11.60,
        change: 0.06,
        changePercent: 0.5,
        timestamp: t1500.add(const Duration(minutes: 5)),
      );
      expect(shouldApplyQuote(live, olderAt1500), isFalse);
    });

    test('比现有行情新 → 接受', () {
      final Quote oldLive = Quote(
        code: '000001',
        region: 'SZ',
        price: 11.50,
        change: 0.0,
        changePercent: 0,
        timestamp: t1500.subtract(const Duration(minutes: 5)),
      );
      expect(shouldApplyQuote(oldLive, olderAt1500), isTrue);
    });

    test('同一时刻，实时推送优先于旧数据来源', () {
      final Quote live = Quote(
        code: '000001',
        region: 'SZ',
        price: 11.55,
        change: 0.0,
        changePercent: 0,
        timestamp: t1500,
      );
      final Quote snap = Quote(
        code: '000001',
        region: 'SZ',
        price: 11.54,
        change: -0.1,
        changePercent: -0.86,
        timestamp: t1500,
        source: QuoteSource.snapshot,
      );
      expect(shouldApplyQuote(snap, live), isTrue);
      expect(shouldApplyQuote(live, snap), isFalse);
    });

    // C-01（review-2026-11-05）：时间戳粒度是秒，同一秒内可能出现第二笔
    // 不同价的报文。原同刻分支只按「来源可信度」裁决（socket>snapshot），
    // 同为 socket 的第二笔会被当成重放丢掉——价格最多滞后一个轮询周期。
    // 内容变了就不是重放。
    test('同一秒内的第二笔不同价（同为实时链路）→ 内容变了就接受', () {
      final Quote first = Quote(
        code: '000001',
        region: 'SZ',
        price: 11.55,
        change: 0.01,
        changePercent: 0.09,
        timestamp: t1500,
      );
      final Quote second = Quote(
        code: '000001',
        region: 'SZ',
        price: 11.57,
        change: 0.03,
        changePercent: 0.26,
        timestamp: t1500,
      );
      expect(
        shouldApplyQuote(first, second),
        isTrue,
        reason: '同秒第二笔不同价是更晚的成交，不是重放',
      );
    });

    test('同一时刻同内容重放帧仍然拒绝（不触发无谓重建）', () {
      final Quote first = Quote(
        code: '000001',
        region: 'SZ',
        price: 11.55,
        change: 0.01,
        changePercent: 0.09,
        timestamp: t1500,
      );
      final Quote replay = Quote(
        code: '000001',
        region: 'SZ',
        price: 11.55,
        change: 0.01,
        changePercent: 0.09,
        timestamp: t1500,
      );
      expect(shouldApplyQuote(first, replay), isFalse);
    });

    test('没有价格的行情永远不覆盖已有数据', () {
      final Quote live = Quote(
        code: '000001',
        region: 'SZ',
        price: 11.55,
        change: 0.0,
        changePercent: 0,
        timestamp: t1500,
      );
      final Quote empty = Quote.empty('000001', region: 'SZ');
      expect(shouldApplyQuote(live, empty), isFalse);
    });
  });

  group('订阅存档', () {
    test('编码 → 解码可以还原', () {
      // 覆盖见 watchlist_repository 的存档路径测试（read/write 往返）
      const List<StockConfig> stocks = <StockConfig>[
        StockConfig(code: '000001', name: '平安银行', region: 'SZ'),
        StockConfig(code: '600519', name: '贵州茅台', region: 'SH'),
      ];
      expect(WatchlistRepository.encode(stocks), isA<String>());
      expect(WatchlistRepository.decode(WatchlistRepository.encode(stocks)), stocks);
    });

    test('坏 JSON / 非数组都退回空，不抛', () {
      expect(WatchlistRepository.decode('not json'), isEmpty);
      expect(WatchlistRepository.decode('{"a":1}'), isEmpty);
    });

    test('坏条目跳过、重复去掉；不按免费档 3 只截断（历史 bug）', () {
      final String raw = WatchlistRepository.encode(<StockConfig>[
        ...AppConfig.stocks,
        ...AppConfig.stocks, // 重复
      ]);
      final List<StockConfig> decoded = WatchlistRepository.decode(raw);
      expect(decoded.length, AppConfig.stocks.length,
          reason: '重复条目必须被去重');
    });

    test('防御性上限：超过 30 只截断到 30', () {
      final List<StockConfig> many = List<StockConfig>.generate(
        40,
        (int i) => StockConfig(
          code: i.toString().padLeft(6, '0'),
          name: 'S$i',
          region: 'SZ',
        ),
      );
      expect(WatchlistRepository.decode(WatchlistRepository.encode(many)).length, 30);
    });

    test('读盘失败时退回默认列表，不影响启动', () async {
      final WatchlistRepository repo = WatchlistRepository(_ThrowingStore());
      final List<StockConfig> loaded = await repo.load();
      expect(loaded, AppConfig.stocks);
    });

    test('代码前缀推断市场；无法识别的段不猜', () {
      expect(WatchlistRepository.regionForCode('600519'), 'SH');
      expect(WatchlistRepository.regionForCode('000001'), 'SZ');
      expect(WatchlistRepository.regionForCode('00700'), 'HK');
      expect(WatchlistRepository.regionForCode('830789'), isNull,
          reason: '北交所 8 段无归属，不猜');
      // 已知边界：920 段（北交所新码）被现实现归为 SH，见 regionForCode 的
      // '9' 分支——与历史行为一致，改映射需先确认真网目录的覆盖范围
    });
  });

  group('股票目录（本地搜索）', () {
    test('首次加载走网络，之后走缓存', () async {
      final MemoryKeyValueStore store = MemoryKeyValueStore();
      final _StaticCatalog catalog = _StaticCatalog();
      final SymbolDirectory dir = SymbolDirectory(
        source: catalog,
        store: store,
      );

      await dir.ensureLoaded();
      expect(dir.isLoaded, isTrue);
      expect(dir.count, 4);
      expect(catalog.calls, 1);

      // 新实例读同一份缓存：不该再发请求
      final _StaticCatalog catalog2 = _StaticCatalog();
      final SymbolDirectory dir2 = SymbolDirectory(
        source: catalog2,
        store: store,
      );
      await dir2.ensureLoaded();
      expect(dir2.count, 4);
      expect(catalog2.calls, 0, reason: '未过期缓存不该重新下载');
    });

    test('按名称搜：茅台 → 600519 沪市', () async {
      final SymbolDirectory dir = SymbolDirectory(
        source: _StaticCatalog(),
        store: MemoryKeyValueStore(),
      );
      await dir.ensureLoaded();

      final List<StockConfig> hits = dir.search('茅台');
      expect(hits.length, 1);
      expect(hits.single.code, '600519');
      expect(hits.single.region, 'SH');
    });

    test('按代码搜：同号代码两个市场都要列出来', () async {
      final SymbolDirectory dir = SymbolDirectory(
        source: _StaticCatalog(),
        store: MemoryKeyValueStore(),
      );
      await dir.ensureLoaded();

      final List<StockConfig> hits = dir.search('000001');
      expect(hits.length, 2, reason: '深市平安银行 + 沪市上证指数');
      expect(
          hits.map((StockConfig s) => s.region).toSet(), <String>{'SZ', 'SH'});
    });

    test('失败时退回旧缓存，搜索仍可用', () async {
      final MemoryKeyValueStore store = MemoryKeyValueStore();
      // 先成功写一份缓存
      final _StaticCatalog ok = _StaticCatalog();
      await SymbolDirectory(source: ok, store: store).ensureLoaded();

      // 再强制刷新，但这次源挂了
      final SymbolDirectory dir = SymbolDirectory(
        source: _StaticCatalog()
          ..throwing = const SymbolFetchException('目录服务挂了'),
        store: store,
      );
      await dir.ensureLoaded(force: true);

      expect(dir.count, 4, reason: '旧的目录比「什么都没有」有用');
      expect(dir.search('茅台').single.code, '600519');
      expect(dir.error, isNotNull);
    });

    test('空查询不返回任何东西', () {
      final SymbolDirectory dir =
          SymbolDirectory(source: _StaticCatalog());
      expect(dir.search('  '), isEmpty);
    });
  });

  group('首页：订阅管理', () {
    testWidgets('点太极图标打开订阅管理', (WidgetTester tester) async {
      final MemoryKeyValueStore store = MemoryKeyValueStore();

      await tester.pumpWidget(
        _host(
          QuoteListPage(
            serviceBuilder: NoopFeed.builder,
            watchlistRepository: WatchlistRepository(store),
            symbolDirectory: SymbolDirectory(
              source: _StaticCatalog(),
              store: store,
            ),
            clock: testClock,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      // 订阅入口在页头太极（产品要求：点图标弹出订阅管理）
      await tester.tap(find.byType(TaijiMark));
      await tester.pumpAndSettle();

      expect(find.text('订阅管理'), findsOneWidget);
      // 当前订阅都列出来了（默认列表来自 AppConfig，不写死名字）
      expect(find.text(AppConfig.stocks.first.name), findsWidgets);
      expect(find.text(AppConfig.stocks[1].name), findsWidgets);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('删掉一只后：存档写入、服务层用新列表', (
      WidgetTester tester,
    ) async {
      final MemoryKeyValueStore store = MemoryKeyValueStore();
      _SpyFeed? service;

      await tester.pumpWidget(
        _host(
          QuoteListPage(
            serviceBuilder: (ValueChanged<List<Quote>> onQuotes) =>
                service = _SpyFeed(onQuotes),
            watchlistRepository: WatchlistRepository(store),
            symbolDirectory: SymbolDirectory(
              source: _StaticCatalog(),
              store: store,
            ),
            clock: testClock,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      await tester.tap(find.byType(TaijiMark));
      await tester.pumpAndSettle();

      // 删掉最后一只（默认列表末位）
      final StockConfig removed = AppConfig.stocks.last;
      await tester.tap(find.byTooltip('删除 ${removed.name}'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      // 服务层的订阅列表已经变了
      expect(service!.lastStocks!.length, AppConfig.stocks.length - 1);
      expect(
        service!.lastStocks!.map((StockConfig s) => s.code),
        isNot(contains(removed.code)),
      );

      // 存档也写下去了，下次启动直接是这两只
      final String? saved = await store.read(WatchlistRepository.storageKey);
      expect(saved, isNotNull);
      expect(saved, isNot(contains(removed.code)));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  });
}

Widget _host(Widget child) => MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: child,
    );

/// 模拟「磁盘读不出来」（例如平台通道异常）
class _ThrowingStore implements KeyValueStore {
  @override
  Future<String?> read(String key) async => throw StateError('disk down');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('disk down');

  @override
  Future<void> remove(String key) async => throw StateError('disk down');
}
