import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:super_market/utils/haptics.dart';

/// 触觉失败不该变成 unhandled error。
///
/// 为什么要有这条：`HapticFeedback.*` 是平台通道调用，部分 OEM ROM 直接禁用
/// 振动（抛 `PlatformException`），桌面/测试环境没有实现（抛
/// `MissingPluginException`）。改造前 4 处调用都是裸 `unawaited(...)`，
/// 异常会浮到引擎；改造后统一走 [selectionClick] / [mediumImpact]。
void main() {
  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  testWidgets('平台拒绝触发触觉：不抛异常，静默降级', (WidgetTester tester) async {
    final List<String> attempted = <String>[];
    messenger().setMockMethodCallHandler(SystemChannels.platform, (
      MethodCall call,
    ) async {
      if (call.method == 'HapticFeedback.vibrate') {
        attempted.add('${call.arguments}');
        throw PlatformException(code: 'no_vibrator');
      }
      return null;
    });
    addTearDown(
      () => messenger().setMockMethodCallHandler(SystemChannels.platform, null),
    );

    // 红态（改造前）这里会抛 PlatformException
    await expectLater(selectionClick(), completes);
    await expectLater(mediumImpact(), completes);
    expect(attempted.length, 2, reason: '两次都该真的尝试过，而不是被提前短路');
  });

  testWidgets('正常情况下仍然真的发出调用（别把成功路径也吞了）', (
    WidgetTester tester,
  ) async {
    final List<Object?> sent = <Object?>[];
    messenger().setMockMethodCallHandler(SystemChannels.platform, (
      MethodCall call,
    ) async {
      if (call.method == 'HapticFeedback.vibrate') {
        sent.add(call.arguments);
      }
      return null;
    });
    addTearDown(
      () => messenger().setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await selectionClick();
    await mediumImpact();

    expect(sent, hasLength(2));
    expect(sent.first, contains('selectionClick'));
    expect(sent.last, contains('mediumImpact'));
  });
}
