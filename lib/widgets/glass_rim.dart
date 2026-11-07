import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// 玻璃边缘光学层：把「一块半透明白」变成「一片有厚度的材料」。
///
/// ## 这一层存在的理由
///
/// `GlassPanel` 原来的边缘只有三样东西：一圈**均匀**的 1px 白描边、顶上一条
/// 直线高光、底上一条直线反光。三样都是「印刷」出来的——描边不看光源方向、
/// 高光不跟着圆角走，所以不管内部多透，轮廓永远是平的。用户的原话是
/// 「缺少边缘折射表现，显得平面且不真实」，指的正是这一圈。
///
/// 真实玻璃的边缘之所以能立住形状，靠的是四件事同时发生（也是 iOS
/// Liquid Glass 的边缘配方）：
///
/// 1. **暗发丝边在最外圈**：光穿过材料边界时先被吸收一次，所以最外 1px 是
///    *暗*的，而不是亮的。均匀白描边恰好相反，它让边缘看起来像贴纸。
/// 2. **亮芯在发丝边内侧 1px**：这是受光面（rim light），亮度沿轮廓变化——
///    迎着光的那段最亮，背光段只剩一点点，而不是整圈一样白。
/// 3. **内侧反光**：亮芯往里 3~5px 还有一道更宽、更柔的亮带。它是倒角（bevel）
///    的第二个面接住的环境光；没有它，边缘就只有一条线，没有「厚度」。
/// 4. **色散**：玻璃对不同波长折射率不同，边缘会散出极淡的暖/冷两条细边。
///    强度必须低到「说不上有颜色，但拿掉就觉得假」——这是玻璃最强的视觉签名，
///    也是最容易做过头的一项。
///
/// 另外还有两项辅助：背光侧的**暗 meniscus**（材料在圆角处变厚、透光损失更多）
/// 与右下角的**次级反光**，它们负责让下半圈不塌。
///
/// ## 为什么是自绘而不是用包里的 rim
///
/// `liquid_glass_widgets` 的 rim 只存在于 premium 着色器里（需要整块表面的
/// 背景捕获）。弹层用的是自绘 `BackdropFilter` 方案，没有着色器；为了这一圈
/// 边缘再套一层 premium 玻璃，等于让每个弹层多付一次全屏捕获。这里全部是
/// 静态描边——**一次绘制、缓存位图、滚动不重绘**，代价可以忽略。
///
/// ⚠️ 调用方必须把它放在「填充层之上、内容层之下」，并且用 `ClipRRect` 裁到
/// 圆角内：`MaskFilter.blur` 会让描边溢出形状边界 1~2px。
class GlassRim extends StatelessWidget {
  const GlassRim({super.key, required this.radius, this.intensity = 1});

  /// 与容器的圆角一致。必须**逐像素相同**，否则高光会偏离轮廓——
  /// 一条 1px 的高光错开 2px，看起来就不是玻璃边缘，而是一条画歪的线。
  final double radius;

  /// 整体强度（0~1）。叠在浅底上的面板用 1.0；小面积提示条可以降到 0.8，
  /// 否则一圈完整的光学描边在小尺寸上会显得「描得太重」。
  final double intensity;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      // 静态内容：面板滚动/跳价时不必跟着重绘这一层
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _GlassRimPainter(radius: radius, intensity: intensity),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// 主光源方向：**左上**。
///
/// 原生 iOS 27 用正上方，光瓣落在上下两条边的正中，在宽而扁的卡片上会读成
/// 「上下各一条白带」——项目此前正是因为这两条白带把卡片边缘光清零的。
/// 斜到左上之后，主瓣在左上圆角、次瓣在右下圆角：同样的亮度，读起来是
/// 「一块斜着受光的玻璃」而不是「一个发光的框」。
const Alignment kGlassLightFrom = Alignment.topLeft;
const Alignment kGlassLightTo = Alignment.bottomRight;

/// 同一个方向，换成 `LiquidGlassSettings.lightAngle` 的弧度写法。
///
/// 包里的约定是方向向量 `(cos a, -sin a)`（y 轴朝上），左上 = (-0.707, -0.707)
/// 解得 a = 3π/4。两处必须同时改：自绘的面板用 [kGlassLightFrom]，
/// 卡片用这个角度。
const double kGlassLightAngle = 3 * math.pi / 4;

class _GlassRimPainter extends CustomPainter {
  const _GlassRimPainter({required this.radius, required this.intensity});

  final double radius;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect bounds = Offset.zero & size;

    RRect outline(double inset) => RRect.fromRectAndRadius(
      bounds.deflate(inset),
      Radius.circular(math.max(0, radius - inset)),
    );

    /// 沿轮廓画一道描边，颜色沿 [from] → [to] 的方向衰减。
    ///
    /// [falloff] 是「衰减到全透明」的位置（0~1 的渐变轴比例）：0.55 表示
    /// 走到对角线 55% 处就没了，剩下的半圈完全不画。用线性渐变而不是扫掠
    /// 渐变，是因为扫掠的角度约定（y 向下 + 起止角）实测很难对齐，四条边
    /// 会亮得一样，方向感反而丢了；线性渐变与「光从哪来」一一对应。
    void stroke({
      required double inset,
      required double width,
      required Color color,
      required Alignment from,
      required Alignment to,
      required double alpha,
      double endAlpha = 0,
      /// 对角线中点（也就是另外两个圆角）的强度。给值表示「亮-暗-次亮」
      /// 三档——这是主瓣 + 背光次瓣的正确做法：**一次描边**走完，而不是
      /// 画两笔加色（两笔会在侧面叠成一圈均匀的白环）。
      double midAlpha = -1,
      double falloff = 1,
    }) {
      final double a = (alpha * intensity).clamp(0.0, 1.0);
      final double b = (endAlpha * intensity).clamp(0.0, 1.0);
      final double m = (midAlpha * intensity).clamp(0.0, 1.0);
      final Paint paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..isAntiAlias = true;
      if (falloff <= 0) {
        // 整圈同强度（材料边界这种不跟光走的元素）
        paint.color = color.withValues(alpha: a);
      } else if (midAlpha >= 0) {
        paint.shader = LinearGradient(
          begin: from,
          end: to,
          colors: <Color>[
            color.withValues(alpha: a),
            color.withValues(alpha: m),
            color.withValues(alpha: b),
          ],
          stops: const <double>[0, 0.5, 1],
        ).createShader(bounds);
      } else if (falloff >= 1) {
        // 从 from 到 to 连续衰减到 endAlpha——**两端都不归零**是关键：
        // 一旦中途收到 0，那一小段轮廓就会露出一道「高光到此为止」的接缝，
        // 在圆角上看起来像被切了一刀。
        paint.shader = LinearGradient(
          begin: from,
          end: to,
          colors: <Color>[color.withValues(alpha: a), color.withValues(alpha: b)],
        ).createShader(bounds);
      } else {
        // 只在受光角附近出现（色散用），走到 falloff 就归零
        paint.shader = LinearGradient(
          begin: from,
          end: to,
          colors: <Color>[
            color.withValues(alpha: a),
            color.withValues(alpha: 0),
            color.withValues(alpha: 0),
          ],
          stops: <double>[0, falloff, 1],
        ).createShader(bounds);
      }
      canvas.drawRRect(outline(inset), paint);
    }

    // ① 暗 meniscus：材料在圆角处变厚，透光损失更多。压在背光侧（右下），
    //    两档宽度递减的深色描边叠出「边缘更厚」而不是「一道深边」。
    //    ⚠️ 全文件**不用 MaskFilter.blur**：一次模糊 = 一次全面板离屏，
    //    弹层滑入动画逐帧重栅格化时就是掉帧的来源（真机实测）；柔和感靠
    //    多档低 alpha 描边叠出来，效果接近、代价为零。
    stroke(
      inset: 1.2,
      width: 2.6,
      color: const Color(0xFF0F172A),
      from: kGlassLightTo,
      to: kGlassLightFrom,
      alpha: 0.055,
    );
    stroke(
      inset: 2.6,
      width: 3.2,
      color: const Color(0xFF0F172A),
      from: kGlassLightTo,
      to: kGlassLightFrom,
      alpha: 0.03,
    );

    // ② 冷色散：折射率高的那一端先弯，细边落在更内侧。
    //    只出现在受光角附近——整圈彩边会变成彩虹描边。
    stroke(
      inset: 2.9,
      width: 1.1,
      color: const Color(0xFFBBD3FF),
      from: kGlassLightFrom,
      to: kGlassLightTo,
      alpha: 0.07,
      falloff: 0.35,
    );

    // ③ 暖色散：紧贴暗发丝边的内侧，与冷边错开约 2px 形成「色散对」。
    stroke(
      inset: 1.15,
      width: 1.2,
      color: const Color(0xFFFFD6BE),
      from: kGlassLightFrom,
      to: kGlassLightTo,
      alpha: 0.12,
      falloff: 0.35,
    );

    // ④ 暗发丝边：**最外圈是暗的**。这是与「均匀白描边」最本质的区别：
    //    描边勾的是形状，发丝边勾的是材料边界。这一道不跟光走——材料边界
    //    是整圈都在的，只是被亮芯盖住一部分。
    stroke(
      inset: 0.55,
      width: 1.1,
      color: const Color(0xFF0B1220),
      from: Alignment.center,
      to: kGlassLightTo,
      alpha: 0.22,
      falloff: 0,
    );

    // ⑤ 亮芯：受光面，落在发丝边内侧 1px。从受光角起，沿对角线迅速衰减。
    stroke(
      inset: 1.55,
      width: 1.3,
      color: const Color(0xFFFFFFFF),
      from: kGlassLightFrom,
      to: kGlassLightTo,
      alpha: 0.9,
      midAlpha: 0.10,
      endAlpha: 0.42,
    );

    // ⑥ 亮芯的柔尾：向内部散开 3px。没有它，亮芯就是一条硬白线（上一版
    //    的直线高光正是这个毛病）；有了它才像「光在材料里散开」。
    stroke(
      inset: 1.55,
      width: 1.8,
      color: const Color(0xFFFFFFFF),
      from: kGlassLightFrom,
      to: kGlassLightTo,
      alpha: 0.15,
      midAlpha: 0.02,
      endAlpha: 0.05,
    );
    stroke(
      inset: 2.6,
      width: 2.8,
      color: const Color(0xFFFFFFFF),
      from: kGlassLightFrom,
      to: kGlassLightTo,
      alpha: 0.06,
      midAlpha: 0.01,
      endAlpha: 0.03,
    );

    // ⑦ 内侧反光：倒角的第二个面接住的环境光，往内 3.4px、更宽更柔。
    //    这一道是「厚度」的来源——只有一条亮线是薄片，亮线里面再有一层
    //    反光才是块料。
    stroke(
      inset: 3.4,
      width: 1.8,
      color: const Color(0xFFFFFFFF),
      from: kGlassLightFrom,
      to: kGlassLightTo,
      alpha: 0.18,
      midAlpha: 0.02,
      endAlpha: 0.02,
    );
    stroke(
      inset: 4.5,
      width: 2.4,
      color: const Color(0xFFFFFFFF),
      from: kGlassLightFrom,
      to: kGlassLightTo,
      alpha: 0.08,
      midAlpha: 0.01,
      endAlpha: 0.01,
    );

    // ⑧ 底部反光：环境光从下方打上来，落在右下角。
    stroke(
      inset: 0.9,
      width: 1.4,
      color: const Color(0xFFFFFFFF),
      from: const Alignment(0.7, 1),
      to: const Alignment(-0.4, -1),
      alpha: 0.10,
      midAlpha: 0.02,
      endAlpha: 0.06,
    );
  }

  @override
  bool shouldRepaint(_GlassRimPainter oldDelegate) =>
      oldDelegate.radius != radius || oldDelegate.intensity != intensity;
}
