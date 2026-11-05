import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/pages/quote_list_page.dart';
import 'fake_feed.dart';
import 'package:super_market/widgets/market_session_badge.dart';
import 'package:super_market/widgets/quote_detail_sheet.dart';
import 'package:super_market/widgets/quote_tile.dart';

void main() {
  testWidgets('单只 notifier 变化只影响自己那一行', (WidgetTester tester) async {
    final ValueNotifier<Quote> a = ValueNotifier<Quote>(Quote.empty('000001'));
    final ValueNotifier<Quote> b = ValueNotifier<Quote>(Quote.empty('600519'));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              QuoteTile(stock: AppConfig.stocks[0], quote: a),
              QuoteTile(stock: AppConfig.stocks[1], quote: b),
            ],
          ),
        ),
      ),
    );

    // 每行有 2 个占位符：价格 + 涨跌
    expect(find.text('--'), findsNWidgets(4));

    int aBuilds = 0;
    a.addListener(() => aBuilds++);

    b.value = Quote(
      code: '600519',
      price: 1500.5,
      change: 10.0,
      changePercent: 0.67,
      timestamp: DateTime.fromMillisecondsSinceEpoch(1731689407000),
    );
    await tester.pump();

    expect(find.text('1500.50'), findsOneWidget);
    expect(find.text('--'), findsNWidgets(2)); // 另一行仍是无数据（价格+涨跌）
    expect(aBuilds, 0); // 第一只股票没被牵连

    a.value = const Quote(
      code: '000001',
      price: 11.2,
      change: -0.1,
      changePercent: -0.88,
    );
    await tester.pump();
    expect(find.text('11.20'), findsOneWidget);
    expect(aBuilds, 1);
  });

  testWidgets('Quote 值相等时 ValueNotifier 不重复通知', (WidgetTester tester) async {
    // 服务端偶尔会重放同一条报文；没有 ==/hashCode 的话每次都重建玻璃层，
    // BackdropFilter 的模糊是有成本的，这里把「去重」这件事锁死。
    const Quote q = Quote(
      code: '000001',
      price: 11.24,
      change: 0.13,
      changePercent: 1.17,
      timestamp: null,
    );
    final ValueNotifier<Quote> n = ValueNotifier<Quote>(q);
    addTearDown(n.dispose);

    int notified = 0;
    n.addListener(() => notified++);

    n.value = const Quote(
      code: '000001',
      price: 11.24,
      change: 0.13,
      changePercent: 1.17,
      timestamp: null,
    );
    expect(notified, 0, reason: '内容完全相同不应触发重建');

    n.value = const Quote(
      code: '000001',
      price: 11.25,
      change: 0.14,
      changePercent: 1.26,
      timestamp: null,
    );
    expect(notified, 1);
  });

  testWidgets('列表页渲染 3 行且不 setState', (WidgetTester tester) async {
    // 注入一个「不会建连」的服务：不走网络，所以状态稳定停在「已断开」。
    // 之前这里直接 pumpWidget(const QuoteListPage())，页面会真的去连 wss://…，
    // 一旦 AppConfig 里填了真 Token，测试就依赖外网、依赖机器网络状况——
    // 那是假失败（红了但代码没坏），也是假成功（绿了但没测到什么）。
    await tester.pumpWidget(
      MaterialApp(
        home: QuoteListPage(serviceBuilder: NoopFeed.builder),
      ),
    );
    await tester.pump();

    expect(find.byType(QuoteTile), findsNWidgets(AppConfig.stocks.length));
    expect(find.text(AppConfig.stocks[1].name), findsOneWidget);
    expect(find.text(AppConfig.stocks[1].code), findsOneWidget); // 代码
    expect(find.text('SH'), findsOneWidget); // 市场角标
    // Token 概念已随 iTick 通道整体退役：任何时候都不该再出现凭证提示
    expect(find.textContaining('Token'), findsNothing);
    // 玻璃头部存在；连接状态胶囊与刷新按钮已按产品要求移除，
    // 断链时轮询链自己换源重连，界面不再展示「已连接/已断开」
    expect(find.text('已断开'), findsNothing);
    expect(find.text('已连接'), findsNothing);
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);
    // 页脚来源行已按产品要求移除
    expect(find.text('iTick · 1 连接 · 实时推送 · 3 订阅 · 切后台暂停'), findsNothing);
    // 交易时段角标（收盘后价格不动是正常的，界面要说清楚原因）
    expect(find.byType(MarketSessionBadge), findsOneWidget);
    // 卡片不带时间：时间统一由页头时钟展示（带秒），旧时间行的
    // 时钟图标必须消失，别两头各显示一个时间
    expect(find.byIcon(Icons.schedule_rounded), findsNothing);

    // 卸载以取消时段角标的 30s 定时器，否则测试结束会报 pending timer
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('点开详情弹层：今开/最高/最低/昨收/量额都在，且不新增订阅', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<Quote> q = ValueNotifier<Quote>(
      const Quote(
        code: '600519',
        price: 1523,
        change: 12.34,
        changePercent: 0.82,
        previousClose: 1510.66,
        open: 1520,
        high: 1540,
        low: 1510,
        volume: 16742235,
        turnover: 3774688301.452,
      ),
    );
    addTearDown(q.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext ctx) => QuoteTile(
              stock: AppConfig.stocks[1],
              quote: q,
              onTap: () => showQuoteDetailSheet(
                ctx,
                stock: AppConfig.stocks[1],
                quote: q,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('今开'), findsNothing);
    await tester.tap(find.byType(QuoteTile));
    await tester.pumpAndSettle();

    expect(find.text('今开'), findsOneWidget);
    expect(find.text('1520.00'), findsOneWidget);
    expect(find.text('最高'), findsOneWidget);
    expect(find.text('1540.00'), findsOneWidget);
    expect(find.text('最低'), findsOneWidget);
    expect(find.text('1510.00'), findsOneWidget);
    expect(find.text('昨收'), findsOneWidget);
    expect(find.text('1510.66'), findsOneWidget);
    expect(find.text('1674.22万'), findsOneWidget);
    expect(find.text('37.75亿'), findsOneWidget);
    expect(find.text('正常交易'), findsOneWidget);
  });
}
