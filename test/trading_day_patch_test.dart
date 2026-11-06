import 'package:flutter_test/flutter_test.dart';

import 'package:super_market/models/kline.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/widgets/kline_chart.dart';

/// 这一组守的是 `patchTodayBar` 的**日期口径**，不是「能不能拼上今天」。
///
/// 两件事必须同时成立，缺一件图就会静默画错（不报错、不崩，只是数字对不上）：
///
/// ① **单调**：日 K 序列的时间只能不减。报价比末根更旧时（退后台跨交易日、
///    刚加自选、网络失败期间点开详情、美股折算到前一日）一律不许追加，
///    否则 painter 按数组序画出「最后一根比倒数第二根更旧」的图，MA5/MA10
///    在乱序收盘价上求值，时间轴刻度倒序。
///
/// ② **口径**：`Kline.time` 是**交易日标签**，`Quote.timestamp` 是**北京
///    挂钟的一个瞬间**。拿后者的 `.day` 直接当交易日，对美股恒定错一天：
///    北京 11-04 03:00 是美东 11-03 的盘中（收盘 16:00 ET = 北京次日 04:00/05:00）。
///    所以美股必须先折算成美东挂钟再取日历日。

Quote _quote({
  required double price,
  required DateTime at,
  String region = 'SH',
  double open = 0,
  double high = 0,
  double low = 0,
  double volume = 0,
  double prevClose = 1439.1,
}) {
  return Quote(
    code: '600519',
    region: region,
    price: price,
    change: price - prevClose,
    changePercent: prevClose > 0 ? (price - prevClose) / prevClose * 100 : 0,
    previousClose: prevClose,
    open: open,
    high: high,
    low: low,
    volume: volume,
    timestamp: at,
  );
}

Kline _bar(
  DateTime t,
  double close, {
  double? open,
  double? high,
  double? low,
  double volume = 100000,
}) {
  return Kline(
    time: t,
    open: open ?? close - 1,
    high: high ?? close + 2,
    low: low ?? close - 2,
    close: close,
    volume: volume,
  );
}

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

/// 时间单调不减：逐根比较，失败时报出具体下标，别只说「不等」。
void _expectNonDecreasing(List<Kline> bars, {String? reason}) {
  for (int i = 1; i < bars.length; i++) {
    expect(
      _day(bars[i].time).isBefore(_day(bars[i - 1].time)),
      isFalse,
      reason:
          '第 $i 根（${bars[i].time}）早于第 ${i - 1} 根（${bars[i - 1].time}）'
          '${reason == null ? '' : '：$reason'}',
    );
  }
}

void main() {
  group('patchTodayBar：报价日期早于末根', () {
    test('陈旧报价（11-02）不得追加到 11-03 之后，序列单调不减', () {
      final List<Kline> bars = <Kline>[
        _bar(DateTime(2026, 11, 2), 1439.10),
        _bar(DateTime(2026, 11, 3), 1451.01),
      ];
      // 退后台跨交易日再回来，轮询给的还是一条 11-02 的快照
      final List<Kline> out = patchTodayBar(
        bars,
        _quote(price: 1450.00, at: DateTime(2026, 11, 2, 14, 30)),
      );

      expect(out.length, 2, reason: '更旧的一天不能在末尾多出一根');
      expect(out.last.time, DateTime(2026, 11, 3), reason: '末根仍是 11-03');
      expect(out.last.close, 1451.01, reason: '末根的收盘不能被陈旧价改写');
      expect(identical(out, bars), isTrue, reason: '什么都没改就别造新 List（白重绘）');
      _expectNonDecreasing(out);
    });

    test('陈旧到早两天也一样（11-01 报价 + 11-03 末根）', () {
      final List<Kline> bars = <Kline>[
        _bar(DateTime(2026, 11, 3), 1451.01),
      ];
      final List<Kline> out = patchTodayBar(
        bars,
        _quote(price: 1440.00, at: DateTime(2026, 11, 1, 15, 0)),
      );

      expect(out.length, 1);
      expect(out.single.time, DateTime(2026, 11, 3));
      expect(out.single.close, 1451.01);
    });

    test('末根之后的新交易日照常追加（守卫不能过严）', () {
      final List<Kline> bars = <Kline>[
        _bar(DateTime(2026, 11, 5), 1440.00),
        _bar(DateTime(2026, 11, 6), 1442.00), // 周五
      ];
      // 周一盘中：新浪日线还停在周五，今日那根必须拼上
      final List<Kline> out = patchTodayBar(
        bars,
        _quote(price: 1460.00, at: DateTime(2026, 11, 9, 10, 20)),
      );

      expect(out.length, 3);
      expect(out.last.time, DateTime(2026, 11, 9));
      expect(out.last.close, 1460.00);
      _expectNonDecreasing(out);
    });

    test('同一报价连应用两次 → 不膨胀、不漂移（在途轮询重放）', () {
      final List<Kline> bars = <Kline>[
        _bar(DateTime(2026, 11, 2), 1439.10),
      ];
      final Quote q = _quote(
        price: 1451.01,
        at: DateTime(2026, 11, 3, 10, 45),
        open: 1450,
        high: 1458,
        low: 1435,
        volume: 2532700,
      );
      final List<Kline> once = patchTodayBar(bars, q);
      final List<Kline> twice = patchTodayBar(once, q);

      expect(once.length, 2);
      expect(twice.length, 2, reason: '第二次必须走覆盖，不能再拼一根');
      expect(twice.last.time, once.last.time);
      expect(twice.last.open, once.last.open);
      expect(twice.last.high, once.last.high);
      expect(twice.last.low, once.last.low);
      expect(twice.last.close, once.last.close);
      expect(twice.last.volume, once.last.volume);
    });
  });

  group('patchTodayBar：美股按美东交易日取日期', () {
    test('北京 11-04 03:00（美东 11-03 14:00，冬令时）→ 覆盖 11-03，不多一根', () {
      final List<Kline> bars = <Kline>[
        _bar(DateTime(2026, 11, 2), 325.58),
        _bar(DateTime(2026, 11, 3), 331.90, volume: 63160026),
      ];
      final List<Kline> out = patchTodayBar(
        bars,
        _quote(
          price: 349.51,
          at: DateTime(2026, 11, 4, 3, 0),
          region: 'US',
          open: 341.57,
          high: 354.50,
          low: 340.99,
          volume: 89637749,
        ),
      );

      expect(out.length, 2, reason: '北京已经是 11-04，但美东还在 11-03 盘中');
      expect(out.last.time, DateTime(2026, 11, 3), reason: '交易日是美东 11-03');
      expect(out.last.close, 349.51);
      expect(out[0].time, DateTime(2026, 11, 2), reason: '旧的 11-02 不动');
      _expectNonDecreasing(out);
    });

    test('北京 03-10 03:00（美东 03-09 15:00，夏令时）→ 覆盖 03-09', () {
      final List<Kline> bars = <Kline>[
        _bar(DateTime(2026, 3, 9), 300.00, volume: 50000000),
      ];
      final List<Kline> out = patchTodayBar(
        bars,
        _quote(
          price: 305.00,
          at: DateTime(2026, 3, 10, 3, 0),
          region: 'US',
          open: 301.00,
          high: 306.00,
          low: 299.00,
          volume: 51000000,
        ),
      );

      expect(out.length, 1);
      expect(out.last.time, DateTime(2026, 3, 9));
      expect(out.last.close, 305.00);
    });

    test('美股盘前（北京 17:00 = 美东 04:00）→ 折算后是当日，不是次日', () {
      final List<Kline> bars = <Kline>[
        _bar(DateTime(2026, 11, 3), 331.90),
      ];
      final List<Kline> out = patchTodayBar(
        bars,
        _quote(
          price: 331.90,
          at: DateTime(2026, 11, 4, 17, 0),
          region: 'US',
          open: 331.90,
          high: 331.90,
          low: 331.90,
        ),
      );

      expect(out.length, 2, reason: '美东 11-04 的盘前属于 11-04 这一天');
      expect(out.last.time, DateTime(2026, 11, 4));
      _expectNonDecreasing(out);
    });
  });

  group('patchTodayBar：A 股 / 港股同日覆盖（回归，行为不变）', () {
    test('A 股同日：open 取 K 线、high 取 max、volume 为 0 时保留原值', () {
      final List<Kline> bars = <Kline>[
        _bar(DateTime(2026, 11, 2), 1439.10),
        _bar(
          DateTime(2026, 11, 3),
          1451.01,
          open: 1400.00,
          high: 1460.00,
          low: 1430.00,
          volume: 2532700,
        ),
      ];
      final List<Kline> out = patchTodayBar(
        bars,
        _quote(
          price: 1453.88,
          at: DateTime(2026, 11, 3, 14, 0),
          open: 0, // 报价的开盘价偶尔为 0
          high: 1455.00,
          low: 1435.00,
          volume: 0, // 报价没给量
        ),
      );

      expect(out.length, 2, reason: '同一天只覆盖，不追加');
      expect(out.last.open, 1400.00, reason: '开盘价以 K 线为准');
      expect(out.last.high, 1460.00, reason: 'high 取两者 max');
      expect(out.last.low, 1430.00, reason: 'low 取两者 min');
      expect(out.last.close, 1453.88, reason: '收盘取实时价');
      expect(out.last.volume, 2532700, reason: '量为 0 时保留 K 线的量');
      expect(out.first.close, 1439.10, reason: '更早的棒原样保留');
    });

    test('港股同日（北京挂钟）：覆盖，不折算', () {
      final List<Kline> bars = <Kline>[
        _bar(DateTime(2026, 11, 3), 398.00, volume: 13442881),
      ];
      final List<Kline> out = patchTodayBar(
        bars,
        _quote(
          price: 400.20,
          at: DateTime(2026, 11, 3, 13, 43),
          region: 'HK',
          open: 399.00,
          high: 401.00,
          low: 396.00,
          volume: 14000000,
        ),
      );

      expect(out.length, 1);
      expect(out.last.time, DateTime(2026, 11, 3));
      expect(out.last.close, 400.20);
    });
  });

  group('patchTodayBar：边界与异常输入', () {
    test('bars 为空 + 有效报价 → 只有一根，且日期按市场口径', () {
      final List<Kline> out = patchTodayBar(
        const <Kline>[],
        _quote(price: 349.51, at: DateTime(2026, 11, 4, 3, 0), region: 'US'),
      );
      expect(out.length, 1);
      expect(out.single.time, DateTime(2026, 11, 3), reason: '美东交易日');
    });

    test('报价无数据（停牌 / 退市 0 值）→ 原样返回同一个 List', () {
      final List<Kline> bars = <Kline>[_bar(DateTime(2026, 11, 3), 1451.01)];
      final Quote empty = Quote.empty('600519');
      expect(identical(patchTodayBar(bars, empty), bars), isTrue);
      expect(
        identical(
          patchTodayBar(bars, _quote(price: 0, at: DateTime(2026, 11, 4, 10, 0))),
          bars,
        ),
        isTrue,
      );
    });

    test('报价无 timestamp → 原样返回同一个 List', () {
      final List<Kline> bars = <Kline>[_bar(DateTime(2026, 11, 3), 1451.01)];
      const Quote q = Quote(
        code: '600519',
        price: 1451.01,
        change: 12,
        changePercent: 0.8,
      );
      expect(identical(patchTodayBar(bars, q), bars), isTrue);
    });
  });
}
