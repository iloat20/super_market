import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/pages/quote_list_page.dart';
import 'fake_feed.dart';

/// 退到后台后，页头的周期刷新必须真的停止。
///
/// 为什么值得一条测试：`paused` 状态下 Flutter 只是不再产生帧
/// （`_framesEnabled = false`），**Dart 侧的 Timer 照跑**——每秒仍会
/// 创建 DateTime / 字符串、请求一帧再被丢弃。这是「停止了渲染」和
/// 「释放了引用」的区别，光看屏幕看不出来，只能测行为。
/// 探针：记录 `now()` 被调了几次。
///
/// 为什么不能只看界面文字：paused 之后 Flutter 只是**不再产生帧**，
/// 定时器照跑、setState 照执行，只是没人画——界面文字「看起来没变」
/// 并不能证明 Timer 停了。真正要断言的是「后台不再调 now() 干活」。
Widget _host(DateTime Function() clock) => MaterialApp(
      home: QuoteListPage(
        clock: clock,
        // 不联网的空转 feed：测试只关心页面时钟与生命周期
        serviceBuilder: NoopFeed.builder,
      ),
    );

void main() {
  testWidgets('退后台时钟停表，回前台立刻补上当前时间', (WidgetTester tester) async {
    DateTime now = DateTime(2026, 11, 4, 10, 0, 0);
    int clockCalls = 0;
    DateTime spy() {
      clockCalls++;
      return now;
    }
    addTearDown(() {
      // 别把 paused 留给后面的用例
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    await tester.pumpWidget(_host(spy));
    await tester.pump();
    expect(find.text('10:00:00'), findsOneWidget, reason: '首帧就要显示时间');

    // 前台：时钟应该在走
    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('10:00:01'), findsOneWidget, reason: '前台每秒都要跳');

    // 退后台：Timer 必须停
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    final int callsAtPause = clockCalls;
    now = now.add(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 2));
    expect(
      clockCalls,
      callsAtPause,
      reason: '后台每秒钟还在调 now()/setState = 白烧 CPU，且不等于释放',
    );

    // 回前台：立刻显示正确时间，而不是等下一秒
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(clockCalls, greaterThan(callsAtPause), reason: '回前台要立即恢复计时');
    expect(find.text('10:00:06'), findsOneWidget, reason: '回前台要立即补当前时间');
  });
}
