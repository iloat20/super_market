import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/utils/exit_diagnostics.dart';

/// 退出归因的**纯逻辑**守门。
///
/// 只测两件事：reason → 分类的映射、时长的人话化。JNI 那半段（真的去读
/// ApplicationExitInfo）在 host 上跑不了——它需要 Android 运行时，验证方式
/// 是真机启动后看 logcat（installExitDiagnostics 会把结论打成一行 W）。
///
/// 这个分工是刻意的：**能纯函数化的就别留在 JNI 里**，否则整条链路都变成
/// "只能上真机试"。分类规则恰恰是最容易写错、也最值得回归的部分。
void main() {
  group('classifyExit', () {
    test('REASON_OTHER + MemoryLimiter 描述 → memoryLimiter', () {
      expect(
        classifyExit(
          reason: ExitReason.other,
          description: 'MemoryLimiter:AnonSwap anon=812MB swap=340MB',
        ),
        ExitCause.memoryLimiter,
      );
    });

    test('大小写不敏感（系统文案不受我们控制）', () {
      expect(
        classifyExit(reason: ExitReason.other, description: 'memorylimiter:x'),
        ExitCause.memoryLimiter,
      );
    });

    test('reason 不是 OTHER 时，描述里出现 MemoryLimiter 也不改判', () {
      // 防御：描述串来自系统，将来前缀可能出现在别的 reason 上；
      // 只有 OTHER 才是 Android 17 那条链路的形状。
      expect(
        classifyExit(
          reason: ExitReason.lowMemory,
          description: 'MemoryLimiter:AnonSwap',
        ),
        ExitCause.lowMemory,
      );
    });

    test('用户主动退出 / 自己结束 / 换包 → clean（不刷 W 噪音）', () {
      for (final int reason in <int>[
        ExitReason.exitSelf,
        ExitReason.userRequested,
        ExitReason.userStopped,
        // sideload 重装后第一条记录就是它；不归 clean 的话每次装机都刷一条 W
        ExitReason.packageUpdated,
        ExitReason.packageStateChange,
      ]) {
        expect(
          classifyExit(reason: reason),
          ExitCause.clean,
          reason: '$reason',
        );
      }
    });

    test('LMK / 崩溃 / ANR 各自分开', () {
      expect(classifyExit(reason: ExitReason.lowMemory), ExitCause.lowMemory);
      expect(classifyExit(reason: ExitReason.crash), ExitCause.crash);
      expect(classifyExit(reason: ExitReason.crashNative), ExitCause.crash);
      expect(
        classifyExit(reason: ExitReason.initializationFailure),
        ExitCause.crash,
      );
      expect(classifyExit(reason: ExitReason.anr), ExitCause.anr);
    });

    test('其余（freezer / signaled / 未知）落 other，不瞎猜', () {
      for (final int reason in <int>[
        ExitReason.unknown,
        ExitReason.signaled,
        ExitReason.freezer,
        ExitReason.permissionChange,
        ExitReason.excessiveResourceUsage,
        ExitReason.dependencyDied,
        999,
      ]) {
        expect(
          classifyExit(reason: reason),
          ExitCause.other,
          reason: '$reason',
        );
      }
    });
  });

  group('describeAgo', () {
    test('不到 1 分钟说「刚刚」', () {
      expect(describeAgo(Duration.zero), '刚刚');
      expect(describeAgo(const Duration(seconds: 59)), '刚刚');
    });

    test('分钟 / 小时 / 天 三档', () {
      expect(describeAgo(const Duration(minutes: 1)), '1 分钟前');
      expect(describeAgo(const Duration(minutes: 59)), '59 分钟前');
      expect(describeAgo(const Duration(hours: 1)), '1 小时前');
      expect(describeAgo(const Duration(hours: 23)), '23 小时前');
      expect(describeAgo(const Duration(days: 1)), '1 天前');
      expect(describeAgo(const Duration(days: 9)), '9 天前');
    });

    test('时钟回拨（负数）不输出「-3 分钟前」', () {
      expect(describeAgo(const Duration(minutes: -5)), '刚刚');
    });
  });
}
