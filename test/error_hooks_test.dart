import 'dart:ui' show ErrorCallback, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:super_market/utils/error_hooks.dart';

/// 全局错误钩子：`FlutterError.onError` + `PlatformDispatcher.instance.onError`。
///
/// 为什么两个都要：前者只覆盖 build / layout / paint 与 `FlutterError.reportError`
/// 主动上报的路径；platform-channel 的异步失败、引擎侧回调里的异常走的是
/// 后者。只用 `runZonedGuarded` 的话，这两类都收不到。
///
/// 为什么必须有：仓库里已经存在两条会穿透到引擎的路径（`unawaited` 的
/// `HapticFeedback`、`SymbolDirectory.ensureLoaded` 里 `_readCache` 在 try 之外）。
/// 没有钩子时它们在 release 包里只留一行 logcat，等于线上永远查不到。
void main() {
  test('装上两个钩子，两路错误都进 sink，撤销后回到装上之前的值', () {
    final FlutterExceptionHandler? previousFlutter = FlutterError.onError;
    final ErrorCallback? previousPlatform = PlatformDispatcher.instance.onError;

    // 装上之前先把框架的处理器摘掉：测试环境里那会把整段红屏刷进输出，
    // 掩盖真正的失败。撤销后应当**回到这个值**（null），而不是回到最初那个。
    FlutterError.onError = null;

    final List<String> seen = <String>[];
    final VoidCallback restore = installErrorHooks(
      report: (String message, StackTrace? stack) => seen.add(message),
    );
    addTearDown(() {
      restore();
      expect(FlutterError.onError, isNull, reason: '撤销应恢复"装上那一刻"的值');
      expect(
        identical(PlatformDispatcher.instance.onError, previousPlatform),
        isTrue,
        reason: '撤销必须把 platform 钩子还给上一任',
      );
      FlutterError.onError = previousFlutter; // 还原测试环境
    });

    expect(FlutterError.onError, isNotNull);
    expect(
      PlatformDispatcher.instance.onError,
      isNotNull,
      reason: '只有 FlutterError.onError 是不够的：platform-channel 与引擎侧'
          '的异步错误只走 PlatformDispatcher',
    );

    FlutterError.onError!(
      FlutterErrorDetails(exception: StateError('boom-framework')),
    );
    expect(
      seen.where((String m) => m.contains('boom-framework')),
      isNotEmpty,
      reason: '框架错误必须能被上报（而不只是打一行 console）',
    );

    final bool handled = PlatformDispatcher.instance.onError!(
      StateError('boom-async'),
      StackTrace.current,
    );
    expect(handled, isTrue, reason: '返回 true 表示已处理，不再让引擎重复上报');
    expect(
      seen.where((String m) => m.contains('boom-async')),
      isNotEmpty,
      reason: '异步错误必须能被上报',
    );
  });
}
