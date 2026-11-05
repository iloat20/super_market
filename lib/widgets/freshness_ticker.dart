import 'dart:async';

import 'package:flutter/widgets.dart';

import '../models/quote.dart';
import '../utils/quote_freshness.dart';

/// 在「这条报价从实时变成快照」的那一刻自动重建一次。
///
/// ## 为什么需要它
///
/// [isStale] 是纯函数，只在 build 时求值。14:59 打开的界面，行情在 15:00
/// 停更（`shouldApplyQuote` 不再放行），`ValueNotifier` 也就再不发声，
/// 卡片和详情页会一直停在「轮询更新」——时间过去了，界面没跟上。
/// 这正是本批次要堵的最后一个「说错话」场景。
///
/// ## 为什么是单次定时器，不是 `Timer.periodic`
///
/// 翻转只发生一次：过了判决线就永远陈旧，直到有新的行情进来。按剩余时间
/// 精确挂一个一次性定时器，翻转后就再也不跑；周期定时器则会让每张卡每
/// 30 秒醒一次，整天都在做无用功（列表 6 张就是 6 个定时器）。
///
/// 触发后**不再重新挂**：万一注入的时钟是停住的（预览/测试），重挂会得到
/// 同一个答案并无限循环。下一次行情到达时 [didUpdateWidget] 会重新挂。
class FreshnessTicker extends StatefulWidget {
  const FreshnessTicker({
    super.key,
    required this.quote,
    required this.now,
    required this.builder,
  });

  final Quote quote;
  final DateTime Function() now;

  /// `stale` 与 [isStale] 同源，构建方不必再算一遍，避免两处判定漂移。
  final Widget Function(BuildContext context, bool stale) builder;

  @override
  State<FreshnessTicker> createState() => _FreshnessTickerState();
}

class _FreshnessTickerState extends State<FreshnessTicker> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(covariant FreshnessTicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 无条件重挂：一条新报价可能把「已陈旧」拉回「实时」，也可能把截止
    // 时间推后。重挂只是 cancel + create 一个 Timer，代价远小于漏判。
    _arm();
  }

  void _arm() {
    _timer?.cancel();
    _timer = null;

    final Duration? remaining = staleIn(widget.quote, widget.now());
    // null = 不会再变：没有行情、没有时间戳（恒陈旧）、或已经陈旧。
    if (remaining == null) {
      return;
    }
    // 判决线是开区间（恰好 5:00 仍算实时，见 isStale），所以多等 1 秒再
    // 重建。少这 1 秒，定时器会落在边界上、算出来还是「实时」，白跑一帧。
    _timer = Timer(remaining + const Duration(seconds: 1), () {
      // 只重建，不重挂。时钟若没走（注入的固定时钟），重挂会死循环。
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, isStale(widget.quote, widget.now()));
}
