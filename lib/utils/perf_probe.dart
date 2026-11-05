import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// 当前显示器的刷新率（Hz）。取不到时按 60 算——宁可低估预算，也别把
/// 掉帧判成合格。
double currentRefreshRate() {
  final ui.FlutterView? view = ui.PlatformDispatcher.instance.implicitView;
  final double hz = view?.display.refreshRate ?? 0;
  return hz > 0 ? hz : 60;
}

/// 帧耗时探针：把 build / raster 两段耗时打到 logcat。
///
/// 只在 `--dart-define=PERF_LOG=true` 的构建里生效，默认构建里第一个
/// `if` 就返回，不注册任何回调——这样它可以留在代码里，不影响线上包。
///
/// 为什么要探针而不是 `dumpsys gfxinfo`：Flutter 自己接管了渲染线程，
/// HWUI 统计不到它的帧（实测 reset 后滑动一次，`Total frames rendered: 0`）。
/// 唯一可靠的数字来自引擎的 `FrameTiming`。
///
/// **预算不写死**：同一台机器会在 60/90/120 档之间切换（本机实测过 90Hz
/// 的 11111111ns）。写死 11.11ms 的话，换到 120Hz（8.33ms）后掉帧会被
/// 判成合格，数字全部失真。所以每次回调现读 [currentRefreshRate]。
///
/// 读法：
/// - **build 高、raster 低** → UI 线程（重建/布局）慢；
/// - **build 低、raster 高** → GPU 慢，通常是模糊/着色器/大图层；
/// - 两个都不高但总时长高 → 平台线程或 vsync 排队。
void installFrameProbe() {
  const bool enabled = bool.fromEnvironment('PERF_LOG');
  if (!enabled) return;

  final List<FrameTiming> buffer = <FrameTiming>[];

  SchedulerBinding.instance.addTimingsCallback((List<FrameTiming> timings) {
    buffer.addAll(timings);
    if (buffer.length < 40) return;

    final double hz = currentRefreshRate();
    final double budgetMs = 1000.0 / hz;

    final List<double> build = <double>[];
    final List<double> raster = <double>[];
    int buildJank = 0;
    int rasterJank = 0;
    for (final FrameTiming t in buffer) {
      final double b = t.buildDuration.inMicroseconds / 1000.0;
      final double r = t.rasterDuration.inMicroseconds / 1000.0;
      build.add(b);
      raster.add(r);
      if (b > budgetMs) buildJank++;
      if (r > budgetMs) rasterJank++;
    }
    buffer.clear();

    String stat(List<double> v) {
      v.sort();
      final double p50 = v[(v.length * 0.5).floor()];
      final double p90 = v[(v.length * 0.9).floor().clamp(0, v.length - 1)];
      return 'p50=${p50.toStringAsFixed(1)} p90=${p90.toStringAsFixed(1)} '
          'max=${v.last.toStringAsFixed(1)}';
    }

    // 单行输出，方便 logcat 里按 tag 抓起；hz/budget 一起打，数字可自证
    debugPrint(
      '[perf] hz=${hz.toStringAsFixed(0)} budget=${budgetMs.toStringAsFixed(2)} '
      'n=${build.length} '
      'build(${stat(build)}) jank=$buildJank '
      'raster(${stat(raster)}) jank=$rasterJank',
    );
  });
}
