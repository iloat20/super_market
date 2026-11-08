import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/utils/adpf.dart';

/// 审查台账（2026-11-08）批次 E：Android 原生通道 / ADPF 会话。
/// Kotlin 半边没有单测框架，用源码守门钉住契约；Dart 半边跑真实通道 mock。
const String kAdpfSession =
    'android/app/src/main/kotlin/app/supermarket/AdpfSession.kt';
const String kMainActivity =
    'android/app/src/main/kotlin/app/supermarket/MainActivity.kt';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('批次 E｜原生通道契约（源码守门）', () {
    test('#18a 上报失败必须回传 error，不能仍回 success(null)', () {
      final String session = File(kAdpfSession).readAsStringSync();
      final String activity = File(kMainActivity).readAsStringSync();
      expect(
        session.contains('fun report(workNanos: Long, targetNanos: Long): String?'),
        isTrue,
        reason: 'Kotlin 把 runCatching 的失败吞成日志并关闭会话，Dart 的'
            'catchError / 失败计数 / 自愈在真机上永不触发',
      );
      expect(session.contains('report-failed'), isTrue);
      expect(activity.contains('result.error('), isTrue);
    });

    test('#18b handler 要有异常兜底，fps 不能强转 Int', () {
      final String activity = File(kMainActivity).readAsStringSync();
      expect(activity.contains('catch (e: Exception)'), isTrue,
          reason: '异常逃逸后 result 永不被调用，Dart 侧 invokeMethod 挂起');
      expect(activity.contains('argument<Number>("fps")'), isTrue,
          reason: 'StandardMessageCodec 把大整数编成 Long，argument<Int> 会抛 ClassCastException');
    });

    test('#18d Dart 侧 start/stop 要用代际令牌', () {
      final String src = File('lib/utils/adpf.dart').readAsStringSync();
      expect(src.contains('_generation'), isTrue,
          reason: 'stop 落在 Binder await 窗口时 _active 仍是 false，'
              'start 返回后会在后台注册帧回调');
    });
  });

  group('批次 E｜ADPF 生命周期竞态', () {
    test('#18c paused 落在 start 的 await 窗口时不得留下后台会话', () async {
      const MethodChannel channel = MethodChannel('test/adpf-race');
      final List<String> methods = <String>[];
      final Completer<bool> gate = Completer<bool>();
      final TestDefaultBinaryMessengerBinding binding =
          TestDefaultBinaryMessengerBinding.instance;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (MethodCall call) async {
          methods.add(call.method);
          if (call.method == 'adpf.start') {
            return await gate.future;
          }
          return null;
        },
      );

      final AdpfMonitor monitor = AdpfMonitor(
        channel: channel,
        refreshRate: () => 60,
      );
      addTearDown(() {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        monitor.dispose();
      });

      final Future<void> starting = monitor.start();
      monitor.didChangeAppLifecycleState(AppLifecycleState.paused);
      gate.complete(true);
      await starting;

      expect(methods, contains('adpf.stop'),
          reason: '窗口期 pause 时 stop 因 !_active 直接返回，既不关会话也不作废 start');
    });
  });
}
