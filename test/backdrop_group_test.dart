import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/pages/quote_list_page.dart';
import 'package:super_market/services/local_store.dart';
import 'fake_feed.dart';
import 'package:super_market/services/watchlist_repository.dart';
import 'package:super_market/widgets/glass.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 滚动掉帧的结构性防线。
///
/// 真机实测（PLJ110 / 90Hz / profile）：滑动的每一帧 raster 11.7ms、
/// 40/40 帧超时，而 build 只有 1.0ms。原因不在重建，在 GPU 取样：
/// Impeller 下**每块** `BackdropFilter` 都会切断 render pass 并拷贝整屏，
/// 与玻璃多小无关；premium 档一块玻璃两次（iOS 27 frost 三次）。
/// 四张卡片 + 页头 = 每帧 15 次全屏拷贝，11.11ms 的预算必然撑不住。
///
/// 修法是 `GlassBackdropGroup`：组内玻璃共享一次背景读取。这个不变量
/// 一旦被删掉，jank 会静默回来（不留任何断言失败），所以在这里钉住。
void main() {
  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: QuoteListPage(
          serviceBuilder: NoopFeed.builder,
          watchlistRepository: WatchlistRepository(MemoryKeyValueStore()),
          clock: () => DateTime(2026, 11, 4, 10, 0),
        ),
      ),
    );
    // 不用 pumpAndSettle：页头秒表每秒跳一格，settle 不会收敛
    await tester.pump();
  }

  testWidgets('列表内所有卡片玻璃共享同一次背景读取', (WidgetTester tester) async {
    await pumpPage(tester);

    final Finder cards = find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(GlassContainer),
    );
    expect(cards, findsWidgets, reason: '列表里应该有成卡片的玻璃');

    // ① 卡片必须在同一个组里
    expect(
      find.ancestor(of: cards.first, matching: find.byType(GlassBackdropGroup)),
      findsOneWidget,
      reason: '没有组 = 每块玻璃各自拷一次整屏',
    );

    // ② 解析出的 backdrop key 必须是同一个对象
    final List<Object?> keys = <Object?>[
      for (final Element element in cards.evaluate())
        GlassBackdropGroup.keyOf(element),
    ];
    expect(
      keys.length,
      greaterThanOrEqualTo(2),
      reason: '组至少要有两块玻璃才划算（单块反而更贵）',
    );
    expect(keys.first, isNotNull, reason: '不在组里的玻璃会自己再拷一次整屏');
    for (final Object? key in keys.skip(1)) {
      expect(
        identical(key, keys.first),
        isTrue,
        reason: '同一组的玻璃必须解析到同一个 backdrop key',
      );
    }
  });

  testWidgets('页头不再额外挂一块玻璃', (WidgetTester tester) async {
    await pumpPage(tester);

    // 页头曾经挂一块「全透明」玻璃（kGlassHeaderSurface）：白纱/霜/高光全清零，
    // 但菲涅尔亮边、rimShade 暗线、色散还在——在浅雾背景上就是一圈看得见的
    // 28 圆角矩形，上滑时卡片一动就更扎眼（用户：「页头的分界线很明显」）。
    // 而且它换不来任何东西：列表 viewport 停在页头下方，卡片根本进不了它背后。
    final Finder cards = find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(GlassContainer),
    );
    expect(cards, findsWidgets);
    expect(
      find.byType(GlassContainer).evaluate().length,
      cards.evaluate().length,
      reason: '页面上除卡片外不该还有玻璃：多出来的那块就是页头轮廓线',
    );

    // 页头与列表之间的过渡改由「与背景同色的渐隐层」承担
    expect(
      find.byType(HeaderFade),
      findsOneWidget,
      reason: '缺了它，卡片会在页头下沿被裁出一刀',
    );
  });
}
