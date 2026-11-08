import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../config/app_config.dart';
import 'app_log.dart';
import 'perf_probe.dart';

/// 与 `MainActivity` 共用的性能通道（刷新率投票也在这条通道上）。
const MethodChannel kPerfChannel = MethodChannel('itick/perf');

/// 攒多少帧报一次。
///
/// 为什么不逐帧报：`reportActualWorkDuration` 每次都要过一次 Binder，
/// 120Hz 下就是每秒 120 次 IPC。攒 8 帧（60Hz 约 133ms、120Hz 约 67ms）
/// 报一次平均值——ADPF 的消费者是滚动窗口，平均值足够表达负载形态。
const int kAdpfBatchFrames = 8;

/// 攒多久报一次（微秒）。帧率很低时按时间兜底，避免半天不报一次。
const int kAdpfBatchMicros = 200 * 1000;

/// 目标工作时长占帧预算的比例。
///
/// 0.75 与引擎侧 ADPF 实现（flutter/flutter #192582）一致：留 25% 给 GPU 合成
/// 与调度抖动。目标定成 100% 会让系统为了追一个几乎不可能的目标猛拉频率，
/// 反而更容易过热降频。
const double kAdpfTargetRatio = 0.75;

/// 连续几次上报失败就自动关掉（会话被系统 EPIPE 掉时不要再刷日志）。
const int kAdpfMaxFailures = 3;

/// Android ADPF（动态性能框架）接入：把每帧的真实工作量报给系统。
///
/// ## 为什么要自己做
///
/// Flutter 引擎在 3.47.9 里**没有任何 ADPF 代码**（`libflutter.so` 里
/// `APerformanceHint` 命中 0 处，见 `tool/android_engine_caps.sh`），
/// 上游 PR #192582 仍未合并。所以在引擎接上之前，只能应用层自己回报。
///
/// ## 做了什么
///
/// 1. Dart 侧用 `SchedulerBinding.addTimingsCallback` 拿每帧 `buildDuration`
///    与 `rasterDuration`（引擎自己测的，比任何外部采样都准）；
/// 2. 攒批后经 `itick/perf` 通道发给 Kotlin；
/// 3. Kotlin 侧把 Flutter 的 `1.ui` / `1.raster` 线程登记进一条
///    `PerformanceHintSession`，逐批回报实际工作时长。
///
/// ## 边界（写清楚，免得以后当成万能药）
///
/// - 只在 Android 上跑；`AppConfig.enableAdpf == false` 时什么都不做。
/// - 平台侧不支持（API < 31、找不到线程、ROM 限制）时**静默降级**：
///   `start()` 返回 false，连 timings 回调都不注册，零常驻开销。
/// - 它改善的是「CPU 频率爬升的时机」，不减少帧数——别指望它把 12ms 的帧变 8ms。
class AdpfMonitor with WidgetsBindingObserver {
  AdpfMonitor({MethodChannel? channel, double Function()? refreshRate})
    : _channel = channel ?? kPerfChannel,
      _refreshRate = refreshRate ?? currentRefreshRate {
    WidgetsBinding.instance.addObserver(this);
  }

  final MethodChannel _channel;
  final double Function() _refreshRate;

  bool _active = false;
  bool _disposed = false;
  int _failures = 0;
  int _frames = 0;
  int _workNanos = 0;
  int _batchStartMicros = 0;

  /// 会话是否真的建起来了（平台侧返回 true 且没被关掉）。
  bool get isActive => _active;

  /// 目标工作时长（纳秒）：按**当前**刷新率算，120Hz 与 60Hz 自动不同。
  @visibleForTesting
  int targetWorkNanos() => (1e9 / _hz * kAdpfTargetRatio).round();

  /// 刷新率；取不到（0）时按 60 兜底——宁可低估预算，也别把目标定得太狠。
  double get _hz {
    final double hz = _refreshRate();
    return hz > 0 ? hz : 60;
  }

  /// 是否有一次 start 正卡在 Binder await 上（此时 [_active] 仍是 false）。
  bool _starting = false;

  /// 帧回调是否已注册：SchedulerBinding.removeTimingsCallback 对未注册的
  /// 回调会断言失败，窗口期 stop 不能无条件移除。
  bool _callbacksRegistered = false;

  /// 代际令牌：stop / 新的 start 会 +1，让在途的 start 结果作废。
  int _generation = 0;

  /// 建会话。失败（含通道不存在）就是静默不可用，不抛。
  Future<void> start() async {
    if (_disposed || _active || _starting) {
      return;
    }
    _starting = true;
    final int generation = ++_generation;
    bool ok = false;
    try {
      ok =
          await _channel.invokeMethod<bool>('adpf.start', <String, Object>{
            'targetNanos': targetWorkNanos(),
          }) ??
          false;
    } on Object catch (e) {
      // MissingPluginException（预览/测试）、PlatformException（ROM 拒绝）都走这里
      AppLog.d('ADPF 不可用：$e');
      return;
    } finally {
      _starting = false;
    }
    // pause 落在 Binder await 窗口时代际已变，这次结果必须作废：
    // 否则会在后台把会话与帧回调重新挂上，且永远不会再有人来关它。
    if (!ok || _disposed || generation != _generation) {
      return;
    }
    _active = true;
    _failures = 0;
    _resetBatch();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _callbacksRegistered = true;
    AppLog.i(
      'ADPF 已启用：目标 ${targetWorkNanos() ~/ 1000}µs'
      '（${_hz.toStringAsFixed(0)}Hz）',
    );
  }

  /// 关会话。`stop()` 之后可以再 `start()`（回前台会走这条路）。
  Future<void> stop() async {
    // 先作废在途的 start，再判断有没有东西要关。窗口期 _active 仍是
    // false，但 Binder 那边随时可能刚建好会话，所以 _starting 也算「有会话」。
    _generation++;
    final bool hadSession = _active || _starting;
    _active = false;
    if (!hadSession) {
      return;
    }
    if (_callbacksRegistered) {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      _callbacksRegistered = false;
    }
    _resetBatch();
    try {
      await _channel.invokeMethod<void>('adpf.stop');
    } on Object catch (_) {
      // 关不掉也无所谓：进程还在时下一次 start 会先 close 旧会话
    }
  }

  /// 退后台就别占着会话，回前台重开。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) {
      return;
    }
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        unawaited(stop());
      case AppLifecycleState.resumed:
        if (!_active) {
          unawaited(start());
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    unawaited(stop());
    WidgetsBinding.instance.removeObserver(this);
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final FrameTiming t in timings) {
      ingest(
        buildNanos: t.buildDuration.inMicroseconds * 1000,
        rasterNanos: t.rasterDuration.inMicroseconds * 1000,
        nowMicros: t.timestampInMicroseconds(ui.FramePhase.rasterFinishWallTime),
      );
    }
  }

  /// 收一帧的工作量。拆出来是为了让测试不必伪造 [FrameTiming]。
  @visibleForTesting
  void ingest({
    required int buildNanos,
    required int rasterNanos,
    required int nowMicros,
  }) {
    if (!_active) {
      return;
    }
    if (_batchStartMicros == 0) {
      _batchStartMicros = nowMicros;
    }
    _frames++;
    _workNanos += buildNanos + rasterNanos;
    if (_frames >= kAdpfBatchFrames ||
        nowMicros - _batchStartMicros >= kAdpfBatchMicros) {
      _flush();
    }
  }

  void _flush() {
    final int frames = _frames;
    if (frames == 0) {
      return;
    }
    final int avg = _workNanos ~/ frames;
    _resetBatch();
    unawaited(
      _channel
          .invokeMethod<void>('adpf.report', <String, Object>{
            'workNanos': avg,
            'targetNanos': targetWorkNanos(),
            'frames': frames,
          })
          .catchError((Object e) {
            _onReportFailed(e);
          }),
    );
  }

  void _onReportFailed(Object error) {
    if (_disposed || !_active) {
      return;
    }
    _failures++;
    if (_failures >= kAdpfMaxFailures) {
      AppLog.w('ADPF 连续 $_failures 次上报失败，自动关闭：$error');
      unawaited(stop());
      return;
    }
    AppLog.d('ADPF 上报失败（第 $_failures 次）：$error');
  }

  void _resetBatch() {
    _frames = 0;
    _workNanos = 0;
    _batchStartMicros = 0;
  }
}

/// 装上 ADPF。返回的对象由调用方持有（进程级单例，不需要 dispose）。
///
/// **首帧之后**才建会话：Kotlin 侧要按线程名扫 `/proc/self/task` 找
/// `1.ui` / `1.raster`，引擎把这些线程命名好是在启动早期，但首帧之后更稳。
AdpfMonitor? installAdpf() {
  if (!AppConfig.enableAdpf) {
    return null;
  }
  if (defaultTargetPlatform != TargetPlatform.android) {
    return null;
  }
  final AdpfMonitor monitor = AdpfMonitor();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(monitor.start());
  });
  return monitor;
}
