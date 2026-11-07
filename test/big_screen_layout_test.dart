import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:super_market/pages/quote_list_page.dart';
import 'package:super_market/widgets/quote_tile.dart';
import 'fake_feed.dart';

/// 大屏 / 可调整窗口下的布局底线（Android 17 / targetSdk 37）。
///
/// 为什么需要这一组：从 targetSdk 37 起，sw ≥ 600dp 的窗口会**忽略**
/// `screenOrientation` / `resizeableActivity` / 宽高比限制（2026-11 实测，
/// 见 `docs/ANDROID17-ALIGNMENT-2026-11-07.md`）。系统不再允许「只做竖屏」，
/// 于是横屏、分屏、桌面模式、气泡都会走进以前没验证过的分支。
///
/// 这组用例守的是**不崩、不溢出、限宽仍然生效**这三条底线，不守观感——
/// 玻璃光学与视觉基线仍要真机走查（`flutter_tester` 无 Impeller）。
///
/// 尺寸取的是 OPPO PLJ110 的物理分辨率 1256×2760 @3x 换算出的逻辑值：
///   竖屏 419×920 / 横屏 920×419 / 分屏上半 419×433，
/// 另加平板横屏 1280×800 与 App Bubbles 的极小窗 240×320。
void main() {
  /// 页面容器限宽（`quote_list_page.dart` 的 `BoxConstraints(maxWidth: 560)`）。
  /// 大屏下卡片不该跟着窗口一起拉长——这是当前唯一的大屏策略。
  const double kListMaxWidth = 560;

  Future<void> pumpAt(WidgetTester tester, Size logical) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = Size(logical.width * 3, logical.height * 3);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: QuoteListPage(serviceBuilder: NoopFeed.builder)),
      ),
    );
    await tester.pump();
  }

  /// 卸载以取消时段角标的 30s 定时器，否则测试结束会报 pending timer。
  Future<void> tearDownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
  }

  testWidgets('竖屏基准 419×920：不溢出且卡片不超过 560', (WidgetTester tester) async {
    await pumpAt(tester, const Size(419, 920));

    expect(tester.takeException(), isNull);
    expect(find.byType(QuoteTile), findsAtLeastNWidgets(1));
    expect(
      tester.getSize(find.byType(QuoteTile).first).width,
      lessThanOrEqualTo(kListMaxWidth),
      reason: '窄屏下卡片跟随窗口宽度，不该被限宽撑开',
    );

    await tearDownTree(tester);
  });

  testWidgets('横屏 920×419：不溢出，卡片被拦在 560', (WidgetTester tester) async {
    await pumpAt(tester, const Size(920, 419));

    expect(tester.takeException(), isNull);

    final double w = tester.getSize(find.byType(QuoteTile).first).width;
    expect(w, lessThanOrEqualTo(kListMaxWidth),
        reason: '920dp 宽屏下卡片必须被 maxWidth 560 拦住，否则一行拉成一条');
    expect(w, greaterThan(419 * 0.9),
        reason: '限宽 560 在 920dp 下应该吃满，不该缩成更窄的一条');

    await tearDownTree(tester);
  });

  testWidgets('平板横屏 1280×800：不溢出且仍然单列限宽', (WidgetTester tester) async {
    await pumpAt(tester, const Size(1280, 800));

    expect(tester.takeException(), isNull);
    expect(find.byType(QuoteTile), findsAtLeastNWidgets(1));
    expect(tester.getSize(find.byType(QuoteTile).first).width,
        lessThanOrEqualTo(kListMaxWidth));

    await tearDownTree(tester);
  });

  testWidgets('分屏上半 419×433：矮窗口不溢出', (WidgetTester tester) async {
    await pumpAt(tester, const Size(419, 433));

    expect(tester.takeException(), isNull);
    expect(find.byType(QuoteTile), findsAtLeastNWidgets(1));

    await tearDownTree(tester);
  });

  testWidgets('气泡极小窗 240×320：不溢出也不空', (WidgetTester tester) async {
    await pumpAt(tester, const Size(240, 320));

    expect(tester.takeException(), isNull);
    expect(find.byType(QuoteTile), findsAtLeastNWidgets(1),
        reason: 'Android 17 的 App Bubbles 可能把窗口压到 240dp，至少得看见一张卡');

    await tearDownTree(tester);
  });

  testWidgets('横屏下打开详情弹层：不溢出，内容宽度不超过 520',
      (WidgetTester tester) async {
    await pumpAt(tester, const Size(920, 419));

    await tester.tap(find.byType(QuoteTile).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(tester.takeException(), isNull);
    // 八项指标里的第一项，能出现说明弹层内容真的构建了（不是空壳）
    expect(find.text('今开'), findsOneWidget);

    // 弹层容器是全宽的 BottomSheet，内容由 ConstrainedBox 限到 520。
    // 这里用「今开」与「成交额」两列标签的横向跨度反推内容宽度。
    final double left = tester.getTopLeft(find.text('今开')).dx;
    final double right = tester.getTopLeft(find.text('成交额')).dx;
    expect(right - left, lessThan(520),
        reason: '920dp 横屏下详情内容应限宽 520 并居中，不该铺满整行');

    await tearDownTree(tester);
  });
}
