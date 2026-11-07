import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/pages/quote_list_page.dart';
import 'package:super_market/widgets/quote_tile.dart';
import 'fake_feed.dart';

/// 布局健壮性：窄屏 + 系统大字体。
///
/// 这类问题真机上很常见（用户把「字体大小」调到最大），但在常规截图里永远发现不了。
/// flutter_test 遇到 RenderFlex 溢出会直接报错，所以「能 pump 完不抛异常」本身就是断言。
Widget _host(Widget child, {double scale = 1.0}) {
  return MaterialApp(
    builder: (BuildContext context, Widget? inner) {
      final MediaQueryData data = MediaQuery.of(context);
      return MediaQuery(
        data: data.copyWith(textScaler: TextScaler.linear(scale)),
        child: inner ?? const SizedBox.shrink(),
      );
    },
    home: Scaffold(body: child),
  );
}

/// 布局用例只关心「长名称 + 长代码 + 两位小数价格」这种最宽组合，
/// 与默认订阅列表无关——所以钉住一只固定标的，不受 AppConfig.stocks 变更影响。
const StockConfig _kMaotai = StockConfig(
  code: '600519',
  name: '贵州茅台',
  region: 'SH',
);

void main() {
  testWidgets('360dp 窄屏 + 2.0 倍字体，列表页不溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _host(
        QuoteListPage(
          serviceBuilder: NoopFeed.builder,
        ),
        scale: 2.0,
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    // 2 倍字体下每张卡都很高，List 只会按需构建可见的那几张，
    // 所以这里只断言「至少渲染出一张」而不是「三张都渲染」
    expect(find.byType(QuoteTile), findsAtLeastNWidgets(1));

    // 卸载以取消时段角标的定时器
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('2.0 倍字体下名称与价格同行、代码与胶囊同行', (
    WidgetTester tester,
  ) async {
    // 回归钉子：曾经「大字体/窄屏自动切上下堆叠」会把价格挤到代码下面
    // （真机截图 2026-11-03 用户实证）。现在布局只有一个——价格恒在右侧。
    // 破坏方式：把堆叠分支加回去，本用例立刻变红。
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final ValueNotifier<Quote> q = ValueNotifier<Quote>(
      Quote(
        code: '600519',
        price: 1439.10,
        change: 47.05,
        changePercent: 3.38,
        previousClose: 1392.05,
        open: 1410,
        high: 1447,
        low: 1395.02,
        volume: 82691,
        turnover: 11849258015,
        timestamp: DateTime(2026, 11, 3, 7, 52, 10),
      ),
    );
    addTearDown(q.dispose);

    await tester.pumpWidget(
      _host(
        Padding(
          padding: const EdgeInsets.all(12),
          child: QuoteTile(stock: _kMaotai, quote: q),
        ),
        scale: 2.0,
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    // 两行结构的钉子（2026-11-03）：名称↔价格同行、代码↔胶囊同行。
    // 堆叠布局回归时价格掉到第三行，与名称的垂直中心差会变成几十像素；
    // 旧的左右两列结构回归时名称/代码与价格/胶囊的行中心也对不齐。
    final Rect name = tester.getRect(find.text('贵州茅台'));
    final Rect code = tester.getRect(find.text('600519'));
    final Rect price = tester.getRect(find.text('1439.10'));
    // 量胶囊**容器**（含 padding），不是里面的文字——文字右缘天然比
    // 容器右缘少一个 padding，直接比会把对齐误判成错位
    final Finder badgeContainer = find.byWidgetPredicate(
      (Widget w) =>
          w is Container &&
          w.padding == const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    );
    final Rect badge = tester.getRect(badgeContainer);
    expect((price.center.dy - name.center.dy).abs(), lessThan(1.5),
        reason: '价格与名称不在同一行 = 布局回归（堆叠或错行）');
    expect((badge.center.dy - code.center.dy).abs(), lessThan(1.5),
        reason: '涨跌胶囊与代码不在同一行 = 布局回归');
    // 价格必须整体在代码那一行的上方（第一行），不能掉下去
    expect(price.bottom, lessThanOrEqualTo(code.top + 1.0));
    // 胶囊与价格的右缘对齐（2026-11-03）：胶囊曾挂在 Flexible 上
    // 「漂」在卡片中部，不在股价正下方。右缘差必须在 2px 内。
    expect((badge.right - price.right).abs(), lessThan(2.0),
        reason: '涨跌胶囊没有贴右缘 = 不在股价正下方');
  });

  testWidgets('320dp 极窄屏 + 1.5 倍字体，行情卡不溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320 * 3, 560 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final ValueNotifier<Quote> q = ValueNotifier<Quote>(
      Quote(
        code: '600519',
        price: 1523.45,
        change: 12.34,
        changePercent: 0.82,
        previousClose: 1510.66,
        open: 1520,
        high: 1540,
        low: 1510,
        volume: 2134900,
        turnover: 3170000000,
        timestamp: DateTime(2026, 11, 2, 14, 59, 3),
      ),
    );
    addTearDown(q.dispose);

    await tester.pumpWidget(
      _host(
        Padding(
          padding: const EdgeInsets.all(12),
          child: QuoteTile(stock: _kMaotai, quote: q),
        ),
        scale: 1.5,
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('1523.45'), findsOneWidget);
  });

  testWidgets('真实报价宽度组合不溢出，且胶囊贴右缘（在股价正下方）', (
    WidgetTester tester,
  ) async {
    // 价格/成交额取自 2026-11-03 07:52 的真实 REST 响应（茅台 1439.10 /
    // 118.49 亿）——「高价股 + 大成交额」是最容易撑破布局的组合。
    //
    // 胶囊右缘对齐（2026-11-03 用户截图实证：Flexible 版 golden 里胶囊
    // 文字右缘距价格右缘 49px）。
    //
    // ⚠️ 诚实声明：这里的合成断言**抓不住** Flexible→Expanded 这一档回归——
    // flutter_test 默认字体是 Ahem（每字符 = 1em 方块），胶囊文字天然
    // ~216px，永远撑满 Flexible 配额，两种写法都贴右。真正的决定性守卫是
    // `tool/preview/app_preview_test.dart` 的 cards.png golden：它加载真实
    // 字体（SimHei），胶囊 ~125px < 配额，Flexible 下漂 38px，golden 直接
    // 变红。本用例保留是因为它还钉着「名称↔价格同行、代码↔胶囊同行」。
    tester.view.physicalSize = const Size(390 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final ValueNotifier<Quote> q = ValueNotifier<Quote>(
      Quote(
        code: '600519',
        price: 1439.10,
        change: 0,
        changePercent: 0,
        previousClose: 1439.10,
        open: 1438.00,
        high: 1441.00,
        low: 1436.50,
        volume: 82691,
        turnover: 11849258015,
        timestamp: DateTime(2026, 11, 3, 7, 52, 10),
      ),
    );
    addTearDown(q.dispose);

    await tester.pumpWidget(
      _host(
        Padding(
          padding: const EdgeInsets.all(12),
          child: QuoteTile(stock: _kMaotai, quote: q),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('1439.10'), findsOneWidget);
    // 平盘显示灰色胶囊「0.00  0.00%」
    expect(find.text('0.00  0.00%'), findsOneWidget);

    // 量胶囊**容器**（含 padding），不是里面的文字——文字右缘天然比
    // 容器少一个 padding，直接比会把对齐误判成错位
    final Finder badgeContainer = find.byWidgetPredicate(
      (Widget w) =>
          w is Container &&
          w.padding == const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    );
    final Rect price = tester.getRect(find.text('1439.10'));
    final Rect badge = tester.getRect(badgeContainer);
    expect((badge.right - price.right).abs(), lessThan(2.0),
        reason: '涨跌胶囊没有贴右缘 = 不在股价正下方');
    expect(price.bottom, lessThanOrEqualTo(badge.top + 1.0),
        reason: '胶囊必须在价格下方');
  });
}
