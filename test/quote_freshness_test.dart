/// A（2026-11-05）：报价来源必须按「数据有多旧」判定，不能按 `Quote.source`。
///
/// ## 这条用例为什么存在
///
/// 页脚与卡片角标原来读 `QuoteSource`，而 `QuoteSource.snapshot` 只有一个
/// 构造点 `Quote.asSnapshot()`，它在整个仓库里**零调用** —— 所有真实报价都
/// 从解析器出来、写死 `socket`。于是「快照」角标永不出现、页脚永远说
/// 「实时推送」。真机实证（2026-11-05 09:01）：界面上是上一个交易日
/// 15:35:45 的收盘价，标签却是「实时推送 · 新浪财经」。
///
/// 这里的断言分两层：纯函数把边界钉死；真实渲染证明 UI 确实走了这个判定
/// （只改函数不改调用点的话，widget 用例会红）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/kline.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/services/kline_loader.dart';
import 'package:super_market/services/source/kline_source.dart';
import 'package:super_market/utils/quote_freshness.dart';
import 'package:super_market/widgets/quote_detail_sheet.dart';
import 'package:super_market/widgets/quote_tile.dart';

/// 钉死的「现在」：2026-11-05 周四 10:00，盘中。
final DateTime _kNow = DateTime(2026, 11, 5, 10, 0, 0);

const StockConfig _kStock = StockConfig(
  code: '600519',
  name: '贵州茅台',
  region: 'SH',
);

Quote _quote({DateTime? timestamp, double price = 1486.00}) => Quote(
  code: '600519',
  region: 'SH',
  price: price,
  change: -12.30,
  changePercent: -0.82,
  previousClose: 1498.30,
  open: 1499.00,
  high: 1502.50,
  low: 1478.10,
  timestamp: timestamp,
);

/// 不联网的走势取数器：详情弹层里那块图与本用例无关，返回空即可。
class _EmptyLoader extends KlineLoader {
  _EmptyLoader()
    : super(chain: const <KlineSource>[], now: () => DateTime(2026, 11, 5, 15));

  @override
  Future<KlineResult<Kline>> loadDaily(StockConfig stock, {int? count}) async =>
      KlineResult<Kline>(items: <Kline>[], sourceId: 'sina');

  @override
  Future<KlineResult<IntradayPoint>> loadIntraday(StockConfig stock) async =>
      KlineResult<IntradayPoint>(items: <IntradayPoint>[], sourceId: 'sina');
}

Future<void> _pumpTile(
  WidgetTester tester,
  Quote quote,
  DateTime Function() clock,
) async {
  final ValueNotifier<Quote> notifier = ValueNotifier<Quote>(quote);
  addTearDown(notifier.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: QuoteTile(stock: _kStock, quote: notifier, now: clock),
      ),
    ),
  );
  await tester.pump();
}

/// 打开详情弹层并等动画收敛
Future<void> _openSheet(
  WidgetTester tester,
  Quote quote,
  DateTime Function() clock,
) async {
  final ValueNotifier<Quote> notifier = ValueNotifier<Quote>(quote);
  addTearDown(notifier.dispose);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      builder: (BuildContext context, Widget? child) =>
          Material(type: MaterialType.transparency, child: child),
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () {
                unawaited(
                  showQuoteDetailSheet(
                    context,
                    stock: _kStock,
                    quote: notifier,
                    loader: _EmptyLoader(),
                    now: clock,
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

void main() {
  group('isStale：边界', () {
    test('3 秒前 → 实时', () {
      expect(
        isStale(
          _quote(timestamp: _kNow.subtract(const Duration(seconds: 3))),
          _kNow,
        ),
        isFalse,
      );
    });

    test('正好 5 分钟 → 仍算实时（判决线是开区间）', () {
      expect(
        isStale(_quote(timestamp: _kNow.subtract(kQuoteStaleAfter)), _kNow),
        isFalse,
        reason: '协议多写一秒就会误标，边界必须钉住',
      );
    });

    test('5 分 01 秒 → 快照', () {
      expect(
        isStale(
          _quote(
            timestamp: _kNow.subtract(const Duration(minutes: 5, seconds: 1)),
          ),
          _kNow,
        ),
        isTrue,
      );
    });

    test('上一个交易日 15:35:45 → 快照（真机现场）', () {
      expect(
        isStale(_quote(timestamp: DateTime(2026, 11, 4, 15, 35, 45)), _kNow),
        isTrue,
        reason: '9:01 打开 App 看到的正是这一条，它曾被标成「实时推送」',
      );
    });

    test('服务端时间比本地时钟晚 30 秒 → 不误标', () {
      expect(
        isStale(
          _quote(timestamp: _kNow.add(const Duration(seconds: 30))),
          _kNow,
        ),
        isFalse,
        reason: '时钟偏差不该把实时价说成快照',
      );
    });

    test('没有行情（价格 0）→ 不谈来源', () {
      expect(isStale(Quote.empty('600519'), _kNow), isFalse);
    });

    test('有价但没有时间戳 → 不能叫实时', () {
      expect(isStale(_quote(), _kNow), isTrue);
    });
  });

  group('staleIn：翻转时刻', () {
    test('1 分钟前 → 还有 4 分钟', () {
      expect(
        staleIn(
          _quote(timestamp: _kNow.subtract(const Duration(minutes: 1))),
          _kNow,
        ),
        const Duration(minutes: 4),
      );
    });

    test('正好卡在判决线 → 返回零（下一秒才翻）', () {
      expect(
        staleIn(_quote(timestamp: _kNow.subtract(kQuoteStaleAfter)), _kNow),
        Duration.zero,
        reason: 'isStale 是开区间，此刻仍算实时，不能返回 null（否则永远不复查）',
      );
    });

    test('已经陈旧 → null（不用再挂定时器）', () {
      expect(
        staleIn(
          _quote(timestamp: _kNow.subtract(const Duration(minutes: 6))),
          _kNow,
        ),
        isNull,
      );
    });

    test('没有行情 / 没有时间戳 → null', () {
      expect(staleIn(Quote.empty('600519'), _kNow), isNull);
      expect(staleIn(_quote(), _kNow), isNull, reason: '无时间戳恒判陈旧，没有翻转可等');
    });
  });

  group('UI 复用同一判定', () {
    // 2026-11-05 用户拍板：界面不再显示「快照」字样（卡片角标整体移除、
    // 页脚 stale 只留来源）。判定逻辑本身保留：页脚的「轮询更新 ↔ 只留来源」
    // 翻转和读屏播报仍依赖它。
    testWidgets('QuoteTile：陈旧与新鲜都不显示「快照」字样', (WidgetTester tester) async {
      await _pumpTile(
        tester,
        _quote(timestamp: DateTime(2026, 11, 4, 15, 35, 45)),
        () => _kNow,
      );
      expect(find.text('快照'), findsNothing, reason: '用户拍板：卡片不再显示快照字样');

      await _pumpTile(
        tester,
        _quote(timestamp: _kNow.subtract(const Duration(seconds: 3))),
        () => _kNow,
      );
      expect(find.text('快照'), findsNothing);
    });

    // 两次弹层必须分成两个用例：同一个 testWidgets 里第二次 pumpWidget
    // 会复用同一个 MaterialApp（同类型 widget → 保留 State），第一次的
    // modal route 还压在栈上，第二次 tap 会打在它的遮罩上。
    testWidgets('详情页脚：陈旧报价只留来源，不说收盘快照', (WidgetTester tester) async {
      await _openSheet(
        tester,
        _quote(timestamp: DateTime(2026, 11, 4, 15, 35, 45)),
        () => _kNow,
      );
      expect(find.textContaining('收盘快照'), findsNothing);
      expect(find.textContaining('轮询更新'), findsNothing);
      expect(find.textContaining('新浪财经'), findsOneWidget, reason: '来源仍要可见');
    });

    testWidgets('详情页脚：新鲜报价说轮询更新', (WidgetTester tester) async {
      await _openSheet(
        tester,
        _quote(timestamp: _kNow.subtract(const Duration(seconds: 3))),
        () => _kNow,
      );
      expect(find.textContaining('轮询更新'), findsOneWidget);
      expect(find.textContaining('收盘快照'), findsNothing);
    });

    // 行情停了以后 ValueNotifier 不再发声，界面只能靠定时器自己翻。
    // 这两条用例就是这个场景：只推进时钟、不送新报价。
    testWidgets('跨过判决线：读屏播报自己翻转（卡片已无可见角标）', (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      DateTime clock = _kNow;
      await _pumpTile(
        tester,
        _quote(timestamp: _kNow.subtract(const Duration(minutes: 4))),
        () => clock,
      );
      expect(find.text('快照'), findsNothing, reason: '卡片上没有可见的快照角标');
      expect(find.bySemanticsLabel(RegExp('收盘快照')), findsNothing,
          reason: '4 分钟前的价仍是实时价');

      // 时钟和定时器一起往前 61 秒：没有新报价进来
      clock = _kNow.add(const Duration(seconds: 61));
      await tester.pump(const Duration(seconds: 61));
      expect(find.bySemanticsLabel(RegExp('收盘快照')), findsOneWidget,
          reason: '读屏仍要说清「这不是实时价」——这是信息不丢的替代通道');
      handle.dispose();
    });

    testWidgets('跨过判决线：详情页脚自己翻转', (WidgetTester tester) async {
      DateTime clock = _kNow;
      await _openSheet(
        tester,
        _quote(timestamp: _kNow.subtract(const Duration(minutes: 4))),
        () => clock,
      );
      expect(find.textContaining('轮询更新'), findsOneWidget);

      clock = _kNow.add(const Duration(seconds: 61));
      await tester.pump(const Duration(seconds: 61));
      expect(find.textContaining('轮询更新'), findsNothing, reason: '陈旧后不再说「轮询更新」');
      expect(find.textContaining('收盘快照'), findsNothing);
      expect(find.textContaining('新浪财经'), findsOneWidget, reason: '来源仍要可见');
    });

    testWidgets('更新时间跨天补日期：昨天 15:35 不会读成今早', (WidgetTester tester) async {
      await _openSheet(
        tester,
        _quote(timestamp: DateTime(2026, 11, 4, 15, 35, 45)),
        () => _kNow,
      );
      expect(find.text('11-04 15:35'), findsOneWidget);
      expect(
        find.text('15:35:45'),
        findsNothing,
        reason: '只写时分秒，早上 9 点看到会以为是今天的价',
      );
    });

    testWidgets('更新时间当天保留秒：盘中能看出在跳', (WidgetTester tester) async {
      await _openSheet(
        tester,
        _quote(timestamp: DateTime(2026, 11, 5, 9, 59, 3)),
        () => _kNow,
      );
      expect(find.text('09:59:03'), findsOneWidget);
    });
  });
}
