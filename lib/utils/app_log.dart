import 'package:flutter/foundation.dart';

/// 极简日志：统一前缀 + 时间戳，debug 级别只在 debug 构建输出。
abstract final class AppLog {
  /// 日志前缀。`main` 里按当前数据源覆盖，
  /// 不会出现「日志写着 A、其实连的是别家」这种最误导人的情况。
  static String tag = 'quote';

  static void i(String message) {
    // 诊断信息只在 debug/profile 输出：`debugPrint` 在 release 下**照样打印**
    // （它不是 assert），而 `i()` 里带着数据源地址、股票代码这类东西。
    // logcat 不是给用户看的运维通道，release 里留 W/E 就够了。
    if (!kReleaseMode) {
      _write('I', message);
    }
  }

  static void w(String message) => _write('W', message);

  static void e(String message) => _write('E', message);

  /// 高频日志（收到推送等），debug 构建下才输出
  static void d(String message) {
    if (kDebugMode) {
      _write('D', message);
    }
  }

  static void _write(String level, String message) {
    final String now = DateTime.now().toIso8601String();
    // 只取 HH:mm:ss.SSS
    final String time = now.length >= 23 ? now.substring(11, 23) : now;
    debugPrint('$time [$level] $tag | $message');
  }
}
