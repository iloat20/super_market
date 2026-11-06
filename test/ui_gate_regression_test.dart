import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/pages/quote_list_page.dart';
import 'package:super_market/services/quote_feed.dart';
import 'package:super_market/widgets/quote_tile.dart';

/// 审查台账 R-01 / R-05（UI 侧）的回归测试。
///
/// - R-05：`shouldApplyQuote` 只挡 `hasData == false`（NaN 被挡住），但
///   Infinity 价格 `hasData == true` 直接放行；而 `_onQuotes`（实时推送路径）
///   又绕过了这个闸门直赋 notifier。Infinity 一路走到 `formatPrice` →
///   `toStringAsFixed(2)` 对 Infinity 抛 `UnsupportedError` → build 崩。
/// - R-01：API Token 曾硬编码在 `app_config.dart`，本测试钉住
///   「源代码里没有内置凭证，必须通过 --dart-define 注入」。
const StockConfig kPingAn =
    StockConfig(code: '000001', name: '平安银行', region: 'SZ');

/// 把页面传入的 onQuotes 钩住的可控 feed：不建连、不轮询
class _HookFeed implements QuoteFeed {
  _HookFeed(this.onQuotes);

  final void Function(List<Quote>) onQuotes;

  @override
  final ValueNotifier<FeedStatus> status =
      ValueNotifier<FeedStatus>(FeedStatus.disconnected);

  @override
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  bool _disposed = false;

  @override
  List<StockConfig> get stocks => AppConfig.stocks;

  @override
  String get sourceLabel => 'Fake';

  @override
  void connect() {}

  @override
  void pause() {}

  @override
  void resume() {}

  @override
  void reconnectNow() {}

  @override
  void updateStocks(List<StockConfig> next) {}

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    status.dispose();
    lastError.dispose();
  }
}

void main() {
  group('行情闸门（R-05）', () {
    test('shouldApplyQuote 拒绝非有限价格', () {
      final Quote empty = Quote.empty('000001', region: 'SZ');
      final Quote infinity = Quote(
        code: '000001',
        region: 'SZ',
        price: double.infinity,
        change: 0,
        changePercent: 0,
      );
      final Quote nan = Quote(
        code: '000001',
        region: 'SZ',
        price: double.nan,
        change: double.nan,
        changePercent: 0,
      );
      final Quote normal = Quote(
        code: '000001',
        region: 'SZ',
        price: 11.54,
        change: 0.1,
        changePercent: 0.88,
      );

      expect(shouldApplyQuote(empty, infinity), isFalse,
          reason: 'Infinity 价格不得进入 UI（hasData 对 Infinity 是 true）');
      expect(shouldApplyQuote(empty, nan), isFalse);
      expect(shouldApplyQuote(empty, normal), isTrue, reason: '正常行情照常放行');
    });

    testWidgets('实时推送路径收到 Infinity 行情：界面保持 --，不崩 build',
        (WidgetTester tester) async {

      // 默认订阅已扩到 6 只：800×600 的默认测试视口放不下，末位控件不会被建出来，
      // 断言与点击都会落空。给足高度（逻辑像素 400×1600），让整个列表可见。
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      _HookFeed? feed;
      await tester.pumpWidget(
        MaterialApp(
          home: QuoteListPage(
            serviceBuilder: (ValueChanged<List<Quote>> onQuotes) {
              feed = _HookFeed(onQuotes);
              return feed!;
            },
          ),
        ),
      );
      await tester.pump();
      expect(find.text('--'), findsWidgets, reason: '首屏无数据');

      // 模拟服务层回调：敌意/异常数据源推来一条 Infinity 行情。
      // 红态：_onQuotes 直赋 notifier → QuoteTile build →
      // formatPrice(∞).toStringAsFixed(2) 抛 UnsupportedError → build 崩
      // 推的必须是订阅列表里的标的，否则 _onQuotes 找不到卡片、测不到闸门
      final StockConfig target = AppConfig.stocks.first;
      feed!.onQuotes(<Quote>[
        Quote(
          code: target.code,
          region: target.region,
          price: double.infinity,
          change: 0,
          changePercent: 0,
        ),
      ]);
      await tester.pump();

      expect(find.textContaining('Infinity'), findsNothing,
          reason: '非有限数值不得以任何文本形式出现在界面上');
      expect(find.byType(QuoteTile), findsNWidgets(AppConfig.stocks.length),
          reason: '一条脏行情不得拖垮整个列表');
      expect(find.text('--'), findsWidgets, reason: '被闸门拒绝后仍显示占位符');

      // 正常行情不受闸门影响
      feed!.onQuotes(<Quote>[
        Quote(
          code: target.code,
          region: target.region,
          price: 11.54,
          change: 0.12,
          changePercent: 1.05,
        ),
      ]);
      await tester.pump();
      expect(find.text('11.54'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

}
