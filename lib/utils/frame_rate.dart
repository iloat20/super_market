import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app_log.dart';

/// 平台通道：Android 侧 `MainActivity` 注册了 `setFrameRate`。
const MethodChannel _kChannel = MethodChannel('itick/perf');

/// 帧率下发出口。测试替换它，避免真的碰平台通道。
typedef FrameRateSink = Future<void> Function(int fps, {required bool fixed});

/// 默认出口。
///
/// 两种失败都不该让上层感知：
/// - `MissingPluginException`：桌面 / widget 测试环境没有原生实现；
/// - `PlatformException`：系统拒绝（OEM 刷新率策略很常见），保持原样即可。
Future<void> _applyToPlatform(int fps, {required bool fixed}) async {
  try {
    final int? applied = await _kChannel.invokeMethod<int>(
      'setFrameRate',
      <String, Object>{'fps': fps, 'fixed': fixed},
    );
    AppLog.d('frameRate: 请求 ${fps}Hz fixed=$fixed -> 实际 ${applied ?? 0}Hz');
  } on MissingPluginException {
    // 没有原生实现（桌面、widget 测试），静默
  } on PlatformException catch (e) {
    AppLog.w('frameRate: 请求 ${fps}Hz 被拒绝（${e.code}）');
  } on Object catch (e) {
    // 原生侧参数编码 / 类型转换抛出的异常不在这两类里；`_sink` 被
    // unawaited，漏出去就是一条 unhandled async error，且 Future 永不完成。
    AppLog.w('frameRate: 请求 ${fps}Hz 出现未预期异常（$e）');
  }
}

/// 滚动期间升到高刷、停下后回落的调度器。
///
/// ## 为什么不「开机就钉最高档」
///
/// 面板一直跑 120Hz 意味着静态看行情时也按 120Hz 刷新，LTPO 没法往 10Hz
/// 掉——费电是实实在在的。清单页真正需要高刷的只有滑动那一两秒，所以只在
/// 滑动期间投票，停下 [idleDelay] 后回落。
///
/// ## 两个档次用不同的 compatibility
///
/// - 升档用 `DEFAULT`：允许系统按倍数自由选择。如果这一帧没赶上（raster
///   超预算），系统可以退回 60 重帧，比强撑 120 造成的 judder 好看。
/// - 回落用 `FIXED_SOURCE`：必须真的掉下去。60 是 120 的约数，用 `DEFAULT`
///   的话系统完全可以「继续 120，只是重帧」——那就白回落了。
///
/// ## 只在**状态切换**时下发
///
/// 滚动期间 `ScrollUpdateNotification` 每帧都来，逐条下发会变成每帧一次
/// 跨平台调用。这里用 [_active] 做边沿触发：一次滑动只投一次票。
class ScrollFrameRateController {
  ScrollFrameRateController({
    this.highFps = 120,
    this.lowFps = 60,
    this.idleDelay = const Duration(milliseconds: 800),
    FrameRateSink? sink,
  }) : _sink = sink ?? _applyToPlatform;

  /// 滑动期间请求的帧率。Panel 不支持 120 时，原生侧会就近降到实际最高档。
  final int highFps;

  /// 停下后回落的帧率。
  final int lowFps;

  /// 停手多久算「停下来了」。短了会在连续滑动中反复升降档，长了省不到电。
  final Duration idleDelay;

  final FrameRateSink _sink;

  /// 最近一次**请求**的帧率（不是系统实际给的）。`null` = 还没投过票。
  int? _requested;
  bool _active = false;
  Timer? _idleTimer;
  bool _disposed = false;

  /// 最近一次请求的帧率，测试与日志用。
  int? get requested => _requested;

  /// 是否处于「滑动中」状态。
  bool get isActive => _active;

  /// 接到滚动通知上。返回 `false` 对应的语义由调用方决定（不吞通知）。
  void handle(ScrollNotification notification) {
    if (_disposed) return;
    if (notification is ScrollEndNotification) {
      _scheduleIdle();
      return;
    }
    // ⚠️ 停手时 Flutter 会连发两条：`ScrollEndNotification` 紧跟一条
    // `UserScrollNotification(direction: idle)`。把后者当成「又开始滑了」，
    // 就会把刚排上的回落定时器取消掉——回落永远不发生，档位永远停在 120。
    // 这个坑是测试抓出来的（真机上表现为「说好省电、结果一直高刷」）。
    if (notification is UserScrollNotification &&
        notification.direction == ScrollDirection.idle) {
      return;
    }
    _activate();
  }

  /// 立刻落回低档，不排队。开屏时用：没有它，应用会停在系统默认档直到第一次
  /// 滑动结束。
  ///
  /// **只在还没投过票时生效**。控制器是全应用共享的，如果每次有新的滚动容器
  /// 挂载（比如打开自选弹层）都无条件落低档，弹层的上滑动画就会被压到 60，
  /// 而用户可能正从一个正在滑动的列表里点进来。
  void settle() {
    if (_disposed) return;
    if (_requested != null) return;
    _active = false;
    _idleTimer?.cancel();
    _idleTimer = null;
    _request(lowFps, fixed: true);
  }

  void _activate() {
    // 新的一帧滚动进来：作废待执行的回落
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_active) return;
    _active = true;
    _request(highFps, fixed: false);
  }

  void _scheduleIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleDelay, () {
      _idleTimer = null;
      if (_disposed || !_active) return;
      _active = false;
      _request(lowFps, fixed: true);
    });
  }

  void _request(int fps, {required bool fixed}) {
    if (_requested == fps) return;
    _requested = fps;
    // 故意不 await：这是提示性调用，晚一帧也无所谓，但绝不能在滚动路径上
    // 让 UI 线程等一个跨平台往返。
    unawaited(_sink(fps, fixed: fixed));
  }

  void dispose() {
    _disposed = true;
    _idleTimer?.cancel();
    _idleTimer = null;
  }
}

/// 全应用共用一份：首页列表和自选弹层同时存在时，两份控制器会互相投票，
/// 后结束的那次把另一个仍在滑动的档位打回 60。
final ScrollFrameRateController appFrameRateController =
    ScrollFrameRateController();

/// 把子树里所有滚动通知接到 [ScrollFrameRateController]。
///
/// 包在滚动容器**外面**：`NotificationListener` 只能收到后代冒泡上来的通知。
class ScrollFrameRate extends StatefulWidget {
  const ScrollFrameRate({super.key, required this.child, this.controller});

  final Widget child;

  /// 传入共享控制器（[appFrameRateController]）；不传则自己 new 一个并负责释放。
  final ScrollFrameRateController? controller;

  @override
  State<ScrollFrameRate> createState() => _ScrollFrameRateState();
}

class _ScrollFrameRateState extends State<ScrollFrameRate> {
  late final bool _owns = widget.controller == null;
  late final ScrollFrameRateController _controller =
      widget.controller ?? ScrollFrameRateController();

  @override
  void initState() {
    super.initState();
    // 开屏先落低档：原生侧不再固定 mode，不投票就会停在系统默认档
    _controller.settle();
  }

  @override
  void dispose() {
    if (_owns) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification notification) {
        _controller.handle(notification);
        return false;
      },
      child: widget.child,
    );
  }
}
