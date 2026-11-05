import 'package:flutter/widgets.dart';

/// 让「周期刷新」的 State 跟随 App 生命周期启停。
///
/// 为什么需要它：`AppLifecycleState.paused` 下 Flutter 只是把
/// `_framesEnabled` 置为 false——**不再产生帧**，但 Dart 侧的 `Timer`
/// 照跑、`setState` 照执行、字符串照分配，页面对象也一个都不会被回收。
/// 「停止渲染」不等于「停止干活」，更不等于「释放引用」。所以退后台时
/// 必须显式把定时器 cancel 掉（并置空，让对象可回收），回前台再重建。
///
/// 实现上刻意**不用** `AppLifecycleListener`：它按「合法状态链」推断
/// 语义（resumed → inactive → hidden → paused），实测直接 `paused →
/// resumed` 的跳变会被整条忽略（探针里 onResume 一次都没触发）。这里直接
/// 看原始状态，谁先到就按谁处理。
mixin LifecyclePause<T extends StatefulWidget> on State<T> {
  _PauseObserver? _observer;

  /// 启动周期任务。回前台时会**立即**调一次，用来补上后台错过的状态。
  /// 实现必须幂等：同一状态可能被重复通知。
  void startTicking();

  /// 停止周期任务：`cancel()` 之后务必把字段置 `null`。
  /// 只 cancel 不置空 = 引用还在，等于没释放。
  void stopTicking();

  @override
  void initState() {
    super.initState();
    final _PauseObserver observer = _PauseObserver(
      onResume: startTicking,
      onStop: stopTicking,
    );
    _observer = observer;
    WidgetsBinding.instance.addObserver(observer);
  }

  @override
  void dispose() {
    final _PauseObserver? observer = _observer;
    if (observer != null) {
      WidgetsBinding.instance.removeObserver(observer);
    }
    _observer = null;
    super.dispose();
  }
}

/// 只做「resumed 就启动、其余状态就停止」的最简判定。
class _PauseObserver with WidgetsBindingObserver {
  _PauseObserver({required this.onResume, required this.onStop});

  final VoidCallback onResume;
  final VoidCallback onStop;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        onResume();
      case AppLifecycleState.inactive:
        // 下拉通知栏 / 来电：瞬时状态，不动。频繁停启反而更费。
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        onStop();
    }
  }
}
