import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:jni/jni.dart';
import 'package:jni_flutter/jni_flutter.dart';

import 'app_log.dart';

/// 进程上次是怎么结束的。
///
/// 存在的理由：Android 17 起系统按设备总 RAM 给每个 App 设**进程级内存上限**，
/// 超限直接杀、不留崩溃堆栈（退出原因记在 `ApplicationExitInfo` 里，描述串含
/// `MemoryLimiter:AnonSwap`）。Flutter 侧对这类死亡**完全不可见**——用户看到的
/// 只是"莫名白屏/重启"，logcat 里连一行 E 都没有。
///
/// 这里把那条系统事实翻译成一行 W 级日志，让"上次被谁杀的"变成可归因。
enum ExitCause {
  /// 用户主动退出 / 自己结束（正常路径，不用管）
  clean,

  /// Android 17 的 per-app 内存上限（REASON_OTHER + MemoryLimiter）
  memoryLimiter,

  /// 系统 LMK 因整机内存紧张回收
  lowMemory,

  /// Java / native 崩溃、初始化失败
  crash,

  /// ANR 被杀
  anr,

  /// 其余（signaled / freezer / 资源超限 / 包状态变化等）
  other,
}

/// `android.app.ApplicationExitInfo` 的 reason 常量（API 30）。
///
/// 不引 `android.app.*` 的生成绑定：只用到 14 个整数，为一组常量引入几千行
/// jnigen 产物不划算。代价是常量名与系统版本的对应关系得自己维护——加在这里，
/// 有注释可查。
abstract final class ExitReason {
  static const int unknown = 0;
  static const int exitSelf = 1;
  static const int signaled = 2;
  static const int lowMemory = 3;
  static const int crash = 4;
  static const int crashNative = 5;
  static const int anr = 6;
  static const int initializationFailure = 7;
  static const int permissionChange = 8;
  static const int excessiveResourceUsage = 9;
  static const int userRequested = 10;
  static const int userStopped = 11;
  static const int dependencyDied = 12;
  static const int other = 13;
  static const int freezer = 14;
  static const int packageStateChange = 15;

  /// 换包（sideload 重装）——你自己最常造成的"上一条退出记录"，
  /// 属于预期内，不该被当成异常刷 W。
  static const int packageUpdated = 16;
}

/// 一次退出的归因结果。
@immutable
class LastExit {
  const LastExit({
    required this.cause,
    required this.reason,
    required this.at,
    this.description,
  });

  final ExitCause cause;

  /// 原始的 `getReason()` 值，留着是为了不被分类逻辑"吃掉"证据。
  final int reason;

  /// 系统给的补充说明（内存上限那条会带 `MemoryLimiter:AnonSwap`）。
  final String? description;

  final DateTime at;

  /// 距现在多久，人话版。
  String get ago => describeAgo(DateTime.now().difference(at));

  @override
  String toString() =>
      'LastExit(${cause.name}, reason=$reason, ago=$ago'
      '${description == null ? '' : ', desc=$description'})';
}

/// 把 `(reason, description)` 归成 [ExitCause]。**纯函数，host 可测**。
///
/// 判定顺序有讲究：`MemoryLimiter` 走的是 `REASON_OTHER` + 描述串匹配，
/// 所以必须先判描述再看 reason——否则永远落进 other。
ExitCause classifyExit({required int reason, String? description}) {
  if (reason == ExitReason.other &&
      (description?.toLowerCase().contains('memorylimiter') ?? false)) {
    return ExitCause.memoryLimiter;
  }
  switch (reason) {
    case ExitReason.exitSelf:
    case ExitReason.userRequested:
    case ExitReason.userStopped:
    // 换包 / 包状态变化也是正常退出路径。不归到 clean 的话，每次
    // `adb install -r` 之后的第一次启动都会刷一条 W，狼来了。
    case ExitReason.packageUpdated:
    case ExitReason.packageStateChange:
      return ExitCause.clean;
    case ExitReason.lowMemory:
      return ExitCause.lowMemory;
    case ExitReason.crash:
    case ExitReason.crashNative:
    case ExitReason.initializationFailure:
      return ExitCause.crash;
    case ExitReason.anr:
      return ExitCause.anr;
    default:
      return ExitCause.other;
  }
}

/// 把时长说成人话。纯函数，边界值可测。
String describeAgo(Duration d) {
  if (d.isNegative) {
    return '刚刚';
  }
  if (d.inMinutes < 1) {
    return '刚刚';
  }
  if (d.inMinutes < 60) {
    return '${d.inMinutes} 分钟前';
  }
  if (d.inHours < 24) {
    return '${d.inHours} 小时前';
  }
  return '${d.inDays} 天前';
}

/// 诊断开关：`--dart-define=JNI_DEBUG=true` 时把 JNI 每一步的中间结果打出来。
///
/// 为什么需要它：这段代码的失败方式是**静默返回 null**（设计如此，不能影响
/// 启动），于是"读不到"和"没记录"在 logcat 里长得一模一样。排障时必须能把
/// 每一步摊开看，又不能让正常包每启动一次就刷五行日志。
const bool _jniDebug = bool.fromEnvironment('JNI_DEBUG');

void _dbg(String message) {
  if (_jniDebug) {
    AppLog.w('[jni] $message');
  }
}

/// 调一次 Java 实例方法，并把 `JClass.forName` 的样板收在这里。
///
/// 为什么要包一层：`instanceMethodId` 定义在 `JClass` 上而不是 `JObject`，
/// 每处调用都写 `forName → methodId → call → release` 会把这个函数变成一片
/// 噪音，且漏一次 `release()` 就漏一个全局引用。这里保证类引用一定被释放。
///
/// 签名（`(Ljava/lang/String;II)Ljava/util/List;` 这种）**编译器不校验**，
/// 写错只在运行时抛 `NoSuchMethodError`——这是 JNI 直连最真实的代价。
DartT? _callOn<JavaT, DartT>(
  JObject receiver,
  String className,
  String method,
  String signature,
  JCallable<JavaT, DartT> returnType,
  List<Object?> args,
) {
  final JClass cls = JClass.forName(className);
  try {
    return cls
        .instanceMethodId(method, signature)
        .callNullable(receiver, returnType, args);
  } finally {
    cls.release();
  }
}

/// 读最近一次进程退出记录。非 Android / API < 30 / 任何失败都返回 null。
///
/// **为什么走 `package:jni` 而不是 MethodChannel**：这条链路只需要一次调用，
/// 但 MethodChannel 要写「Kotlin 侧 + Dart 侧 + 通道名」三处，还得为它维护一份
/// 原生代码；而 `libdartjni.so` 本来就已经在包里（path_provider 经 jni_flutter
/// 带进来的），Dart 直接调 Java 的边际成本几乎为零。
///
/// 代价必须说清：方法签名是**字符串**，写错了编译器不管，只在运行时抛
/// `NoSuchMethodError`。所以每个引用都在 finally 里释放，整体被 [readLastExit]
/// 兜住——读不到就当没有，绝不影响启动。
LastExit? _readLastExitSync() {
  // ApplicationExitInfo 是 API 30 才有的，minSdk 24 必须自己判版本。
  // 注意：这个判断必须在任何 forName('android/app/ApplicationExitInfo') 之前，
  // 否则 API 29 及以下会直接 ClassNotFound。
  final int sdkInt = JClass.forName(r'android/os/Build$VERSION')
      .use((JClass c) => c.staticFieldId('SDK_INT', 'I').get(c, jint.type));
  _dbg('sdkInt=$sdkInt');
  if (sdkInt < 30) {
    _dbg('API < 30，系统没有 ApplicationExitInfo');
    return null;
  }

  final JObject context = androidApplicationContext;
  final JString serviceName = 'activity'.toJString();
  try {
    final JObject? manager = _callOn(
      context,
      'android/content/Context',
      'getSystemService',
      '(Ljava/lang/String;)Ljava/lang/Object;',
      JObject.type,
      <Object?>[serviceName],
    );
    _dbg('manager=${manager != null}');
    if (manager == null) {
      return null;
    }
    try {
      // maxNum = 1：只要最近一次。多拿几条没有额外价值，还要多释放几次引用。
      final JObject? list = _callOn(
        manager,
        'android/app/ActivityManager',
        'getHistoricalProcessExitReasons',
        '(Ljava/lang/String;II)Ljava/util/List;',
        JObject.type,
        <Object?>[null, 0, 1],
      );
      _dbg('list=${list != null}');
      if (list == null) {
        return null;
      }
      try {
        final int size =
            _callOn(
              list,
              'java/util/List',
              'size',
              '()I',
              jint.type,
              const <Object?>[],
            ) ??
            0;
        _dbg('exitRecords=$size');
        if (size <= 0) {
          return null;
        }

        final JObject? info = _callOn(
          list,
          'java/util/List',
          'get',
          '(I)Ljava/lang/Object;',
          JObject.type,
          const <Object?>[0],
        );
        if (info == null) {
          return null;
        }
        try {
          final int reason =
              _callOn(
                info,
                'android/app/ApplicationExitInfo',
                'getReason',
                '()I',
                jint.type,
                const <Object?>[],
              ) ??
              ExitReason.unknown;
          final int timestamp =
              _callOn(
                info,
                'android/app/ApplicationExitInfo',
                'getTimestamp',
                '()J',
                jlong.type,
                const <Object?>[],
              ) ??
              0;
          final JString? desc = _callOn(
            info,
            'android/app/ApplicationExitInfo',
            'getDescription',
            '()Ljava/lang/String;',
            JString.type,
            const <Object?>[],
          );
          final String? text = desc?.toDartString(releaseOriginal: true);
          _dbg('reason=$reason ts=$timestamp desc=$text');

          return LastExit(
            cause: classifyExit(reason: reason, description: text),
            reason: reason,
            description: text,
            at: DateTime.fromMillisecondsSinceEpoch(timestamp),
          );
        } finally {
          info.release();
        }
      } finally {
        list.release();
      }
    } finally {
      manager.release();
    }
  } finally {
    serviceName.release();
    context.release();
  }
}

/// 安全版：任何异常都吞掉并记一行，返回 null。**绝不让诊断代码影响启动**。
LastExit? readLastExit() {
  if (!Platform.isAndroid) {
    return null;
  }
  try {
    return _readLastExitSync();
  } on Object catch (e) {
    AppLog.w('退出归因读取失败（忽略）: $e');
    return null;
  }
}

/// 首帧之后读一次并落日志。
///
/// 为什么放在首帧之后：这是个 binder 调用，放 `main()` 里会直接进冷启动关键路径
/// （基线 403ms，每一毫秒都要交代）。首帧之后做，最坏只是第二帧多几毫秒。
void installExitDiagnostics() {
  SchedulerBinding.instance.addPostFrameCallback((_) {
    final LastExit? last = readLastExit();
    // 正常退出不说话：这条日志只在"上次死得不体面"时出现，
    // 否则每天开十次就有十行噪音，真出事时反而没人看。
    if (last == null || last.cause == ExitCause.clean) {
      return;
    }
    // 用 W 而不是 I：AppLog.i 在 release 下是关的，而这条诊断恰恰是
    // release 才需要——"用户说 App 自己没了"的现场只在 release 存在。
    AppLog.w(
      '上次进程退出：${last.cause.name}'
      '（reason=${last.reason}，${last.ago}）'
      '${last.description == null ? '' : ' 说明=${last.description}'}',
    );
  });
}
