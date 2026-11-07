import 'dart:ui' show AppLifecycleState;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/utils/adpf.dart';

/// ADPF 的 Dart 半边：攒批、报值、失败自愈。
///
/// Kotlin 那半边（建会话、扫线程、Binder 调用）没法在 `flutter test` 里跑，
/// 只能靠真机 logcat 验；这里把**所有会算错的地方**（目标时长、平均值、
/// 批次边界、失败次数、生命周期）钉住。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('test/adpf');

  late List<MethodCall> calls;
  late List<bool> startResults;
  late List<Object> reportFailures;

  setUp(() {
    calls = <MethodCall>[];
    startResults = <bool>[true];
    reportFailures = <Object>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          switch (call.method) {
            case 'adpf.start':
              return startResults.isEmpty ? true : startResults.removeAt(0);
            case 'adpf.report':
              if (reportFailures.isNotEmpty) {
                throw reportFailures.removeAt(0);
              }
              return null;
            case 'adpf.stop':
              return null;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  AdpfMonitor build({double hz = 60}) {
    final AdpfMonitor monitor = AdpfMonitor(
      channel: channel,
      refreshRate: () => hz,
    );
    addTearDown(monitor.dispose);
    return monitor;
  }

  List<MethodCall> reports() =>
      calls.where((MethodCall c) => c.method == 'adpf.report').toList();

  test('目标时长按刷新率算，并取帧预算的 75%', () async {
    final AdpfMonitor m120 = build(hz: 120);
    await m120.start();
    expect(
      (calls.firstWhere((MethodCall c) => c.method == 'adpf.start').arguments
          as Map<Object?, Object?>)['targetNanos'],
      6250000, // 1e9 / 120 * 0.75
    );

    final AdpfMonitor m60 = build(hz: 60);
    await m60.start();
    expect(
      (calls.last.arguments as Map<Object?, Object?>)['targetNanos'],
      12500000, // 1e9 / 60 * 0.75
    );
  });

  test('刷新率取不到时按 60Hz 兜底', () async {
    final AdpfMonitor m = build(hz: 0);
    await m.start();
    expect(
      (calls.last.arguments as Map<Object?, Object?>)['targetNanos'],
      12500000,
    );
  });

  test('攒够 8 帧报一次平均值（不是总和，也不是最后一帧）', () async {
    final AdpfMonitor m = build();
    await m.start();
    for (int i = 1; i <= 8; i++) {
      m.ingest(
        buildNanos: 2000000,
        rasterNanos: 6000000,
        nowMicros: i * 1000,
      );
    }
    await pumpEventQueue();

    final List<MethodCall> got = reports();
    expect(got, hasLength(1));
    final Map<Object?, Object?> args = got.single.arguments as Map<Object?, Object?>;
    expect(args['workNanos'], 8000000);
    expect(args['frames'], 8);
  });

  test('帧率很低时按时间兜底：2 帧跨过 200ms 也要报', () async {
    final AdpfMonitor m = build();
    await m.start();
    m.ingest(buildNanos: 1000000, rasterNanos: 1000000, nowMicros: 1000);
    m.ingest(buildNanos: 1000000, rasterNanos: 1000000, nowMicros: 250000);
    await pumpEventQueue();

    final List<MethodCall> got = reports();
    expect(got, hasLength(1));
    expect((got.single.arguments as Map<Object?, Object?>)['frames'], 2);
    expect((got.single.arguments as Map<Object?, Object?>)['workNanos'], 2000000);
  });

  test('平台说建不起来（API<31 / 扫不到线程）就彻底不干活', () async {
    startResults = <bool>[false];
    final AdpfMonitor m = build();
    await m.start();

    expect(m.isActive, isFalse);
    for (int i = 1; i <= 16; i++) {
      m.ingest(buildNanos: 1000000, rasterNanos: 1000000, nowMicros: i * 1000);
    }
    await pumpEventQueue();
    expect(reports(), isEmpty);
  });

  test('通道不存在（预览/非 Android）不抛异常', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    final AdpfMonitor m = build();
    await m.start(); // MissingPluginException 被吞掉
    expect(m.isActive, isFalse);
  });

  test('连续 3 次上报失败就自动关会话，不无限刷日志', () async {
    reportFailures = <Object>[
      PlatformException(code: 'epipe'),
      PlatformException(code: 'epipe'),
      PlatformException(code: 'epipe'),
      PlatformException(code: 'epipe'),
    ];
    final AdpfMonitor m = build();
    await m.start();

    for (int round = 0; round < 4; round++) {
      for (int i = 1; i <= 8; i++) {
        m.ingest(
          buildNanos: 1000000,
          rasterNanos: 1000000,
          nowMicros: (round * 8 + i) * 1000,
        );
      }
      await pumpEventQueue();
    }

    expect(m.isActive, isFalse);
    expect(
      calls.where((MethodCall c) => c.method == 'adpf.stop'),
      hasLength(1),
      reason: '第 3 次失败后关一次就够，第 4 次不该再发',
    );
    expect(reports(), hasLength(3), reason: '关掉之后批次不该继续上报');
  });

  test('stop 之后不再上报，可以再 start', () async {
    final AdpfMonitor m = build();
    await m.start();
    await m.stop();
    expect(m.isActive, isFalse);

    for (int i = 1; i <= 8; i++) {
      m.ingest(buildNanos: 1000000, rasterNanos: 1000000, nowMicros: i * 1000);
    }
    await pumpEventQueue();
    expect(reports(), isEmpty);

    await m.start();
    expect(m.isActive, isTrue);
    expect(
      calls.where((MethodCall c) => c.method == 'adpf.start'),
      hasLength(2),
    );
  });

  test('退后台关会话，回前台重开', () async {
    final AdpfMonitor m = build();
    await m.start();

    m.didChangeAppLifecycleState(AppLifecycleState.paused);
    await pumpEventQueue();
    expect(m.isActive, isFalse);

    m.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await pumpEventQueue();
    expect(m.isActive, isTrue);
    expect(
      calls.where((MethodCall c) => c.method == 'adpf.start'),
      hasLength(2),
    );
  });
}
