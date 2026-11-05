import 'dart:ui' show ErrorCallback, PlatformDispatcher;

import 'package:flutter/foundation.dart';

import 'app_log.dart';

/// 错误上报出口。默认走 [AppLog]（logcat）；接入上报 SDK 时在 `main()` 里换掉。
typedef ErrorReport = void Function(String message, StackTrace? stack);

/// 装上**两个**全局错误钩子，并返回一个可以撤销的函数。
///
/// ## 为什么是两个，不是一个
///
/// | 钩子 | 覆盖范围 |
/// | --- | --- |
/// | `FlutterError.onError` | build / layout / paint 里的异常、`FlutterError.reportError` 主动上报的错误 |
/// | `PlatformDispatcher.instance.onError` | platform-channel 的异步失败、引擎回调里的未捕获异常、以及 Dart 侧逃出 `Future` 的错误 |
///
/// 只用 `runZonedGuarded` 是最常见的错误做法：**它收不到 platform-channel 的
/// 异步错误**（那些错误在 root zone 里由引擎派发，不经过你自己的 zone）。
/// Flutter 3.3+ 之后正确姿势就是这两个钩子。
///
/// ## 为什么要有它（不是洁癖）
///
/// 本仓库已经存在两条会穿透到引擎的路径：
/// 1. `unawaited(HapticFeedback.selectionClick())` —— 平台通道抛
///    `PlatformException` 时无人接收；
/// 2. `SymbolDirectory.ensureLoaded` 里 `_readCache()` 在 `try` 之外 ——
///    path_provider 失败时异常一路穿到 `unawaited(_prepareDirectory())`。
///
/// 没有钩子时，它们在 release 包里只留一行 logcat，等于线上永远查不到。
/// 装上之后至少能计数、能归因、能接到上报 SDK 上。
///
/// ## 与上一任处理器的关系
///
/// debug 模式下**保留**上一任（`FlutterError.presentError` 负责红屏与完整栈），
/// 只是额外多上报一份；release 下上一任是默认实现，同样保留——它不会打印
/// 任何东西，成本为零。
///
/// 返回的函数用于撤销（测试里必须恢复，否则会污染同一进程里的后续用例）。
VoidCallback installErrorHooks({ErrorReport? report}) {
  final ErrorReport sink = report ?? _logReport;

  final FlutterExceptionHandler? previousFlutter = FlutterError.onError;
  final ErrorCallback? previousPlatform = PlatformDispatcher.instance.onError;

  FlutterError.onError = (FlutterErrorDetails details) {
    // 先交给上一任：debug 下保住红屏与完整栈，别让"加了监控反而更难查"
    previousFlutter?.call(details);
    sink(
      'FlutterError: ${details.exceptionAsString()}',
      details.stack,
    );
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    sink('Uncaught async: $error', stack);
    // true = 已处理，不再让引擎把同一条错误再上报一次（否则线上会双计）
    return true;
  };

  return () {
    FlutterError.onError = previousFlutter;
    PlatformDispatcher.instance.onError = previousPlatform;
  };
}

void _logReport(String message, StackTrace? stack) {
  AppLog.e(stack == null ? message : '$message\n$stack');
}
