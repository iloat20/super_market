import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 把交互控件的可点击区域扩到至少 [minSize]，**但不改变布局占位与绘制**。
///
/// Android 无障碍规范要求的是「每个交互元素的可聚焦区域 ≥48×48dp」，不是
/// 视觉盒子的尺寸。Material 的 `_InputPadding` 会把按钮的布局占位一起撑到
/// 48，那会连带抬高整行、挤动弹层（本项目详情弹层有 0.82 屏高硬约束）。
/// 这里只放宽 `hitTest`：child 的 size / paint 完全不变，所以 golden 逐字节
/// 一致，也不会因为行高变化而挤走图表。
///
/// [alignment] 表示 **child 在扩展区内的位置**，用来把多出来的余量定向到
/// 没有其它交互控件的一侧，避免扩展区互相偷点击：
/// - `Alignment.centerLeft`：child 靠左 → 余量在右侧；
/// - `Alignment.bottomCenter`：child 靠下 → 余量在上方；
/// - `Alignment.bottomRight`：child 靠右下 → 余量在左上方。
class HitTarget extends SingleChildRenderObjectWidget {
  const HitTarget({
    super.key,
    this.minSize = const Size(48, 48),
    this.alignment = Alignment.center,
    required super.child,
  });

  /// 最小命中尺寸。平台基线为 48×48dp（Android / Material 3）。
  final Size minSize;

  /// child 在扩展区内的对齐方式，决定多余空间落在哪一侧。
  final Alignment alignment;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderHitTarget(
        minSize: minSize,
        alignment: alignment,
      );

  @override
  void updateRenderObject(BuildContext context, RenderHitTarget renderObject) {
    renderObject
      ..minSize = minSize
      ..alignment = alignment;
  }
}

/// [HitTarget] 的渲染对象：只放宽命中测试，不改变布局占位与绘制。
class RenderHitTarget extends RenderProxyBoxWithHitTestBehavior {
  RenderHitTarget({
    required this.minSize,
    required this.alignment,
  }) : super(behavior: HitTestBehavior.deferToChild);

  /// 最小命中尺寸。改它只影响 hitTest，无需 markNeedsLayout / markNeedsPaint。
  Size minSize;

  /// child 在扩展区内的对齐方式。同上。
  Alignment alignment;

  /// 相对自身坐标系的命中矩形；允许为负（即向 child 边界外扩）。
  Rect get _expandedRect {
    final double extraW = math.max(0.0, minSize.width - size.width);
    final double extraH = math.max(0.0, minSize.height - size.height);
    final double left = extraW * (alignment.x + 1) / 2;
    final double top = extraH * (alignment.y + 1) / 2;
    return Rect.fromLTWH(
      -left,
      -top,
      size.width + extraW,
      size.height + extraH,
    );
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (size.isEmpty) {
      return super.hitTest(result, position: position);
    }
    if (!_expandedRect.contains(position)) {
      return super.hitTest(result, position: position);
    }

    // 命中点可能在 child 边界之外。把它钳回边界内再委派给 child，
    // child 里的 GestureDetector / InkWell / IconButton 才会收到 pointer down。
    // Rect.contains 对 right/bottom 是严格小于，钳到边界值会被 child 拒绝，
    // 所以留一个 epsilon。
    const double eps = 0.01;
    final Offset clamped = Offset(
      position.dx.clamp(0.0, size.width - eps).toDouble(),
      position.dy.clamp(0.0, size.height - eps).toDouble(),
    );
    if (hitTestChildren(result, position: clamped)) {
      return true;
    }
    return hitTestSelf(clamped);
  }
}
