/// 「北京挂钟」这一层为什么必须存在，以及它现在被谁用着。
///
/// 缺陷本身依赖设备时区（非 UTC+8 才可复现），本机是 UTC+8，所以这里
/// 分两半测：
/// 1. 数学：任意时刻 → 北京挂钟字段的折算；
/// 2. 静态不变量：所有「拿现在跟报价时间戳比」的入口默认时钟必须是
///    [beijingNow]，不能是 `DateTime.now`（后者在非 +8 设备上会整体偏移）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/utils/beijing_clock.dart';
import 'package:super_market/utils/market_session.dart';
import 'package:super_market/utils/quote_freshness.dart';
import 'package:super_market/models/quote.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('折算数学', () {
    test('UTC 02:00 → 北京 10:00', () {
      final DateTime bj = toBeijingWallClock(DateTime.utc(2026, 11, 3, 2, 0));
      expect(bj.hour, 10);
      expect(bj.day, 3);
      expect(bj.minute, 0);
    });

    test('UTC 20:00（周一）→ 北京次日 04:00（周二）', () {
      final DateTime bj = toBeijingWallClock(DateTime.utc(2026, 11, 2, 20, 0));
      expect(bj.day, 3);
      expect(bj.hour, 4);
      expect(bj.weekday, DateTime.tuesday);
    });

    test('beijingNow 的字段等于「UTC 现在 + 8 小时」', () {
      // 只比字段，不比 epochs：beijingNow 是「本地标记 + 北京字段」，
      // 与 UTC 时刻相差的就是本地时区偏移，直接相减必然不等于 0。
      int ordinalMinutes(DateTime t) =>
          ((t.year * 12 + t.month) * 31 + t.day) * 1440 + t.hour * 60 + t.minute;

      final DateTime want = DateTime.now().toUtc().add(kBeijingOffset);
      final DateTime got = beijingNow();
      expect(
        (ordinalMinutes(got) - ordinalMinutes(want)).abs() <= 1,
        isTrue,
        reason: 'beijingNow 必须落在北京钟点上（允许一分钟的跨界容差）',
      );
    });
  });

  group('消费方行为', () {
    test('刚拿到的北京挂钟报价不算陈旧（与设备时区无关）', () {
      final DateTime stamp = beijingNow().subtract(const Duration(seconds: 3));
      final Quote q = Quote(
        code: '600519',
        region: 'SH',
        price: 1486,
        change: 0,
        changePercent: 0,
        timestamp: stamp,
      );
      expect(isStale(q, beijingNow()), isFalse);
    });

    test('十分钟前的北京挂钟报价算陈旧', () {
      final DateTime stamp = beijingNow().subtract(const Duration(minutes: 10));
      final Quote q = Quote(
        code: '600519',
        region: 'SH',
        price: 1486,
        change: 0,
        changePercent: 0,
        timestamp: stamp,
      );
      expect(isStale(q, beijingNow()), isTrue);
    });

    test('MarketSession 接受北京挂钟输入', () {
      // 2026-11-03 周二 10:00 北京 → A 股盘中
      expect(MarketSession.of(DateTime(2026, 11, 3, 10, 0)), MarketSession.trading);
    });
  });

  group('静态不变量：默认时钟不得再用 DateTime.now', () {
    test('三个「北京挂钟」消费方的构造默认值都是 beijingNow', () {
      // 这些类的 now 参数默认值就是生产路径：漏一个，那个组件在非 +8
      // 设备上就会自己算错，而且不会有任何测试变红（本机是 +8）。
      for (final String path in <String>[
        'lib/pages/quote_list_page.dart',
        'lib/widgets/quote_detail_sheet.dart',
        'lib/widgets/quote_tile.dart',
        'lib/widgets/market_session_badge.dart',
        'lib/widgets/taiji_mark.dart',
        'lib/services/polling_quote_feed.dart',
      ]) {
        final String src = _read(path);
        expect(
          src,
          contains('beijingNow'),
          reason: '$path 的默认时钟必须是 beijingNow',
        );
        expect(
          src,
          isNot(contains('now = DateTime.now')),
          reason: '$path 还留着 DateTime.now 作默认值：'
              '那会让「现在」与报文时间戳（北京钟点）差一个时区偏移',
        );
      }
    });
  });
}
