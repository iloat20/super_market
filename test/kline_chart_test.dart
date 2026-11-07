import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:super_market/models/kline.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/widgets/kline_chart.dart';

/// 这两件事最容易悄悄做错，而错了**不会报错、也不崩**，只是图上数字对不上：
/// ① 日线的「今天」这根要不要拼；② 分时的最后一个点要不要跟着实时价走。
/// 所以它们被写成纯函数、单独测，而不是埋在 painter 里。

Quote _quote({
  required double price,
  required DateTime at,
  double open = 1450,
  double high = 1458,
  double low = 1435,
  double volume = 2532700,
  double prevClose = 1439.1,
}) {
  return Quote(
    code: '600519',
    region: 'SH',
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

Kline _bar(DateTime t, double close) => Kline(
      time: t,
      open: close - 1,
      high: close + 2,
      low: close - 2,
      close: close,
      volume: 100000,
    );

void main() {
  group('patchTodayBar：日线的「今天」', () {
    test('新浪日线到昨天 + 实时报价 → 追加今日一根', () {
      final List<Kline> bars = <Kline>[
        _bar(DateTime(2026, 10, 30), 1392.05),
        _bar(DateTime(2026, 11, 2), 1439.10),
      ];
      final Quote q = _quote(price: 1451.01, at: DateTime(2026, 11, 3, 10, 45));
      final List<Kline> out = patchTodayBar(bars, q);

      expect(out.length, 3);
      expect(out.last.time, DateTime(2026, 11, 3));
      expect(out.last.close, 1451.01);
      expect(out.last.open, 1450);
      expect(out.last.high, 1458);
      expect(out.last.low, 1435);
    });

    test('腾讯日线已含今日 + 实时报价 → 覆盖而不是再追加一根', () {
      final List<Kline> bars = <Kline>[
        _bar(DateTime(2026, 11, 2), 1439.10),
        _bar(DateTime(2026, 11, 3), 1451.01),
      ];
      final Quote q = _quote(price: 1453.88, at: DateTime(2026, 11, 3, 10, 46));
      final List<Kline> out = patchTodayBar(bars, q);

      expect(out.length, 2); // 关键：不是 3
      expect(out.last.close, 1453.88);
      // 开盘价以 K 线为准（报价的 open 偶尔是 0）
      expect(out.last.open, bars.last.open);
      // 高低取并集：接口那份可能比实时值旧
      expect(out.last.high, greaterThanOrEqualTo(1458));
    });

    test('实时报价没有时间戳 → 原样返回（不能凭空造一根）', () {
      final List<Kline> bars = <Kline>[_bar(DateTime(2026, 11, 2), 1439.1)];
      const Quote q = Quote(
        code: '600519',
        price: 1451.01,
        change: 12,
        changePercent: 0.8,
      );
      expect(patchTodayBar(bars, q).length, 1);
    });

    test('空数据 + 空报价 → 空（不要造出一根 0 价的柱子）', () {
      final Quote empty = Quote.empty('600519');
      expect(patchTodayBar(const <Kline>[], empty), isEmpty);
      expect(
        patchTodayBar(const <Kline>[], _quote(price: 0, at: DateTime(2026, 11, 3))),
        isEmpty,
      );
    });
  });

  group('patchLatestPrice：分时的最后一个点', () {
    List<IntradayPoint> points(DateTime day) => <IntradayPoint>[
          IntradayPoint(
            time: DateTime(day.year, day.month, day.day, 9, 30),
            price: 1450,
            avgPrice: 1450,
            volume: 165000,
          ),
          IntradayPoint(
            time: DateTime(day.year, day.month, day.day, 10, 44),
            price: 1446.30,
            avgPrice: 1448.2,
            volume: 162000,
          ),
        ];

    test('同一天 → 最后一点换成实时价，其余不动', () {
      final DateTime day = DateTime(2026, 11, 3);
      final List<IntradayPoint> out = patchLatestPrice(
        points(day),
        _quote(price: 1451.01, at: DateTime(2026, 11, 3, 10, 45)),
      );
      expect(out.length, 2);
      expect(out.first.price, 1450); // 首点不动
      expect(out.last.price, 1451.01);
      expect(out.last.avgPrice, 1448.2); // 均价是累计算出来的，不该被单价污染
      expect(out.last.volume, 162000);
    });

    test('报价是另一天 → 不动（别把昨天的线画成今天的价）', () {
      final List<IntradayPoint> out = patchLatestPrice(
        points(DateTime(2026, 11, 2)),
        _quote(price: 1451.01, at: DateTime(2026, 11, 3, 10, 45)),
      );
      expect(out.last.price, 1446.30);
    });

    test('没有点 / 报价为空 → 原样返回', () {
      expect(
        patchLatestPrice(const <IntradayPoint>[],
            _quote(price: 1451.01, at: DateTime(2026, 11, 3, 10, 45))),
        isEmpty,
      );
      expect(
        patchLatestPrice(
          points(DateTime(2026, 11, 3)),
          Quote.empty('600519'),
        ).last.price,
        1446.30,
      );
    });
  });

  group('movingAverage：日 K 均线', () {
    test('前 period-1 个位置没有值，之后逐根右移', () {
      expect(
        movingAverage(<double>[1, 2, 3, 4, 5, 6], 5),
        <double?>[null, null, null, null, 3, 4],
      );
    });

    test('样本不足 period → 全空（不能拿半个窗口冒充均线）', () {
      expect(movingAverage(<double>[10, 20, 30], 5), <double?>[null, null, null]);
    });

    test('空输入 → 空输出', () {
      expect(movingAverage(const <double>[], 5), isEmpty);
    });

    test('period <= 1 → 原值（不做无意义的平移）', () {
      expect(movingAverage(<double>[7, 8], 1), <double?>[7, 8]);
      expect(movingAverage(<double>[7, 8], 0), <double?>[7, 8]);
    });

    test('窗口内真正求平均，不是取末值', () {
      // (10+20+30)/3 = 20，若实现误取最后一位会得到 30
      expect(movingAverage(<double>[10, 20, 30], 3), <double?>[null, null, 20]);
    });
  });

  group('tradingMinute：分时横轴', () {
    DateTime at(int h, int m) => DateTime(2026, 11, 3, h, m);

    test('开盘 0、上午收盘 120、下午开盘 120、收盘 240', () {
      expect(tradingMinute(at(9, 30)), 0);
      expect(tradingMinute(at(11, 30)), 120);
      expect(tradingMinute(at(13, 0)), 120);
      expect(tradingMinute(at(15, 0)), 240);
    });

    test('10:45 只走了 75/240，线不该铺满整张图', () {
      expect(tradingMinute(at(10, 45)), 75);
    });

    test('午休期间夹在上午收盘那一刻（不能让它占宽度）', () {
      expect(tradingMinute(at(12, 0)), 120);
      expect(tradingMinute(at(12, 59)), 120);
    });

    test('开盘前/收盘后夹到两端，不会画出界', () {
      expect(tradingMinute(at(9, 0)), 0);
      expect(tradingMinute(at(15, 30)), 240);
    });
  });

  group('tradingMinute(us:true)：美股分时横轴（美东挂钟，无午休）', () {
    DateTime at(int h, int m) => DateTime(2026, 11, 4, h, m); // 周三

    test('总分钟数 390（09:30–16:00 连续）', () {
      expect(tradingMinutesOf(hk: false, us: true), 390);
    });

    test('开盘 0、盘中线性推进、收盘 390', () {
      expect(tradingMinute(at(9, 30), us: true), 0);
      expect(tradingMinute(at(10, 30), us: true), 60);
      expect(
        tradingMinute(at(12, 45), us: true),
        195,
        reason: '全程中点，时间轴中缝刻度就写它',
      );
      expect(tradingMinute(at(16, 0), us: true), 390);
    });

    test('没有午休：12:00 连续推进而不是夹在 120', () {
      expect(tradingMinute(at(12, 0), us: true), 150);
      expect(tradingMinute(at(12, 59), us: true), 209);
    });

    test('盘前/盘后夹到两端', () {
      expect(tradingMinute(at(9, 0), us: true), 0);
      expect(tradingMinute(at(20, 0), us: true), 390);
    });
  });

  // U-01（review-2026-11-05）：shouldRepaint 的比较集必须是「全部影响绘制的
  // 字段」。axisStyle / hk / us 漏比时，任何样式口径变化（换字体、换区域）
  // 都不会触发重绘，刻度文字停留在旧样式。
  //
  // ⚠️ 审查时曾误判「系统字体缩放会让刻度停在旧字号」——实际不成立：
  // axisStyle 是 `DefaultTextStyle.style.copyWith(fontSize: 9.5, …)`，
  // fontSize 被 copyWith 钉死，图表本身缩放不变。第二段用例把这个语义
  // 钉住：若将来有人解开 fontSize 的钉子而忘了更新 shouldRepaint，它会红。
  CustomPainter painterOf(WidgetTester tester) => tester
      .renderObject<RenderCustomPaint>(
        find.descendant(
          of: find.byType(KlineChart),
          matching: find.byWidgetPredicate((Widget w) => w is CustomPaint),
        ),
      )
      .painter!;

  // ⚠️ bars 必须只建一次、两次 pump 共用同一个 List 实例：
  // shouldRepaint 对 bars 用 identical 判断，每次新建会让 identical 恒为
  // false，两条用例都会被「数据变了」蒙混过关，测不到样式比较本身。
  final List<Kline> sharedBars = <Kline>[
    _bar(DateTime(2026, 11, 3), 1451.01),
    _bar(DateTime(2026, 11, 4), 1453.88),
  ];

  Widget host(WidgetTester tester, {TextStyle? base, double scale = 1.0}) {
    tester.view.physicalSize = const Size(390 * 3, 182 * 3);
    tester.view.devicePixelRatio = 3;
    Widget chart = KlineChart(mode: ChartMode.daily, bars: sharedBars);
    if (base != null) {
      chart = DefaultTextStyle(style: base, child: chart);
    }
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(body: Center(child: chart)),
      ),
    );
  }

  testWidgets('axisStyle 真变化（fontFamily）→ 必须要求重绘', (WidgetTester tester) async {
    await tester.pumpWidget(host(tester, base: const TextStyle(fontSize: 14, fontFamily: 'Roboto')));
    final CustomPainter first = painterOf(tester);

    // 同一份 bars，只换了字体族——axisStyle 里的 fontFamily 会跟着变
    await tester.pumpWidget(
      host(tester, base: const TextStyle(fontSize: 14, fontFamily: 'Courier')),
    );
    final CustomPainter second = painterOf(tester);

    expect(
      second.shouldRepaint(first),
      isTrue,
      reason: 'axisStyle 变了还返回 false，刻度会停留在旧字体',
    );
  });

  testWidgets('字体缩放变化 → 刻意不重绘（fontSize 被 copyWith 钉死，图是缩放不变的）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(tester, scale: 1.0));
    final CustomPainter first = painterOf(tester);

    await tester.pumpWidget(host(tester, scale: 2.0));
    final CustomPainter second = painterOf(tester);

    expect(
      second.shouldRepaint(first),
      isFalse,
      reason: 'fontSize 钉在 9.5，缩放不改变任何绘制输入；'
          '若此断言变红，说明钉子被解开而 shouldRepaint 没跟上',
    );
  });
}
