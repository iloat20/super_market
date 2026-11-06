import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/services/kline_loader.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/widgets/kline_chart.dart';
import 'package:super_market/widgets/quote_detail_sheet.dart';

/// 详情弹层里的走势图：默认打开「分时」、能切到「日 K」、拉不到数据时给一行
/// 可重试的提示，而且**不能因此弄坏八项指标**。

const StockConfig kMaotai = StockConfig(
  code: '600519',
  name: '贵州茅台',
  region: 'SH',
);

const StockConfig kApple = StockConfig(
  code: 'AAPL',
  name: '苹果',
  region: 'US',
  exchange: 'NASDAQ',
);

const String _intraday = '''
{"result":{"status":{"code":0},"data":[
 {"day":"2026-11-03 09:30:00","open":"1450","high":"1450","low":"1450","close":"1450","volume":"165000","amount":"239250000"},
 {"day":"2026-11-03 09:31:00","open":"1450","high":"1451","low":"1436","close":"1436","volume":"162000","amount":"233109222"},
 {"day":"2026-11-03 10:44:00","open":"1440","high":"1450","low":"1439","close":"1446.30","volume":"120000","amount":"173000000"}]}}''';

const String _daily = '''
{"result":{"status":{"code":0},"data":[
 {"day":"2026-10-30","open":"1363.000","high":"1393.370","low":"1352.980","close":"1392.050","volume":"5992729"},
 {"day":"2026-11-02","open":"1410.000","high":"1447.000","low":"1395.020","close":"1439.100","volume":"8269122"}]}}''';

/// 美股走腾讯 ifzq（新浪 K 线不支持美股，loader 链里被 supports 跳过），
/// 形状是 `{"code":0,"data":{"usAAPL.OQ":{"day":[[日期,开,收,高,低,量(股)],…]}}}`。
/// 数据取自 2026-11-05 真网探针（tool/us_live_probe_test.dart）。
const String _usDaily = '''
{"code":0,"msg":"","data":{"usAAPL.OQ":{"day":[
 ["2026-11-03","325.580","331.900","334.500","325.330","63160026.000"],
 ["2026-11-04","341.570","349.510","354.500","340.990","89637749.000"]],
"qt":{},"prec":"343.990","version":"16"}}}''';

Quote _quote({double price = 1451.01, String code = '600519', String region = 'SH'}) =>
    Quote(
      code: code,
      region: region,
      price: price,
      change: price - 1439.1,
      changePercent: (price - 1439.1) / 1439.1 * 100,
      previousClose: 1439.1,
      open: 1450,
      high: 1458,
      low: 1435,
      volume: 2532700,
      turnover: 3658010435,
      timestamp: DateTime(2026, 11, 3, 10, 45),
    );

KlineLoader _loader({
  required bool intradayOk,
  required bool dailyOk,
}) {
  return KlineLoader(
    httpGet: (Uri uri, Map<String, String> headers) async {
      final bool isDaily = uri.queryParameters['scale'] == '240';
      final bool ok = isDaily ? dailyOk : intradayOk;
      if (!ok) {
        return const HttpRawResponse(statusCode: 502, body: <int>[]);
      }
      return HttpRawResponse(
        statusCode: 200,
        body: utf8.encode(isDaily ? _daily : _intraday),
      );
    },
  );
}

/// 美股 loader：日线走腾讯 fqkline（按路径判别），fixtrue 用真探针报文。
KlineLoader _usLoader({required bool dailyOk}) {
  return KlineLoader(
    httpGet: (Uri uri, Map<String, String> headers) async {
      if (!dailyOk) {
        return const HttpRawResponse(statusCode: 502, body: <int>[]);
      }
      return HttpRawResponse(
        statusCode: 200,
        body: utf8.encode(_usDaily),
      );
    },
  );
}

Future<void> _open(
  WidgetTester tester, {
  required KlineLoader loader,
  Quote? quote,
  StockConfig stock = kMaotai,
}) async {
  final ValueNotifier<Quote> notifier =
      ValueNotifier<Quote>(quote ?? _quote());
  addTearDown(notifier.dispose);

  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showQuoteDetailSheet(
                context,
                stock: stock,
                quote: notifier,
                loader: loader,
              ),
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
  testWidgets('默认打开「分时」，两个 tab 都在，图上标了走势源', (WidgetTester tester) async {
    await _open(tester, loader: _loader(intradayOk: true, dailyOk: true));

    expect(find.text('分时'), findsOneWidget);
    expect(find.text('日K'), findsOneWidget);
    expect(find.byType(KlineChart), findsOneWidget);

    final KlineChart chart = tester.widget<KlineChart>(find.byType(KlineChart));
    expect(chart.mode, ChartMode.intraday);
    expect(chart.points.length, 3);
    expect(chart.prevClose, 1439.1);
    // 最后一个点被实时价覆盖（分时数据到 10:44，报价是 10:45 的 1451.01）
    expect(chart.points.last.price, 1451.01);

    // 走势源单独标注：主备切换是静默的，图换源了得能看见
    expect(find.text('新浪'), findsOneWidget);
  });

  testWidgets('切到「日K」会换成蜡烛图，并把今天那根拼进序列', (WidgetTester tester) async {
    await _open(tester, loader: _loader(intradayOk: true, dailyOk: true));

    await tester.tap(find.text('日K'));
    await tester.pumpAndSettle();

    final KlineChart chart = tester.widget<KlineChart>(find.byType(KlineChart));
    expect(chart.mode, ChartMode.daily);
    // 接口给到 11-02，实时报价是 11-03 → 拼出第三根
    expect(chart.bars.length, 3);
    expect(chart.bars.last.time, DateTime(2026, 11, 3));
    expect(chart.bars.last.close, 1451.01);
    expect(chart.points, isEmpty);
  });

  testWidgets('切图有一次 120ms 淡入（只淡入，不交叉淡化）', (WidgetTester tester) async {
    await _open(tester, loader: _loader(intradayOk: true, dailyOk: true));

    await tester.tap(find.text('日K'));
    // 两帧：第一帧走 setState 进 loading，第二帧假 loader 的 Future 落地、图建出来
    await tester.pump();
    await tester.pump();

    final Finder fade = find
        .ancestor(of: find.byType(KlineChart), matching: find.byType(Opacity))
        .first;
    expect(
      tester.widget<Opacity>(fade).opacity,
      lessThan(0.2),
      reason: '新图必须从接近透明开始，否则就是瞬切',
    );

    await tester.pump(const Duration(milliseconds: 60));
    final double mid = tester.widget<Opacity>(fade).opacity;
    expect(mid, greaterThan(0.2), reason: '60ms 时应当已经过半');
    expect(mid, lessThan(1), reason: '60ms 时还没到终态');

    await tester.pumpAndSettle();
    expect(
      tester.widget<Opacity>(fade).opacity,
      1,
      reason: '稳态必须是 1.0 —— Opacity 为 1 时 Flutter 会跳过 saveLayer，不再有开销',
    );
  });

  testWidgets('拉不到走势 → 一行「点此重试」，八项指标照常显示',
      (WidgetTester tester) async {
    await _open(tester, loader: _loader(intradayOk: false, dailyOk: false));

    expect(find.text('走势暂不可用 · 点此重试'), findsOneWidget);
    expect(find.byType(KlineChart), findsNothing);

    // 图挂了不能让指标跟着消失
    expect(find.text('今开'), findsOneWidget);
    expect(find.text('昨收'), findsOneWidget);
    expect(find.text('成交额'), findsOneWidget);
    expect(find.text('1451.01'), findsOneWidget);
  });

  testWidgets('重试会绕开缓存重新请求', (WidgetTester tester) async {
    int calls = 0;
    final KlineLoader loader = KlineLoader(
      httpGet: (Uri uri, Map<String, String> headers) async {
        calls++;
        return const HttpRawResponse(statusCode: 502, body: <int>[]);
      },
    );
    await _open(tester, loader: loader);
    expect(calls, 2); // 新浪 + 腾讯各一次

    await tester.tap(find.text('走势暂不可用 · 点此重试'));
    await tester.pumpAndSettle();
    expect(calls, 4); // 失败不写缓存，重试真的又打了一轮
  });

  group('美股详情页：走势不可用就直接不显示', () {
    testWidgets('默认打开「日K」（分时 tab 不渲染），腾讯日线正常出图', (
      WidgetTester tester,
    ) async {
      await _open(
        tester,
        loader: _usLoader(dailyOk: true),
        stock: kApple,
        // 北京 11-05 03:30 = 美东 11-04 14:30（冬令时，盘中）——报价与末根
        // 在**美东交易日**口径下是同一天。这是美股唯一正确的重叠方式：
        // 北京日期（11-05）比美东交易日（11-04）大一天，直接拿北京日历日
        // 当键会多出一根 11-05 的"未来棒"。
        quote: Quote(
          code: 'AAPL',
          region: 'US',
          price: 349.99,
          change: 8.42,
          changePercent: 2.46,
          previousClose: 341.57,
          open: 341.57,
          high: 354.50,
          low: 340.99,
          volume: 89637749,
          timestamp: DateTime(2026, 11, 5, 3, 30),
        ),
      );

      // 分时对美股没有入口：收盘时段必空，不给一个注定失败的 tab
      expect(find.text('分时'), findsNothing);
      expect(find.text('日K'), findsOneWidget);

      final KlineChart chart = tester.widget<KlineChart>(find.byType(KlineChart));
      expect(chart.mode, ChartMode.daily, reason: '美股默认打开日 K，不是注定为空的分时');
      expect(chart.region, 'US');
      // 腾讯日线（量是股，真探针数值，×100 会变成 8963774900）：
      // fixture 给了 2 根（11-03 / 11-04），报价属美东 11-04 →
      // 覆盖 11-04 那根，**不追加**（长度仍是 2，不是 3）。
      expect(chart.bars.length, 2, reason: '同一交易日只能覆盖，不能凭空多一根');
      expect(chart.bars.first.close, 331.90);
      expect(chart.bars[0].time, DateTime(2026, 11, 3));
      expect(chart.bars[1].time, DateTime(2026, 11, 4), reason: '交易日是美东 11-04');
      expect(
        chart.bars[1].time.isAfter(chart.bars[0].time),
        isTrue,
        reason: '时间必须单调递增，最右一根就是最后一根',
      );
      expect(chart.bars.last.open, 341.570, reason: '开盘价仍以 K 线为准');
      expect(chart.bars.last.close, 349.99, reason: '末根收盘被实时价覆盖（349.510 → 349.99）');
      expect(chart.bars[1].volume, 89637749, reason: '量是股，不是手（×100 会是 8963774900）');

      // 指标区照常
      expect(find.text('今开'), findsOneWidget);
      expect(find.text('349.99'), findsOneWidget);
    });

    testWidgets('日 K 也拉不到 → 整个走势区块不显示（无占位、无 tab）', (
      WidgetTester tester,
    ) async {
      await _open(
        tester,
        loader: _usLoader(dailyOk: false),
        stock: kApple,
        quote: _quote(code: 'AAPL', region: 'US', price: 349.51),
      );

      expect(find.byType(KlineChart), findsNothing);
      expect(find.text('日K'), findsNothing);
      // A 股的「点此重试」占位不出现：美股按「不可用就不显示」处理
      expect(find.text('走势暂不可用 · 点此重试'), findsNothing);

      // 指标区照常，不能被走势消失带偏
      expect(find.text('今开'), findsOneWidget);
      expect(find.text('昨收'), findsOneWidget);
      expect(find.text('成交额 (USD)'), findsOneWidget);
      expect(find.text('349.51'), findsOneWidget);
    });
  });

  group('分时 / 日K 图表区块等高', () {
    testWidgets('切到日K 后指标区不位移，且不再出现「加载更早」「区间摘要」', (
      WidgetTester tester,
    ) async {
      await _open(tester, loader: _loader(intradayOk: true, dailyOk: true));
      final double intradayTop = tester.getRect(find.text('今开')).top;
      // 摘要行已整体移除：两个 tab 图下都不再有任何说明文字
      expect(find.textContaining('区间'), findsNothing);

      await tester.tap(find.text('日K'));
      await tester.pumpAndSettle();
      final double dailyTop = tester.getRect(find.text('今开')).top;

      expect(
        dailyTop,
        intradayTop,
        reason: '两个 tab 的图表区块必须等高，切 tab 不该让指标区位移',
      );
      expect(find.textContaining('区间'), findsNothing);
      expect(find.text('加载更早'), findsNothing);
      expect(find.textContaining('已到最早'), findsNothing);
      // 绘图区本来就等高（KlineChart.height = 182），钉住别再改出差异
      expect(tester.getSize(find.byType(KlineChart)).height, KlineChart.height);
    });
  });

  testWidgets('日K 加 RepaintBoundary，分时不加', (WidgetTester tester) async {
    await _open(tester, loader: _loader(intradayOk: true, dailyOk: true));

    // 分时图跟着价格变，再包一层边界只会让栅格缓存反复失效（更亏）
    expect(
      find.descendant(
        of: find.byType(KlineChart),
        matching: find.byType(RepaintBoundary),
      ),
      findsNothing,
      reason: '分时是动态图，包边界反而增加栅格缓存开销',
    );

    await tester.tap(find.text('日K'));
    await tester.pumpAndSettle();

    // 日K 是静态图：独立图层后，价格每秒跳动都不必重绘它
    expect(
      find.descendant(
        of: find.byType(KlineChart),
        matching: find.byType(RepaintBoundary),
      ),
      findsWidgets,
      reason: '日K 静态，独立成层才不会跟着 tick 重绘',
    );
  });
}
