import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:super_market/utils/format.dart';
import 'package:super_market/utils/market_session.dart';
import 'package:super_market/widgets/market_session_badge.dart';

/// 固定构造一个工作日时间（2025-11-17 是周一）
DateTime monday(int hour, int minute) => DateTime(2025, 11, 17, hour, minute);

void main() {
  group('MarketSession 交易时段', () {
    test('开盘前 → 未开盘', () {
      expect(MarketSession.of(monday(8, 0)), MarketSession.preOpen);
      expect(MarketSession.of(monday(9, 14)), MarketSession.preOpen);
    });

    test('09:15 起为集合竞价，09:30 进入连续竞价', () {
      expect(MarketSession.of(monday(9, 15)), MarketSession.callAuction);
      expect(MarketSession.of(monday(9, 29)), MarketSession.callAuction);
      expect(MarketSession.of(monday(9, 30)), MarketSession.trading);
    });

    test('11:30–13:00 午间休市', () {
      expect(MarketSession.of(monday(11, 29)), MarketSession.trading);
      expect(MarketSession.of(monday(11, 30)), MarketSession.lunchBreak);
      expect(MarketSession.of(monday(12, 59)), MarketSession.lunchBreak);
      expect(MarketSession.of(monday(13, 0)), MarketSession.trading);
    });

    test('15:00 收盘', () {
      expect(MarketSession.of(monday(14, 59)), MarketSession.trading);
      expect(MarketSession.of(monday(15, 0)), MarketSession.closed);
      expect(MarketSession.of(monday(23, 59)), MarketSession.closed);
    });

    test('周六周日 → 休市（哪怕时间在盘中）', () {
      // 2025-11-22 周六 / 2025-11-23 周日
      expect(
        MarketSession.of(DateTime(2025, 11, 22, 10, 0)),
        MarketSession.weekend,
      );
      expect(
        MarketSession.of(DateTime(2025, 11, 23, 14, 0)),
        MarketSession.weekend,
      );
    });

    test('isLive 只在集合竞价与连续竞价时为 true', () {
      expect(MarketSession.trading.isLive, isTrue);
      expect(MarketSession.callAuction.isLive, isTrue);
      expect(MarketSession.lunchBreak.isLive, isFalse);
      expect(MarketSession.closed.isLive, isFalse);
      expect(MarketSession.preOpen.isLive, isFalse);
      expect(MarketSession.weekend.isLive, isFalse);
    });
  });

  group('MarketSession.ofUs 美股（美东挂钟 / 夏令时）', () {
    // 2025-11-03（周一）在冬令时（11 月第一个周日 11-02 已切换）：北京 = ET + 13
    // 2026-03-09（周一）在夏令时（3 月第二个周日 03-08 已切换）：北京 = ET + 12
    test('冬令时：北京 22:30 开盘，次日 05:00 收盘', () {
      expect(
        MarketSession.ofUs(DateTime(2025, 11, 3, 20, 0)),
        MarketSession.preOpen,
        reason: 'ET 07:00',
      );
      expect(
        MarketSession.ofUs(DateTime(2025, 11, 3, 21, 30)),
        MarketSession.preOpen,
        reason: 'ET 08:30，还差一分钟开盘',
      );
      expect(
        MarketSession.ofUs(DateTime(2025, 11, 3, 22, 30)),
        MarketSession.trading,
        reason: 'ET 09:30',
      );
      expect(
        MarketSession.ofUs(DateTime(2025, 11, 4, 4, 59)),
        MarketSession.trading,
        reason: '北京周二凌晨 = ET 周一 15:59',
      );
      expect(
        MarketSession.ofUs(DateTime(2025, 11, 4, 5, 0)),
        MarketSession.closed,
        reason: 'ET 16:00 收盘',
      );
      expect(
        MarketSession.ofUs(DateTime(2025, 11, 4, 10, 0)),
        MarketSession.closed,
      );
    });

    test('夏令时：北京 21:30 开盘，次日 04:00 收盘', () {
      expect(
        MarketSession.ofUs(DateTime(2026, 3, 9, 20, 0)),
        MarketSession.preOpen,
        reason: 'ET 08:00',
      );
      expect(
        MarketSession.ofUs(DateTime(2026, 3, 9, 21, 30)),
        MarketSession.trading,
        reason: 'ET 09:30（EDT，比冬令时早一小时）',
      );
      expect(
        MarketSession.ofUs(DateTime(2026, 3, 10, 3, 59)),
        MarketSession.trading,
      );
      expect(
        MarketSession.ofUs(DateTime(2026, 3, 10, 4, 0)),
        MarketSession.closed,
        reason: 'ET 16:00 收盘',
      );
    });

    test('周末看美东日历：北京周六凌晨美股周五还在交易', () {
      // 北京 2025-11-08（周六）03:00 = ET 周五 14:00（冬令时）→ 交易中
      expect(
        MarketSession.ofUs(DateTime(2025, 11, 8, 3, 0)),
        MarketSession.trading,
      );
      // 北京周六 10:00 = ET 周五 21:00 → 已收盘（不是「休市」：ET 还是工作日）
      expect(
        MarketSession.ofUs(DateTime(2025, 11, 8, 10, 0)),
        MarketSession.closed,
      );
      // 北京周日 21:00 = ET 周日 08:00 → 休市
      expect(
        MarketSession.ofUs(DateTime(2025, 11, 9, 21, 0)),
        MarketSession.weekend,
      );
    });

    test('美股没有集合竞价与午休：这两个状态不该出现', () {
      for (final int h in <int>[0, 6, 9, 12, 15, 18, 21, 23]) {
        final MarketSession s = MarketSession.ofUs(DateTime(2025, 11, 3, h, 0));
        expect(s, isNot(MarketSession.callAuction), reason: '$h:00 → $s');
        expect(s, isNot(MarketSession.lunchBreak), reason: '$h:00 → $s');
      }
    });
  });

  group('MarketSession.ofRegions 订阅市场并集', () {
    const List<String> a = <String>['SH', 'SZ'];
    const List<String> hk = <String>['HK'];
    const List<String> both = <String>['SH', 'SZ', 'HK'];

    test('纯 A 股订阅：口径完全不变', () {
      expect(
        MarketSession.ofRegions(monday(9, 20), a),
        MarketSession.callAuction,
      );
      expect(
        MarketSession.ofRegions(monday(11, 45), a),
        MarketSession.lunchBreak,
      );
      expect(MarketSession.ofRegions(monday(15, 30), a), MarketSession.closed);
    });

    test('纯港股订阅：15:00 后仍交易到 16:10', () {
      expect(MarketSession.ofRegions(monday(9, 29), hk), MarketSession.preOpen);
      expect(
        MarketSession.ofRegions(monday(11, 45), hk),
        MarketSession.trading,
      );
      expect(
        MarketSession.ofRegions(monday(12, 30), hk),
        MarketSession.lunchBreak,
      );
      expect(
        MarketSession.ofRegions(monday(15, 30), hk),
        MarketSession.trading,
      );
      expect(MarketSession.ofRegions(monday(16, 9), hk), MarketSession.trading);
      expect(MarketSession.ofRegions(monday(16, 10), hk), MarketSession.closed);
    });

    test('混合订阅：任一市场在交易就算交易中', () {
      expect(
        MarketSession.ofRegions(monday(8, 0), both),
        MarketSession.preOpen,
      );
      expect(
        MarketSession.ofRegions(monday(9, 20), both),
        MarketSession.callAuction,
        reason: 'A 股集合竞价，港股还没开盘',
      );
      expect(
        MarketSession.ofRegions(monday(11, 45), both),
        MarketSession.trading,
        reason: 'A 股午休、港股早市仍在交易',
      );
      expect(
        MarketSession.ofRegions(monday(12, 30), both),
        MarketSession.lunchBreak,
        reason: '两地同时午休',
      );
      expect(
        MarketSession.ofRegions(monday(15, 30), both),
        MarketSession.trading,
        reason: 'A 股已收盘、港股午后仍在交易',
      );
      expect(
        MarketSession.ofRegions(monday(16, 10), both),
        MarketSession.closed,
      );
    });

    test('周末休市；空订阅退回 A 股口径', () {
      expect(
        MarketSession.ofRegions(DateTime(2025, 11, 22, 10, 0), both),
        MarketSession.weekend,
      );
      expect(
        MarketSession.ofRegions(monday(15, 30), const <String>[]),
        MarketSession.closed,
      );
    });

    test('美股并入并集：A/H 收盘后由美股接力', () {
      // 2025-11-03（周一）冬令时：
      const List<String> all3 = <String>['SZ', 'HK', 'US'];
      expect(
        MarketSession.ofRegions(DateTime(2025, 11, 3, 15, 30), all3),
        MarketSession.trading,
        reason: '港股 15:30 还在交易（到 16:10）',
      );
      expect(
        MarketSession.ofRegions(DateTime(2025, 11, 3, 16, 30), all3),
        MarketSession.preOpen,
        reason: 'A/H 已收盘、美股 ET 03:30 未开盘',
      );
      expect(
        MarketSession.ofRegions(DateTime(2025, 11, 3, 22, 30), all3),
        MarketSession.trading,
        reason: 'A/H 已收盘、美股盘中接力',
      );
      // 只有美股订阅时完全按美股口径
      expect(
        MarketSession.ofRegions(DateTime(2025, 11, 3, 22, 30), const <String>[
          'US',
        ]),
        MarketSession.trading,
      );
      expect(
        MarketSession.ofRegions(DateTime(2025, 11, 3, 16, 30), const <String>[
          'US',
        ]),
        MarketSession.preOpen,
      );
    });
  });

  group('法定节假日：工作日也不开市', () {
    test('A 股春节：2/17（周二）10:00 是休市，不再是「交易中」', () {
      expect(
        MarketSession.of(DateTime(2026, 2, 17, 10, 0)),
        MarketSession.holiday,
      );
    });

    test('节假日整天都是休市：盘前不写「未开盘」、收盘后不写「已收盘」', () {
      // 2026-10-01（周四，国庆）
      for (final DateTime t in <DateTime>[
        DateTime(2026, 10, 1),
        DateTime(2026, 10, 1, 9, 0),
        DateTime(2026, 10, 1, 9, 20),
        DateTime(2026, 10, 1, 14, 0),
        DateTime(2026, 10, 1, 23, 0),
      ]) {
        expect(MarketSession.of(t), MarketSession.holiday, reason: '$t');
      }
    });

    test('节后首日恢复：2/24、10/8 都是正常交易日', () {
      expect(
        MarketSession.of(DateTime(2026, 2, 24, 10, 0)),
        MarketSession.trading,
      );
      expect(
        MarketSession.of(DateTime(2026, 10, 8, 10, 0)),
        MarketSession.trading,
      );
    });

    test('节假日区间里的周六仍报「周末休市」（周末先判）', () {
      // 2026-02-21 是周六，也在春节休市区间内
      expect(
        MarketSession.of(DateTime(2026, 2, 21, 10, 0)),
        MarketSession.weekend,
      );
    });

    test('港股：佛诞翌日 5/25、圣诞 12/25 都是休市', () {
      expect(
        MarketSession.ofHk(DateTime(2026, 5, 25, 10, 0)),
        MarketSession.holiday,
      );
      expect(
        MarketSession.ofHk(DateTime(2026, 12, 25, 10, 0)),
        MarketSession.holiday,
      );
    });

    test('港股半日市：12/24 只有早市，12:10 后已收盘', () {
      expect(
        MarketSession.ofHk(DateTime(2026, 12, 24, 9, 0)),
        MarketSession.preOpen,
      );
      expect(
        MarketSession.ofHk(DateTime(2026, 12, 24, 11, 59)),
        MarketSession.trading,
      );
      // 12:00–12:10 是收市竞价，价格还会动
      expect(
        MarketSession.ofHk(DateTime(2026, 12, 24, 12, 9)),
        MarketSession.trading,
      );
      expect(
        MarketSession.ofHk(DateTime(2026, 12, 24, 12, 10)),
        MarketSession.closed,
      );
      // 同一天的 13:30：正常交易日照样交易，半日市已经收盘
      expect(
        MarketSession.ofHk(DateTime(2026, 12, 17, 13, 30)),
        MarketSession.trading,
      );
      expect(
        MarketSession.ofHk(DateTime(2026, 12, 24, 13, 30)),
        MarketSession.closed,
      );
    });

    test('美股按美东日判休市：北京 11/26 晚已是感恩节', () {
      // 冬令时：北京 = ET + 13。北京 11/26 22:30 = ET 11/26 09:30
      expect(
        MarketSession.ofUs(DateTime(2026, 11, 26, 22, 30)),
        MarketSession.holiday,
      );
      // 北京 11/27 01:00 = ET 11/26 12:00，仍是感恩节
      expect(
        MarketSession.ofUs(DateTime(2026, 11, 27, 1, 0)),
        MarketSession.holiday,
      );
    });

    test('美股半日市：感恩节次日 13:00 ET 收盘', () {
      // 北京 11/27 22:30 = ET 11/27 09:30
      expect(
        MarketSession.ofUs(DateTime(2026, 11, 27, 22, 30)),
        MarketSession.trading,
      );
      // 北京 11/28 01:30 = ET 12:30
      expect(
        MarketSession.ofUs(DateTime(2026, 11, 28, 1, 30)),
        MarketSession.trading,
      );
      // 北京 11/28 02:00 = ET 13:00
      expect(
        MarketSession.ofUs(DateTime(2026, 11, 28, 2, 0)),
        MarketSession.closed,
      );
      // 对照：普通周五要到 ET 16:00（北京次日 05:00）才收盘
      expect(
        MarketSession.ofUs(DateTime(2026, 11, 21, 4, 30)),
        MarketSession.trading,
      );
    });

    test('holiday 不算 isLive（太极不转、圆点是灰的）', () {
      expect(MarketSession.holiday.isLive, isFalse);
      expect(MarketSession.holiday.isRestDay, isTrue);
      expect(MarketSession.weekend.isRestDay, isTrue);
      expect(MarketSession.closed.isRestDay, isFalse);
    });
  });

  group('节假日与订阅并集', () {
    const List<String> a = <String>['SZ'];
    const List<String> aHk = <String>['SZ', 'HK'];

    test('A 股休市、港股照常 → 并集仍是「交易中」', () {
      // 2026-02-23（周一）A 股春节休市，港股正常交易
      expect(
        MarketSession.ofRegions(DateTime(2026, 2, 23, 10, 0), a),
        MarketSession.holiday,
      );
      expect(
        MarketSession.ofRegions(DateTime(2026, 2, 23, 10, 0), aHk),
        MarketSession.trading,
      );
    });

    test('两地同时休市 → 并集是「休市」而不是「已收盘」', () {
      // 2026-10-01 国庆，A 股与港股都休市
      expect(
        MarketSession.ofRegions(DateTime(2026, 10, 1, 10, 0), aHk),
        MarketSession.holiday,
      );
    });

    test('A 股休市、港股已收盘 → 「已收盘」（港股今天确实开过市）', () {
      // 2026-02-23（周一）A 股春节休市，港股 16:10 收盘
      expect(
        MarketSession.ofRegions(DateTime(2026, 2, 23, 17, 0), aHk),
        MarketSession.closed,
      );
    });
  });

  group('页头时段角标（订阅并集）', () {
    // 周一 15:30：A 股已收盘（15:00），港股交易到 16:10
    final DateTime t = DateTime(2026, 11, 2, 15, 30);

    Future<void> pumpBadge(WidgetTester tester, List<String> regions) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MarketSessionBadge(now: () => t, regions: regions),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('混合 A+H：15:30 显示「交易中」而不是「已收盘」', (WidgetTester tester) async {
      await pumpBadge(tester, const <String>['SZ', 'HK']);
      expect(find.text('交易中'), findsOneWidget);
      expect(find.text('已收盘'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('纯 A 股：15:30 仍是「已收盘」', (WidgetTester tester) async {
      await pumpBadge(tester, const <String>['SZ']);
      expect(find.text('已收盘'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('订阅里加港股：不等 30s 定时器，当场翻成「交易中」', (WidgetTester tester) async {
      await pumpBadge(tester, const <String>['SZ']);
      expect(find.text('已收盘'), findsOneWidget);
      await pumpBadge(tester, const <String>['SZ', 'HK']);
      expect(find.text('交易中'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('法定节假日：角标写「休市」，不是「交易中」', (WidgetTester tester) async {
      // 2026-02-17（周二，春节）—— 修复前这里会写「交易中」
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MarketSessionBadge(
              now: () => DateTime(2026, 2, 17, 10, 0),
              regions: const <String>['SZ'],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('休市'), findsOneWidget);
      expect(find.text('交易中'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('format', () {
    test('formatSigned 处理符号与 -0.00', () {
      expect(formatSigned(1.234), '+1.23');
      expect(formatSigned(-1.235), '-1.24');
      expect(formatSigned(0), '0.00');
      // 负零：不能显示成 "-0.00"
      expect(formatSigned(-0.001), '0.00');
      expect(formatSigned(1.5, suffix: '%'), '+1.50%');
      expect(formatSigned(-1.5, suffix: '%'), '-1.50%');
    });

    test('formatCompact 按万/亿压缩', () {
      expect(formatCompact(16742235), '1674.22万');
      expect(formatCompact(3774688301.452), '37.75亿');
      expect(formatCompact(9999), '9999');
      expect(formatCompact(12345), '1.23万');
    });

    test('formatClock / formatDateTimeShort 补零', () {
      final DateTime t = DateTime(2025, 3, 9, 9, 5, 3);
      expect(formatClock(t), '09:05:03');
      expect(formatClock(null), '—');
      expect(formatDateTimeShort(t), '03-09 09:05');
      expect(formatDateTimeShort(null), '--');
    });

    test('formatUpdateTime 同一天给秒、跨天给日期', () {
      final DateTime now = DateTime(2025, 3, 10, 9, 30);
      expect(formatUpdateTime(DateTime(2025, 3, 10, 9, 5, 3), now), '09:05:03');
      // 昨天：只写 15:35 会被读成今早 9:30 之前的价
      expect(
        formatUpdateTime(DateTime(2025, 3, 9, 15, 35, 45), now),
        '03-09 15:35',
      );
      // 跨年同月同日也必须带日期
      expect(
        formatUpdateTime(DateTime(2024, 3, 10, 15, 35), now),
        '03-10 15:35',
      );
      expect(formatUpdateTime(null, now), '--');
    });
  });
}
