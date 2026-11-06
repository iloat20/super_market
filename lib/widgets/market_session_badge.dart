import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../utils/beijing_clock.dart';
import '../utils/market_session.dart';
import '../utils/lifecycle_pause.dart';
import 'glass.dart';

/// 交易时段角标：交易中 / 集合竞价 / 午间休市 / 已收盘 / 休市 / 未开盘。
///
/// 为什么需要：iTick 只在有成交时推送，收盘后价格自然不动。
/// 只显示「已连接」会让人怀疑卡死；把「已收盘」摆出来才是对静止数据的解释。
///
/// 时段按 [MarketSessionBadge.regions] 里的**订阅市场并集**判定（与太极同口径）：
/// 混合 A+H 自选时，A 股 15:00 收盘后港股仍交易到 16:10，角标不能提前写
/// 「已收盘」；只有 A 股订阅时行为完全不变。订阅列表一变就当场重判，
/// 不等定时器。
///
/// 自己持有 30s 定时器（只在时段真正变化时 setState），
/// 不影响列表：列表的刷新依旧走各自的 ValueNotifier。
class MarketSessionBadge extends StatefulWidget {
  const MarketSessionBadge({
    super.key,
    this.now = beijingNow,
    this.regions = const <String>[],
  });

  /// 可注入时钟。
  ///
  /// 为什么需要：角标文字直接决定截图像素，而它读的是墙钟——于是同一份代码
  /// 在 08:30 的 golden 是「盘前」、09:20 是「集合竞价」，预览图会自己失效。
  /// 生产环境走 beijingNow（与报文时间戳同域），视觉预览里钉死一个时刻。
  final DateTime Function() now;

  /// 当前订阅的市场集合（`SH` / `SZ` / `HK`），由页面传入。
  ///
  /// 自选可以混 A 股和港股：A 股 15:00 收盘后港股还在交易到 16:10，
  /// 只按 A 股口径会写「已收盘」，跟仍在跳的港股行情和自转的太极自相矛盾。
  /// 空集合退回 A 股口径（没传订阅信息的调用方行为不变）。
  final List<String> regions;

  @override
  State<MarketSessionBadge> createState() => _MarketSessionBadgeState();
}

class _MarketSessionBadgeState extends State<MarketSessionBadge>
    with LifecyclePause<MarketSessionBadge> {
  late MarketSession _session;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _session = _resolve(widget.now());
    startTicking();
  }

  /// 订阅列表变了（比如在订阅管理里加了一只港股）要**当场重判**，
  /// 不能等 30s 定时器：刚回到列表页时角标还写着「已收盘」就是撒谎。
  @override
  void didUpdateWidget(MarketSessionBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(widget.regions, oldWidget.regions)) {
      _refresh();
    }
  }

  MarketSession _resolve(DateTime time) =>
      MarketSession.ofRegions(time, widget.regions);

  @override
  void startTicking() {
    if (_timer != null) {
      return; // 幂等
    }
    // 回前台先补一次：后台期间可能已经开盘/收盘了
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  void _refresh() {
    final MarketSession next = _resolve(widget.now());
    if (next != _session) {
      if (mounted) {
        setState(() => _session = next);
      } else {
        _session = next;
      }
    }
  }

  @override
  void stopTicking() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    stopTicking();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool live = _session.isLive;
    // 用蓝色而不是红/绿：红绿在这个 App 里专指涨跌，不能混用作「系统状态」
    final Color dot = live ? const Color(0xFF1D6BF3) : const Color(0xFF8A94A6);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            _session.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 0.1,
              color: live ? const Color(0xFF2C4A7C) : GlassPalette.inkSoft,
            ),
          ),
        ),
      ],
    );
  }
}
