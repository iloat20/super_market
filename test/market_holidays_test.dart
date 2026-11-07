/// 交易日历的**表结构不变量** —— 这些断言不关心业务，只保证「这张表能被信任」。
///
/// 为什么值得单独一组：表是手写的、每年手改一次。手写数据最容易出的错不是
/// 逻辑写错，而是**漏一天 / 多一天 / 把周末也抄进来 / 排序乱了看不出重复**，
/// 这些错在界面上表现为「某天莫名显示交易中」，靠肉眼看 80 行数字发现不了。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/market_holidays.dart';

/// 把 `20260217` 还原成日期（编码规则见 `MarketHolidays.keyOf`）。
DateTime decode(int key) =>
    DateTime(key ~/ 10000, key % 10000 ~/ 100, key % 100);

void main() {
  final Map<String, Set<int>> tables = <String, Set<int>>{
    ...MarketHolidays.byRegion,
    ...MarketHolidays.halfDays.map(
      (String k, Set<int> v) => MapEntry<String, Set<int>>('$k(half)', v),
    ),
  };

  group('交易日历表结构', () {
    test('只收工作日：周末本来就不开市，抄进来只增加出错面', () {
      for (final MapEntry<String, Set<int>> entry in tables.entries) {
        for (final int key in entry.value) {
          final DateTime day = decode(key);
          expect(
            day.weekday,
            lessThanOrEqualTo(DateTime.friday),
            reason:
                '${entry.key} 的 $key 落在${day.weekday == DateTime.saturday ? '周六' : '周日'}',
          );
        }
      }
    });

    test('每天都能还原成合法日期（编码无错位）', () {
      for (final MapEntry<String, Set<int>> entry in tables.entries) {
        for (final int key in entry.value) {
          final DateTime day = decode(key);
          expect(
            day.month,
            inInclusiveRange(1, 12),
            reason: '${entry.key} $key',
          );
          expect(day.day, inInclusiveRange(1, 31), reason: '${entry.key} $key');
          // 2 月 30 日这类会被 DateTime 顺延到 3 月，keyOf 就不再等于原值
          expect(
            MarketHolidays.keyOf(day),
            key,
            reason: '${entry.key} $key 不是真实存在的日期',
          );
        }
      }
    });

    test('组内严格递增：顺手把「重复」和「乱序」一起挡住', () {
      for (final MapEntry<String, Set<int>> entry in tables.entries) {
        final List<int> keys = entry.value.toList();
        final List<int> sorted = List<int>.of(keys)..sort();
        expect(keys, sorted, reason: '${entry.key} 未按日期升序');
        expect(
          keys.toSet(),
          hasLength(keys.length),
          reason: '${entry.key} 有重复日期',
        );
      }
    });

    test('三个市场都覆盖 2026 与 2027 两年', () {
      for (final String region in <String>['A', 'HK', 'US']) {
        final Set<int>? table = MarketHolidays.byRegion[region];
        expect(table, isNotNull, reason: '$region 缺表');
        for (final int year in <int>[2026, 2027]) {
          expect(
            table!.any((int key) => key ~/ 10000 == year),
            isTrue,
            reason: '$region 没覆盖 $year 年',
          );
        }
      }
    });

    test('lastCoveredYear 与表里最大的年份一致（改表必须改声明）', () {
      int maxYear = 0;
      for (final Set<int> table in tables.values) {
        for (final int key in table) {
          if (key ~/ 10000 > maxYear) {
            maxYear = key ~/ 10000;
          }
        }
      }
      expect(MarketHolidays.lastCoveredYear, maxYear);
    });

    test('日历还没过期（过了 lastCoveredYear 这条会红：请补下一年的表）', () {
      final int nowYear = DateTime.now().year;
      expect(
        nowYear,
        lessThanOrEqualTo(MarketHolidays.lastCoveredYear),
        reason:
            '交易日历只写到 ${MarketHolidays.lastCoveredYear} 年，'
            '现在已是 $nowYear 年——春节/国庆会重新显示成「交易中」。'
            '请按交易所通知补齐后更新 lastCoveredYear。',
      );
    });
  });

  group('抽查官方通知里的日期', () {
    // 上证公告〔2025〕45 号：2026 年春节 2/15–2/23 休市、2/24 开市。
    test('A 股 2026 春节：2/16–2/20 与 2/23 休市，2/24 开市', () {
      for (int day = 16; day <= 20; day++) {
        expect(
          MarketHolidays.isClosedOn(DateTime(2026, 2, day, 10, 0), 'SH'),
          isTrue,
          reason: '2026-02-$day',
        );
      }
      expect(
        MarketHolidays.isClosedOn(DateTime(2026, 2, 23, 10, 0), 'SZ'),
        isTrue,
      );
      expect(
        MarketHolidays.isClosedOn(DateTime(2026, 2, 24, 10, 0), 'SH'),
        isFalse,
      );
    });

    test('A 股 2026 国庆：10/1–10/7 中的工作日全休，10/8 开市', () {
      for (final int day in <int>[1, 2, 5, 6, 7]) {
        expect(
          MarketHolidays.isClosedOn(DateTime(2026, 10, day), 'SH'),
          isTrue,
          reason: '2026-10-$day',
        );
      }
      expect(MarketHolidays.isClosedOn(DateTime(2026, 10, 8), 'SZ'), isFalse);
    });

    test('SH 与 SZ 共用同一张 A 股表', () {
      for (final int key in MarketHolidays.byRegion['A']!) {
        final DateTime day = decode(key);
        expect(MarketHolidays.isClosedOn(day, 'SH'), isTrue);
        expect(MarketHolidays.isClosedOn(day, 'SZ'), isTrue);
      }
    });

    // 港交所 2026 年市场假期通告：12/24、12/31、2/16 为半日市。
    test('港股半日市：每年固定三天（除夕、圣诞前夕、新年前夕）', () {
      final Set<int> hkHalf = MarketHolidays.halfDays['HK']!;
      expect(hkHalf.where((int key) => key ~/ 10000 == 2026).toSet(), <int>{
        20260216,
        20261224,
        20261231,
      });
      expect(hkHalf.where((int key) => key ~/ 10000 == 2027).toSet(), <int>{
        20270205,
        20271224,
        20271231,
      });
      expect(
        MarketHolidays.isHalfDayOn(DateTime(2026, 12, 24, 9, 30), 'HK'),
        isTrue,
      );
      expect(
        MarketHolidays.isHalfDayOn(DateTime(2026, 12, 25, 9, 30), 'HK'),
        isFalse,
        reason: '圣诞当天是全天休市，不是半日市',
      );
    });

    // NYSE 公告：2026 年独立日（周六）改在 7/3 休市；11/27、12/24 提前收市。
    test('美股 2026：7/3 全天休市，11/27 与 12/24 是半日市', () {
      expect(MarketHolidays.isClosedOn(DateTime(2026, 7, 3), 'US'), isTrue);
      expect(MarketHolidays.isHalfDayOn(DateTime(2026, 11, 27), 'US'), isTrue);
      expect(MarketHolidays.isHalfDayOn(DateTime(2026, 12, 24), 'US'), isTrue);
    });

    test('未知市场按 A 股口径（老报文没有 r 字段）', () {
      expect(MarketHolidays.isClosedOn(DateTime(2026, 2, 17), ''), isTrue);
      expect(MarketHolidays.isClosedOn(DateTime(2026, 2, 17), 'ZZ'), isTrue);
    });
  });
}
