import 'package:flutter/services.dart';

import 'app_log.dart';

/// 触觉反馈的**安全出口**。
///
/// ## 为什么需要这一层
///
/// `HapticFeedback.*` 是平台通道调用，失败方式有两种，而且都不罕见：
/// - `MissingPluginException`：桌面端、widget 测试里没有原生实现；
/// - `PlatformException`：部分 OEM ROM 干脆禁用振动，或用户关掉了触感反馈。
///
/// 仓库里 4 处调用原本全是 `unawaited(HapticFeedback.xxx(...))`，异常会变成
/// unhandled async error。装了全局钩子之后它至少会被记下来，但**"点一下没震动"
/// 不该产生一条错误日志**：触觉是装饰，失败就该静默降级。
///
/// 返回的 Future 故意允许 `unawaited`：调用方在事件回调里，不该为了一个
/// 装饰性反馈去等一个跨平台往返。
Future<void> selectionClick() => _guard(HapticFeedback.selectionClick);

/// 中等强度反馈（删除、拖拽落位一类"有后果"的操作）。
Future<void> mediumImpact() => _guard(HapticFeedback.mediumImpact);

Future<void> _guard(Future<void> Function() call) async {
  try {
    await call();
  } on MissingPluginException {
    // 没有原生实现：桌面、widget 测试。什么都不做是对的。
  } on PlatformException catch (e) {
    // debug 构建留一行，release 里 AppLog.d 本身就是空操作
    AppLog.d('触觉反馈被拒绝：${e.code}');
  }
}
