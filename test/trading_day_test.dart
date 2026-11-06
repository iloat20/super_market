import 'package:flutter_test/flutter_test.dart';

import 'package:super_market/utils/trading_day.dart';

/// 「某市场的交易日」必须是**一个**可测的纯函数。
///
/// 这一组存在的理由：日期键一旦被就地算出来（`DateTime(q.timestamp.year,
/// q.timestamp.month, q.timestamp.day)`），美股的误差是**恒定一天**，而且
/// 不会抛异常、不会崩，只是图上多一根 / 末根画的是昨天。把它抽成函数之后，
/// 夏令时、跨零点、非交易时段这些边界才有地方被钉住。

void main() {
  group('tradingDayOf：瞬间 → 交易日', () {
    test('A 股 / 港股：与北京挂钟同一日历日', () {
      expect(
        tradingDayOf(DateTime(2026, 11, 3, 10, 45), 'SH'),
        DateTime(2026, 11, 3),
      );
      expect(
        tradingDayOf(DateTime(2026, 11, 3, 14, 0), 'SZ'),
        DateTime(2026, 11, 3),
      );
      expect(
        tradingDayOf(DateTime(2026, 11, 3, 13, 43), 'HK'),
        DateTime(2026, 11, 3),
      );
    });

    test('美股：北京凌晨的瞬间属于前一个美东日历日', () {
      // 冬令时：北京 = ET + 13，美股收盘 16:00 ET = 北京次日 05:00
      expect(
        tradingDayOf(DateTime(2026, 11, 4, 3, 0), 'US'),
        DateTime(2026, 11, 3),
        reason: 'ET 11-03 14:00，盘中',
      );
      expect(
        tradingDayOf(DateTime(2026, 11, 4, 0, 30), 'US'),
        DateTime(2026, 11, 3),
        reason: 'ET 11-03 11:30，盘中',
      );
      // 夏令时：北京 = ET + 12
      expect(
        tradingDayOf(DateTime(2026, 6, 16, 3, 0), 'US'),
        DateTime(2026, 6, 15),
        reason: 'ET 06-15 15:00，盘中',
      );
    });

    test('美股：北京晚间开盘后仍是同一个日历日', () {
      // 冬令时 22:30 开盘 = ET 09:30
      expect(
        tradingDayOf(DateTime(2026, 11, 4, 22, 30), 'US'),
        DateTime(2026, 11, 4),
      );
      // 夏令时 21:30 开盘 = ET 09:30
      expect(
        tradingDayOf(DateTime(2026, 6, 16, 21, 30), 'US'),
        DateTime(2026, 6, 16),
      );
    });

    test('美股：北京 12:00–13:00 的瞬间必须按夏令时规则折算，不能写死 -13h', () {
      // 这一小时是唯一「-12 与 -13 会得到不同日期」的窗口。
      // 收盘后的陈旧报文可能落在这里，写死偏移会算错一天。
      expect(
        tradingDayOf(DateTime(2026, 6, 15, 12, 30), 'US'),
        DateTime(2026, 6, 15),
        reason: '夏令时 ET 06-15 00:30；写死 -13h 会得到 06-14',
      );
      expect(
        tradingDayOf(DateTime(2026, 11, 4, 12, 30), 'US'),
        DateTime(2026, 11, 3),
        reason: '冬令时 ET 11-03 23:30；写死 -12h 会得到 11-04',
      );
    });

    test('未知 / 空 region 退回北京挂钟口径（老报文没有 r 字段）', () {
      expect(tradingDayOf(DateTime(2026, 11, 4, 3, 0), ''), DateTime(2026, 11, 4));
      expect(
        tradingDayOf(DateTime(2026, 11, 4, 3, 0), 'NASDAQ'),
        DateTime(2026, 11, 4),
      );
    });
  });

  group('easternWallClock：北京挂钟 → 美东挂钟', () {
    test('冬令时 -13h、夏令时 -12h', () {
      final DateTime winter = easternWallClock(DateTime(2026, 11, 2, 21, 0));
      expect(winter, DateTime(2026, 11, 2, 8, 0));
      final DateTime summer = easternWallClock(DateTime(2026, 6, 15, 21, 0));
      expect(summer, DateTime(2026, 6, 15, 9, 0));
    });

    test('折算后跨回前一天（北京 03:00 → 美东 14:00 / 15:00 前一日）', () {
      expect(
        easternWallClock(DateTime(2026, 11, 4, 3, 0)),
        DateTime(2026, 11, 3, 14, 0),
      );
      expect(
        easternWallClock(DateTime(2026, 6, 16, 3, 0)),
        DateTime(2026, 6, 15, 15, 0),
      );
    });
  });
}
