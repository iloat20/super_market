import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter/material.dart';

import '../utils/market_session.dart';

/// 圆形太极徽标（页头身份图标）。
///
/// [regions] 里的**任意市场**处于交易时段（含集合竞价）时，每来一条行情就
/// 转一格——给「数据是活的」一个不用读文字的信号；全部市场都不在交易、
/// 或者数据本身没到，就静止。
///
/// 页面传入当前订阅列表的市场并集（如 `['SH', 'HK']`）：混合 A+H 自选时，
/// A 股 15:00 收盘后港股还在跳，太极必须跟着动。
///
/// ## 为什么是「数据驱动转一格」而不是「按时段一直转」
///
/// 旧实现按交易时段 `AnimationController.repeat()`：09:15–15:00 之间以
/// 12 秒一圈、约 60fps 连续出帧，每天约 5.5 小时。两个代价：
///
/// 1. 这 5.5 小时里应用**永远没有静止帧**，LTPO 面板无法降到 1~10Hz；
/// 2. 每帧都要重录一次 picture，其中 `BoxShadow` 的 maskFilter 模糊要重跑。
///
/// 更要紧的是语义：旧注释自己写着「数据本来就不动，图标还在转就是在撒谎」，
/// 而它转不转其实只跟钟点有关——午休、停牌、源全挂的时候照样转。现在把
/// 「转」直接绑在**报价到达**上，这句话才真正落地；顺带删掉了每 30 秒
/// 重判时段的定时器，以及为它服务的 `LifecyclePause`。
///
/// 「有没有行情」由页面注入的 [ticks] 计数表达，「算不算数」由 [regions]
/// 的时段判定把关：收盘后快照仍会 3s 一次，但价格不动，转了就是撒谎。
class TaijiMark extends StatefulWidget {
  const TaijiMark({
    super.key,
    this.now = DateTime.now,
    this.size = 36,
    this.regions = const <String>['SH', 'SZ'],
    this.ticks,
  });

  /// 可注入时钟，与页面的 `clock` 参数同一条线：测试和预览钉死时刻，
  /// 否则同一份代码在不同时间跑出不同的动画状态，golden 自己失效。
  final DateTime Function() now;

  /// 徽标直径，太极本体占满整个圆（无外圈）。
  final double size;

  /// 参与判定的市场集合（region 代码：SH/SZ 走 A 股时段，HK 走港股时段）。
  /// 页面随订阅列表更新；缺省只看 A 股。
  final List<String> regions;

  /// 行情到达计数：每 +1 转一格。
  ///
  /// 传 `null` 表示**永不转动**（静态预览、纯渲染测试）。用计数器而不是
  /// `ValueListenable<Quote>`：太极不关心价格是多少，只关心「有没有东西动过」，
  /// 传一个 int 就不必认识那个类型。
  final ValueListenable<int>? ticks;

  /// 每格转多少圈。
  ///
  /// 24 格 = 一圈：3 秒一格 → 72 秒转完一圈。12 秒一圈的旧速度是靠 60fps
  /// 连续出帧撑出来的，改成「每格一跳」后必须放慢，否则会像被人猛拨了一下。
  /// 想更克制就调大分母（48 → 2.4 分钟一圈），想更明显就调小。
  static const double turnsPerTick = 1 / 24;

  /// 单格动画时长。
  ///
  /// 比轮询间隔（3s）短一个数量级：长于 1s 会显得拖沓，短于 150ms 会变成硬跳；
  /// 也不该接近 3s——与下一格首尾相接就没有「停顿」这个节奏了。
  static const Duration stepDuration = Duration(milliseconds: 300);

  @override
  State<TaijiMark> createState() => _TaijiMarkState();
}

class _TaijiMarkState extends State<TaijiMark>
    with SingleTickerProviderStateMixin {
  late List<String> _regions;

  /// 只在「走一格」时运行的单次控制器；跑完自然停在 1.0。
  late final AnimationController _spin;

  /// 当前这一格的起止角度（单位：圈）。
  ///
  /// 用累计值而不是让控制器承载绝对角度：上一个 tick 还没走完又来了新 tick
  /// （手动重连、切源后的立即拉取）时，可以从「当前位置」继续，不会跳回起点。
  double _from = 0;
  double _to = 0;

  /// 系统「减少动态效果」开关。在 [didChangeDependencies] 里读，
  /// 不在 initState 里读 MediaQuery：开关可能在使用过程中被切。
  bool _reduceMotion = false;

  /// 缓动后的当前角度（圈）。
  double get _turns =>
      _from + (_to - _from) * Curves.easeOutCubic.transform(_spin.value);

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(vsync: this, duration: TaijiMark.stepDuration);
    _regions = List<String>.of(widget.regions);
    widget.ticks?.addListener(_onTick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool reduce = MediaQuery.disableAnimationsOf(context);
    if (reduce != _reduceMotion) {
      _reduceMotion = reduce;
      // 开关中途打开：把正在走的那一格停住，停在当前角度，不跳回起点
      if (reduce) {
        _spin.stop();
      }
    }
  }

  @override
  void didUpdateWidget(TaijiMark oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.ticks, oldWidget.ticks)) {
      oldWidget.ticks?.removeListener(_onTick);
      widget.ticks?.addListener(_onTick);
    }
    // 订阅列表变了 → 市场集合可能变了。不必当场重判：是否转动由**下一个
    // tick** 决定，而那一刻读的就是新集合（[_anyLive] 走 [_regions]）。
    if (!listEquals(widget.regions, oldWidget.regions)) {
      _regions = List<String>.of(widget.regions);
    }
  }

  /// 一条行情到达：走一格。
  void _onTick() {
    if (!mounted || _reduceMotion) {
      return;
    }
    if (!_anyLive(widget.now())) {
      return; // 收盘 / 午休 / 周末：数据可能还在来（快照），但价格没动
    }
    final double current = _turns;
    _from = current;
    _to = current + TaijiMark.turnsPerTick;
    _spin.forward(from: 0);
  }

  /// 订阅里任意市场在交易（含集合竞价）即视为「数据是活的」
  bool _anyLive(DateTime t) {
    for (final String region in _regions) {
      final MarketSession session = switch (region) {
        'HK' => MarketSession.ofHk(t),
        'US' => MarketSession.ofUs(t),
        _ => MarketSession.of(t),
      };
      if (session.isLive) {
        return true;
      }
    }
    return false;
  }

  @override
  void dispose() {
    widget.ticks?.removeListener(_onTick);
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _spin,
      builder: (BuildContext context, Widget? child) {
        return Transform.rotate(angle: _turns * 2 * math.pi, child: child);
      },
      // 旋转作用在**独立图层**上：徽标本体只栅格化一次，之后每帧只是改了一个
      // 变换矩阵，不再重跑 BoxShadow 的 maskFilter 模糊与 CustomPaint 重录。
      child: RepaintBoundary(
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Color(0x1A213A5C),
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: const CustomPaint(painter: _TaijiPainter()),
        ),
      ),
    );
  }
}

/// 太极本体：白底整圆 + 深色鱼形 + 两枚异色鱼眼 + 一圈发丝描边。
///
/// 几何（画布中心为原点，鱼半径 r）：
/// - 深色区域 = 左半大圆 + 上侧小半圆（向右凸）- 下侧小半圆（向左凹），
///   三段圆弧首尾相接成 S 曲线；
/// - 鱼眼在两个鱼头中心 (0, ∓r/2)，颜色与所在鱼身相反。
///
/// 不带外圈：太极本体就是整个徽标（r 占满直径）。白鱼在浅色玻璃上
/// 靠两样东西立住——柔和投影（Container 的 boxShadow）+ 1px 暗色发丝边。
class _TaijiPainter extends CustomPainter {
  const _TaijiPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double r = size.shortestSide / 2;
    final Paint light = Paint()..color = Colors.white;
    final Paint dark = Paint()..color = const Color(0xFF20242E);

    canvas.drawCircle(c, r, light);

    final Path fish = Path()
      ..moveTo(c.dx, c.dy - r)
      // 左半大圆：从顶到底，逆时针（屏幕坐标）走左侧
      ..arcToPoint(
        Offset(c.dx, c.dy + r),
        radius: Radius.circular(r),
        clockwise: false,
      )
      // 下侧小半圆：从底到圆心，凸向左 → 把下鱼头让给白鱼
      ..arcToPoint(
        Offset(c.dx, c.dy),
        radius: Radius.circular(r / 2),
        clockwise: true,
      )
      // 上侧小半圆：从圆心回顶，凸向右 → 黑鱼头咬进白区
      ..arcToPoint(
        Offset(c.dx, c.dy - r),
        radius: Radius.circular(r / 2),
        clockwise: false,
      )
      ..close();
    canvas.drawPath(fish, dark);

    // 鱼眼：白鱼头（下）点黑眼，黑鱼头（上）点白眼
    canvas.drawCircle(Offset(c.dx, c.dy + r / 2), r / 5, dark);
    canvas.drawCircle(Offset(c.dx, c.dy - r / 2), r / 5, light);

    // 发丝边：浅色玻璃上白鱼的轮廓线，1px、贴内缘避免抗锯齿吃掉
    canvas.drawCircle(
      c,
      r - 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x2E213A5C),
    );
  }

  @override
  bool shouldRepaint(_TaijiPainter oldDelegate) => false;
}
