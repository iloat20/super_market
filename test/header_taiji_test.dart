import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/pages/quote_list_page.dart';
import 'package:super_market/services/local_store.dart';
import 'fake_feed.dart';
import 'package:super_market/services/watchlist_repository.dart';
import 'package:super_market/utils/market_session.dart';
import 'package:super_market/widgets/taiji_mark.dart';

/// 页头两个元素的行为：
/// - `_ClockTitle`：标题位是当前时间（带秒），每秒走一格；
/// - `TaijiMark`：**每来一条行情转一格**，没有行情就一帧都不排。
///
/// ## 太极的判定从「时段」改成了「数据」
///
/// 旧实现按交易时段 `repeat()`：整个交易日 60fps 不停，面板无法降频。
/// 现在由页面传入的 `ticks`（行情到达计数）驱动，所以这里的分工是：
/// - 有没有 tick → 决定「动不动」；
/// - 当前是否在交易时段 → 决定「tick 算不算数」（收盘快照也会 3s 一次，
///   但价格没动，转了就是撒谎）。
///
/// 全部用「有没有排帧」来断言，不看角度：排帧才是功耗与刷新率的直接原因。
void main() {
  // 可变的假时钟：用例里手动拨针
  DateTime now = DateTime(2026, 11, 2, 16, 30); // 周一 16:30 → 已收盘
  setUp(() => now = DateTime(2026, 11, 2, 16, 30));

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: QuoteListPage(
          serviceBuilder: NoopFeed.builder,
          watchlistRepository: WatchlistRepository(MemoryKeyValueStore()),
          clock: () => now,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('标题位显示当前时间（带秒）', (WidgetTester tester) async {
    await pumpPage(tester);
    expect(find.text('16:30:00'), findsOneWidget);
    expect(find.text('行情'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('时钟每秒走一格，秒位变化才重绘', (WidgetTester tester) async {
    await pumpPage(tester);
    // 实现读的是注入时钟，不是测试框架的假时钟：先拨针再 pump，
    // 定时器下一跳读到新秒位才会 setState
    await tester.pump(const Duration(seconds: 1));
    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('16:30:01'), findsOneWidget);
    now = now.add(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('16:30:04'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('收盘后：没有行情，整页一帧都不排', (WidgetTester tester) async {
    await pumpPage(tester);
    // 先让 bootstrap（读存档 / 快照链路）排的帧全部收敛
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('交易中但没有行情：仍然一帧都不排（旧实现这里会一直转）', (
    WidgetTester tester,
  ) async {
    now = DateTime(2026, 11, 2, 14, 0); // 周一 14:00 → 交易中
    await pumpPage(tester);
    expect(MarketSession.of(now).isLive, isTrue);
    // NoopFeed 不推报价 → 没有 tick → 不该有任何帧
    await tester.pump(const Duration(seconds: 2));
    expect(
      tester.binding.hasScheduledFrame,
      isFalse,
      reason: '交易时段不再是「转」的理由：没有数据到达就必须彻底静止',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('页面推一条行情 → 太极转一格，转完就停', (WidgetTester tester) async {
    now = DateTime(2026, 11, 2, 14, 0);
    late ValueChanged<List<Quote>> pushQuotes;

    await tester.pumpWidget(
      MaterialApp(
        home: QuoteListPage(
          serviceBuilder: (ValueChanged<List<Quote>> onQuotes) {
            pushQuotes = onQuotes;
            return NoopFeed(onQuotes);
          },
          watchlistRepository: WatchlistRepository(MemoryKeyValueStore()),
          clock: () => now,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    // 推的必须是订阅列表里的标的，否则 `_notifierFor` 找不到卡片、也就没有 tick
    final StockConfig one = AppConfig.stocks.first;
    pushQuotes(<Quote>[
      Quote(
        code: one.code,
        region: one.region,
        price: 38.71,
        change: 0.3,
        changePercent: 0.02,
        previousClose: 38.41,
        timestamp: DateTime(2026, 11, 2, 14, 0),
      ),
    ]);
    await tester.pump(); // 启动这一格的动画
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      tester.binding.hasScheduledFrame,
      isTrue,
      reason: '拿到行情必须真的动一下，否则「数据活了」这个信号就没了',
    );

    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.binding.hasScheduledFrame,
      isFalse,
      reason: '一格（300ms）转完必须停下，不能留下持续动画',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('太极画在本体里：圆形容器 + CustomPaint', (WidgetTester tester) async {
    now = DateTime(2026, 11, 2, 16, 30);
    await pumpPage(tester);
    expect(find.byType(TaijiMark), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('太极：tick 驱动 + 时段判定', () {
    Future<ValueNotifier<int>> pumpMark(
      WidgetTester tester, {
      required List<String> regions,
    }) async {
      final ValueNotifier<int> ticks = ValueNotifier<int>(0);
      addTearDown(ticks.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaijiMark(now: () => now, regions: regions, ticks: ticks),
          ),
        ),
      );
      await tester.pump();
      return ticks;
    }

    Matrix4 rotationOf(WidgetTester tester) => tester
        .widget<Transform>(
          find.descendant(
            of: find.byType(TaijiMark),
            matching: find.byType(Transform),
          ),
        )
        .transform;

    testWidgets('交易中：一个 tick 转一格，且转完不再排帧', (WidgetTester tester) async {
      now = DateTime(2026, 11, 2, 14, 0);
      final ValueNotifier<int> ticks = await pumpMark(
        tester,
        regions: <String>['SH'],
      );

      await tester.pump(const Duration(seconds: 2));
      expect(tester.binding.hasScheduledFrame, isFalse, reason: '无数据 → 静止');
      final Matrix4 before = rotationOf(tester);

      ticks.value++;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // 走完 300ms

      expect(
        rotationOf(tester),
        isNot(equals(before)),
        reason: 'tick 必须真的改变角度，否则太极永远停在同一格',
      );
      expect(
        tester.binding.hasScheduledFrame,
        isFalse,
        reason: '一格结束就该停：持续排帧正是这次要消掉的东西',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('收盘后（快照还在 3s 一次）：tick 不转', (WidgetTester tester) async {
      now = DateTime(2026, 11, 2, 16, 30);
      final ValueNotifier<int> ticks = await pumpMark(
        tester,
        regions: <String>['SH'],
      );
      final Matrix4 before = rotationOf(tester);

      ticks.value++;
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(rotationOf(tester), equals(before), reason: '收盘价没在动，图标也不该动');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('多市场：A 股收盘但港股在交易 → tick 仍然转', (
      WidgetTester tester,
    ) async {
      // 15:30：A 股已收盘（15:00）、港股交易中（13:00–16:10）——用户拍板的
      // 语义：混合 A+H 自选时 A 股收盘后港股还在跳，太极必须跟着动
      now = DateTime(2026, 11, 2, 15, 30);
      final ValueNotifier<int> ticks = await pumpMark(
        tester,
        regions: <String>['SH', 'HK'],
      );

      ticks.value++;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        tester.binding.hasScheduledFrame,
        isTrue,
        reason: '港股在交易，tick 必须能推动太极',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('只有 A 股且已收盘 → tick 不转', (WidgetTester tester) async {
      now = DateTime(2026, 11, 2, 15, 30);
      final ValueNotifier<int> ticks = await pumpMark(
        tester,
        regions: <String>['SH'],
      );

      ticks.value++;
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('订阅加了港股后，下一个 tick 就按新市场集合判定', (
      WidgetTester tester,
    ) async {
      now = DateTime(2026, 11, 2, 15, 30);
      final ValueNotifier<int> ticks = await pumpMark(
        tester,
        regions: <String>['SH'],
      );

      // 先确认此刻 tick 无效
      ticks.value++;
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.hasScheduledFrame, isFalse);

      // 订阅里加了一只港股 → 同一个 State，didUpdateWidget 换掉市场集合
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaijiMark(
              now: () => now,
              regions: const <String>['SH', 'HK'],
              ticks: ticks,
            ),
          ),
        ),
      );
      ticks.value++;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        tester.binding.hasScheduledFrame,
        isTrue,
        reason: '市场集合必须跟着 didUpdateWidget 更新，否则加了港股也不会动',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
