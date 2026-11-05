import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 液态玻璃（Liquid Glass）设计令牌。
///
/// 统一使用 const ARGB 字面量而不是 `withOpacity()`：
/// 1) 避免新版 Flutter 的 deprecation 提示；
/// 2) 玻璃层叠时的透明度是「设计值」，写死更可控。
///
/// 文字色只有**两档**，不是三档——这是算出来的，不是审美取舍。
///
/// ## 为什么 `inkMute` 被删掉（A05）
///
/// 旧值 `#8B94A3` 的相对亮度 L=0.293。深色字压浅底时对比度上限是
/// `1.05 / (0.293 + 0.05) = 3.06`——**哪怕背景是纯白也到不了 4.5**。
/// 也就是说它不是「在某个面上偏浅」，而是**在任何浅色面上都不可能达标**，
/// 调面板、加白纱都救不回来。9~11px 的小字必须换成更深的一档。
///
/// 剩下的问题是：深一档之后还剩几档可用？实测弹层面板（遮罩 + 模糊 +
/// 半透明白）最暗处 L≈0.79，4.5:1 要求文字 L ≤ 0.136。而 `ink` 已经是
/// 0.007，`inkSoft` 取 0.120——**两档之间只剩 0.12~0.136 这 0.016 的窗口**，
/// 再塞一档「mute」只会得到两个肉眼分不开、却都贴着及格线的灰。
/// 所以第三档取消，次要文字统一走 [inkSoft]；层次靠字号和字重拉开。
///
/// ## 涨跌色为什么也变深了
///
/// 旧的跌绿 `#0E9F5B` L=0.256，压在 L=0.79 的面板上只有 2.74:1——**连
/// 24px 以上大字要求的 3:1 都不到**。这不是「小字才有的问题」，红绿本身
/// 就得为浅底重新取值。现在两档都落在 4.5 以上，所以同一个颜色可以同时
/// 用于 34px 的价格和 11px 的标签，不必再拆「大字版/小字版」两套红绿。
abstract final class GlassPalette {
  // 文字
  static const Color ink = Color(0xFF10131A);
  static const Color inkSoft = Color(0xFF58616F);

  // 行情涨跌（A 股：涨红、跌绿、平灰）
  //
  // 色相不动（红 5°、绿 152°），只压明度。旧值 E03A2F/0E9F5B 是屏幕观感
  // 调出来的，压在浅玻璃上偏亮。现在按**实测最暗背景**取值：首页卡片 #EAE7E6（L=0.80）、
  // 弹层面板 L≈0.79，红 4.57:1 / 绿 4.82:1，都留了一档余量（见 test/contrast_test.dart）。
  static const Color up = Color(0xFFC62828);
  static const Color down = Color(0xFF0A7341);
  static const Color flat = Color(0xFF5B616C);

  // 玻璃面
  //
  // stroke 50% → 60%：玻璃变透之后，卡片内部几乎和背景同色，唯一还能
  // 说明「这里有一块玻璃」的就是这圈边缘高光。液态玻璃本来也是靠边缘
  // 而不是靠内部来立住形状的。
  static const Color stroke = Color(0x99FFFFFF);
  static const Color strokeSoft = Color(0x4DFFFFFF);
  static const Color shadow = Color(0x1A213A5C);
  static const Color shadowSoft = Color(0x0D213A5C);

  // 背景基色：**中段刻意中性**。
  //
  // 原来 bgTop(FBE7DE) 一路暖到 bgBottom，整片底色自己就带色相，五团光
  // 打上去只显得「更暖」，色相环拉不开——看上去是一整块藕粉色，而不是
  // 几种光。现在顶暖、中中性、底微冷：底色只负责提供「受光的表面」，
  // 上色的事交给雾团。
  //
  // v6：底部从 E9E8F0 再压深一档到 DED9EA。原因是雾团铺满之后，用户
  // 仍觉得下半屏「像留白」——底色本身太接近白，光打上去也显不出色。
  // 底部必须自带一点紫灰，冷光才有东西可叠。
  //
  // v9：再压一档。B 档（60%/×0.45）真机上仍是「看得出颜色」的背景，用户
  // 选 C 档。底色同步从 F9F6F3/F2F1F3/DCDAE1 收到 F8F6F5/EFEEEF/DCDBDE：
  // 三块彩度降到 3/1/3，几乎只能读出明度，读不出色相。
  static const Color bgTop = Color(0xFFF8F6F5);
  static const Color bgMid = Color(0xFFEFEEEF);
  static const Color bgBottom = Color(0xFFDCDBDE);
}

/// 雾团的 alpha 衰减曲线：**高斯型**，不是线性。
///
/// 两色径向渐变（实色 → 全透明）的 alpha 沿半径线性下降，而人眼对线性
/// 衰减非常敏感——每团光都会显出一个「圆盘」的轮廓，五团叠起来就是五块
/// 贴纸。这里用 7 个 stop 把衰减压成高斯分布：前 18% 半径几乎不变，
/// 中段快速掉，边缘彻底归零。边界落在分辨不出的地方，看起来才是「光」。
const List<double> _kFalloff = <double>[1, 0.86, 0.68, 0.48, 0.27, 0.10, 0];
const List<double> _kFalloffStops = <double>[
  0,
  0.18,
  0.36,
  0.54,
  0.72,
  0.88,
  1,
];

/// 数字用等宽字形，价格跳动时不会左右抖（iOS 计价器的观感）
const List<ui.FontFeature> kTabularFigures = <ui.FontFeature>[
  ui.FontFeature.tabularFigures(),
];

/// 全屏白纱：毛玻璃的「雾」。
///
/// 单独一层白，压在雾团之上、底部积影之下。它是「背景不抢阅读」最直接的
/// 手段：降饱和只减弱色相，文字对比度还得靠这层白把整块背景抬亮。
/// alpha 越高越像磨砂玻璃（背景退到 3~4 米外），越低越像清玻璃。
///
/// 12% → 18%：C 档把雾团 alpha 压到原来的三成，颜色已经退到几乎看不出，
/// 此时再不给白纱，背景会变成「浅而脏的灰」——颜色没了，但也没变亮。
/// 这一档的磨砂感主要靠它。
const Color _kVeil = Color(0x2EFFFFFF);

/// 应用背景：中性渐变底 + 一片「晨雾」（极光式多色光域）。
///
/// 教训驱动的四次反转（前三次保留，第四次是这次的 iOS 化重做）：
/// 1. 彩光团 v1（珊瑚/蓝/紫/玫瑰，高饱和）→ frost 玻璃的 saturation 2.1
///    把背景放大成满屏粉红，文字没法读，全部删掉（用户「太丑」）；
/// 2. 纯中性灰 v2 → 玻璃背后**没有任何东西可折射**，液态感消失，
///    卡片退化成普通白卡（用户「液态玻璃的效果不明显」）；
/// 3. 两团单色晨雾 v3 → 有液态感但颜色太素（用户「彩虹颜色比较好看」）；
/// 4. 五团雾 v4（红/蓝/紫/粉/金）→ 颜色够了，但两件事一眼能看出来：
///    每团都像个**圆盘**（线性衰减的边界骗不了眼睛），且红在顶左、蓝在
///    顶右，**隔着画面对冲**，中间混出的是一块灰紫（用户「光晕再好看点，
///    参考 iOS 的设计」）。
///
/// v5 照 iOS 的 mesh 渐变重做，三件事：
/// ① **高斯型衰减**（[_kFalloff]）：径向渐变的 alpha 从线性改成高斯，
///    中心几乎不变、中段快速掉、边缘彻底归零，光就没有「边」；
/// ② **冷暖上下分区**：金/珊瑚在上，粉在右腰，紫/蓝紫在下。色相沿
///    45°→15°→340°→290°→232° 连续下降，不再让红和蓝在水平方向对撞；
/// ③ **一团大而淡的冷底光**（size 900）铺满下半部，只负责「下半部偏冷」
///    这件事，不参与色相环——它太大太淡，永远不会显出圆形边界。
///
/// v6（用户「下半屏要改，上半屏也要多铺点，包括页头」）：
/// ① 底色底部 #E9E8F0 → #DED9EA：底色本身太接近白，冷光打上去也显不出色，
///    底部必须自带一点紫灰才有东西可叠；
/// ② 删掉明暗层顶部的 +5% 白——那层白是页头发灰的直接原因，用户要页头也
///    有颜色，就不能在顶上再盖一层白纱；
/// ③ 雾团整体放大并上移，金光/珊瑚光的圆心抬到画布上缘附近（0.02~0.04），
///    否则页头只吃到衰减尾巴；
/// ④ 新增左下「提亮团」（更亮的淡紫罗兰）：**铺满靠尺寸，层次靠明度**。
///    第一版只把冷光 alpha 提到 0x82，结果下半部是一大块均匀淡紫，
///    像一块紫布——颜色是满了，但明度从头到尾一样平。
///
/// v8（用户「背景色太明显了，要有毛玻璃的效果，不能影响阅读」）：
/// 前七版一直在**加**，这一版整体**减**，两件事一起做才有用：
/// ① 每个色团都朝自己的灰度（Rec.709 亮度）插值 60%，alpha 再乘 0.45。
///    只降 alpha 不降饱和，颜色会变得又淡又脏；只降饱和不降 alpha，
///    色相还在，只是变灰——两样一起，才从「彩色雾」变成「色温」。
/// ② 新增一层 [_kVeil] 白纱（12%）。降饱和只解决色相抢眼，文字对比度
///    得靠白纱把整块背景抬亮。这一层压在雾团之上、底部积影之下，
///    所以立体感（下暗）仍然保留。
///
/// 底色同步去饱和：顶 #FDF5EF → #F9F6F3、中 #F2EDF3 → #F2F1F3、
/// 底 #DED9EA → #DCDAE1。底色是背景里面积最大的那块，它带色相的话，
/// 雾团怎么调都还是"有颜色的背景"。
///
/// v9（用户「C」）：在 B 档基础上再退一档，三个参数一起动：
/// ① 去饱和 60% → **80%**：每个色团朝自身灰度的插值更深，色相几乎读不出；
/// ② alpha ×0.45 → **×0.30**：这一档是「雾」，不是「光」，不能有方向感；
/// ③ 白纱 12% → **18%**：颜色退掉之后必须有东西接手对比度，否则背景
///    会变成「浅而脏的灰」——不抢眼了，但也不够亮。
///
/// 差值的来源：色值全部从**原始饱和色**按 (t=0.80, ×0.30) 重算，不是拿
/// B 的结果再叠一次——后者等于减两遍，会把金/珊瑚压到和冷色同亮度，
/// 整个上半屏的「光源方向」就没了。现在金（0x2BD5C9B7，彩度 30）仍是
/// 全图最暖最亮的一团，只是不再显色。
///
/// ⚠️ 这一档已经接近下限。再往「纯灰」压就是 v2 的死路：玻璃背后没有
/// 可折射的颜色，液态感消失、卡片退化成白卡。要更淡请改白纱而不是
/// 继续去饱和。
///
/// ⚠️ 光团定位**不能用 `Align`**，原因见 [_mistGlow] 的注释：光团尺寸超过
/// 父容器时 Align 的偏移方向会反转，顶光会跑到屏幕正中变成一个橙色圆盘。
///
/// 仍然**无绿色**：绿色在本 App 里专属「跌」，背景出绿会误导。
/// 类名保留 `AuroraBackground`：页 / 弹层 / 预览 harness 的调用点不动。
class AuroraBackground extends StatelessWidget {
  const AuroraBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            GlassPalette.bgTop,
            GlassPalette.bgMid,
            GlassPalette.bgBottom,
          ],
          stops: <double>[0, 0.52, 1],
        ),
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          final double w = c.maxWidth;
          final double h = c.maxHeight;
          return Stack(
            children: <Widget>[
              // ① 冷底光：中下部的主冷调，一次铺满 45%~100% 的高度。
              //    圆心放在 0.52（画布中线附近）而不是贴着底边：高斯衰减
              //    到画面中部就归零了，腰腹位置仍是白的，看上去像
              //    「上半截有色、下半截留白」。
              //
              //    alpha 0x82 → 0x5A：第一版把下半部铺成了一大块**均匀的
              //    淡紫**——颜色是满了，但明度从头到尾一样平，像一块紫布
              //    而不是光。铺满靠尺寸，层次靠 alpha 和下面的提亮团。
              _mistGlow(
                w,
                h,
                size: 1100,
                color: const Color(0x10A0A3AF),
                at: const Offset(0.20, 0.55),
              ),
              // ② 底光：圆心在画布下缘之外，只有上缘进画面。
              //    只干一件事——让最底下那 15% 也有色，不留纯底色。
              //    放在画布外是安全的：高斯尾部已经完全归零，不会切出硬边。
              _mistGlow(
                w,
                h,
                size: 1000,
                color: const Color(0x0A9896A8),
                at: const Offset(0.05, 1.12),
              ),
              // ③ 紫：右下。冷调里唯一有明确色相的一团，负责接住上面的粉。
              //    圆心压到 0.88：紫色集中在下缘右侧，中下部才不会被整片
              //    紫灰糊住（那是"脏"的来源，不是"深"的来源）。
              _mistGlow(
                w,
                h,
                size: 760,
                color: const Color(0x1C9C98AB),
                at: const Offset(0.75, 0.88),
              ),
              // ④ 提亮：中下偏左的一团**更亮**的淡紫罗兰。
              //
              //    这一团不提供新色相，只是把底部那片冷色「提起来」，
              //    制造明度起伏。iOS 壁纸的柔和感来自明暗的连续变化，
              //    而不是把几种颜色平均铺开——纯靠叠加色相，最后一定是
              //    一块平涂的色块。
              _mistGlow(
                w,
                h,
                size: 950,
                color: const Color(0x15D0CDD7),
                at: const Offset(0.30, 0.70),
              ),
              // ⑤ 粉：右下角。**v7 新增**。
              //
              //    真机上（2760px 长屏）下半部只剩一整片紫，颜色是满了，
              //    但只有一个色相，滚到底部时像一块紫布。补一团右下角的
              //    粉，让下半部至少有两个色相在过渡——这是"铺满"和
              //    "好看"的区别：前者靠覆盖面积，后者靠色相和明度的变化。
              _mistGlow(
                w,
                h,
                size: 620,
                color: const Color(0x0EC3AFB8),
                at: const Offset(0.92, 0.74),
              ),
              // ⑤ 粉：右腰。冷暖之间唯一的过渡色，位置必须在紫和珊瑚之间。
              //    alpha 是彩团里最低的——它只负责「接上」，不负责出彩；
              //    给高了整张图会糊成一片藕粉。
              _mistGlow(
                w,
                h,
                size: 640,
                color: const Color(0x1CBCACB3),
                at: const Offset(1.02, 0.20),
              ),
              // ⑥ 珊瑚：顶右。和金色一起构成「顶光」。
              //    圆心抬到 0.02（贴近画布上缘）：用户要求「页头上也多铺点」，
              //    圆心必须真的进可视区，否则页头只吃到衰减尾巴。
              _mistGlow(
                w,
                h,
                size: 760,
                color: const Color(0x28BFACA7),
                at: const Offset(0.62, 0.02),
              ),
              // ⑦ 金：顶左，全图最亮的一团。iOS 的壁纸总有一个明确的光源
              //    方向，这里定在左上，其余色团按明度往下递减。
              //    色值取饱和的金而不是浅金：浅金叠在浅底上只会变成米白，
              //    「金」得靠色相而不是亮度说。
              _mistGlow(
                w,
                h,
                size: 900,
                color: const Color(0x2BD5C9B7),
                at: const Offset(0.16, 0.04),
              ),
              // ⑧ 白纱：把整片雾压成「磨砂玻璃」。
              //    放在明暗层之下，底部的积影仍然能压到画面上。
              Positioned.fill(
                child: IgnorePointer(child: ColoredBox(color: _kVeil)),
              ),
              // ⑦ 明暗层：底部 -7% 冷暗。
              //    **没有顶部白纱**——那层白是页头发灰的直接原因：用户要
              //    页头也有颜色，就不能在顶上再盖一层白。立体感改由
              //    「底部压暗」单独承担，光源方向依然成立。
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: <Color>[
                          Color(0x00FFFFFF),
                          Color(0x00FFFFFF),
                          Color(0x12222B48),
                        ],
                        stops: <double>[0, 0.55, 1],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 行情卡的玻璃参数（单一来源）。
///
/// 页头按产品要求**完全透明**（背后直接是 AuroraBackground 的连续渐变），
/// 所以玻璃材质只用在卡片上；这里仍是唯一一份参数，改只改这里。
///
/// 「再透一点」这一版调的是四个叠在一起才会变白的量，只调其中任何一个
/// 都救不回来：
/// - 白纱 8% → 4%：白膜本身；
/// - 霜 0.20 → 0.12：模糊层压上去的那层乳白；
/// - 厚度 72 → 56：透镜带越厚，采样进来越多背景白，边缘带越宽；
/// - 高光 1.6 → 1.35 / 亮边 2.2 → 1.8：卡身上下那两条白带。
/// 同时饱和度 1.15 → 1.30 **补回来**：去掉白纱后折射会显得发灰，靠饱和度
/// 把雾团颜色提亮，才是「透明玻璃」而不是「灰塑料」。
/// v6「只要玻璃质感，不要白光」：把**所有加色**项清零，只留**光学形变**项。
///
/// 读包源码确认了白光的四个来源（`liquid_glass_settings.dart` 的文档）：
/// - `rimLight`：光轴（默认 π/2 = 正上方）两端各一个光瓣，核心 1px + 柔尾，
///   **加色混合**。卡片上下那两条白带就是它，顶部比底部亮。
/// - `lightIntensity`：宽镜面高光，同样加色。
/// - `glassColor`：白纱本身（4% 白）。
/// - `frostOpacity`：霜层压上去的乳白。
///
/// 而「玻璃质感」在包里是另一组量，与白光无关：
/// - `fresnelStrength`：菲涅尔边缘反射，只在轮廓一圈，不形成条带；
/// - `chromaticAberration`：色散，边缘出现细微彩边——玻璃最强的视觉签名；
/// - `rimShade`：**做减法的暗线**（从底色里减掉一个固定步长），它是
///   「泡泡边缘」的轮廓，不会发白，所以保留；
/// - `thickness` / `refractiveIndex`：透镜折射，让背景在边缘被弯折；
/// - `saturation`：去白之后必须补，否则折射会发灰。
///
/// 踩坑记录：只把 `rimLight` 调到 0 而留着 `glassColor`/`frost`，卡片会变成
/// 一块**没有边的雾**（比白带更难看）；反过来只去白纱留 rimLight，白带照旧。
/// 这两组必须一起处理。
final LiquidGlassSettings kGlassSurface = LiquidGlassSettings.ios27Light
    .copyWith(
      // 去白之后折射会显得发灰，靠饱和度把雾团颜色提回来
      saturation: 1.45,
      glassColor: const Color(0x00FFFFFF), // 白纱清零
      frostOpacity: 0.0, // 霜清零
      // 厚度 56 → 44：透镜带仍在（这是「有厚度的材料」的来源），但带子窄一点，
      // 避免边缘折射卷进来的那圈亮边又变成一条白带
      thickness: 44,
      refractiveIndex: 1.52,
      lightIntensity: 0.0, // 宽镜面高光清零
      fresnelStrength: 0.95, // 0.7 → 0.95：轮廓只靠这一圈立住
      rimLight: 0.0, // 上下光瓣清零（白光的真正来源）
      rimShade: 1.0, // 1.8 → 1.0：暗线保留，但不再过重
      rimShadeEnds: 0.2,
      edgeAbsorption: 0.14,
      bodyShade: 0.0, // 必须为 0：0.3 会把卡身压成灰色
      glowIntensity: 1.0,
      chromaticAberration: 0.55, // 0.45 → 0.55：色散加强，玻璃签名
    );

/// 卡片圆角（页头已不再有玻璃，见 [HeaderFade]）
const double kGlassRadius = 28;

/// 页头与列表之间的「背景续接」：把背景的顶部**原样再画一遍**，再随高度渐隐。
///
/// ## 为什么页头不能再放一块玻璃
///
/// 页头原本是一块 `GlassContainer`（`kGlassHeaderSurface`，白纱/霜/高光全清零，
/// 只剩菲涅尔 + `rimShade` 暗线 + 色散）。参数上是「全透明」，但它**仍然
/// 在背景上画了一圈轮廓**：`fresnelStrength 0.95` 的亮边、`rimShade` 的暗线、
/// `chromaticAberration` 的彩边——在浅雾背景上，这就是一条看得见的 28 圆角
/// 矩形边界。而且这层玻璃换不来任何东西：列表 viewport 停在页头下方、硬裁
/// 在页头下沿，卡片**根本进不了页头背后**（原注释里「卡片从玻璃底下穿过」
/// 从未真正发生过）。等于每帧付一次全屏背景捕获，只为了在背景中央画一圈边。
///
/// 现在的做法：页头不放任何材质，直接露出 [AuroraBackground]；让列表
/// viewport 顶到页面最上面（内容靠 padding 让开页头），再在本层盖上
/// 「背景的顶部」——卡片上滑进入本层，被**逐像素相同**的背景吃掉，
/// 静止时完全看不出这里有一层东西，只有卡片滑上来时才会「沉进背景」，
/// 全程没有任何硬边。
///
/// ## 为什么是「重画一遍」而不是填一个近似的颜色
///
/// 试过：从渲染结果采样顶部色，填一个同色渐变。不行——顶部色**随画布尺寸
/// 漂移**：359×789 的中心是 #EBE7E4，390×844 的中心是 #EFEAE8，差 4 阶
/// （1.6%）。因为 [AuroraBackground] 的雾团是固定 dp 尺寸，画布一宽，光团的
/// 相对覆盖就变了。一块比背景暗 1.6% 的矩形，下沿就是一条淡淡的灰线——
/// 正是要消灭的东西。所以这里直接复用 [AuroraBackground]：布局高度传
/// `canvasHeight`（整页高度），光团坐标与背景逐一对得上，**任何宽度都零色差**。
///
/// 代价是多一层静态绘制：`RepaintBoundary` 之后只光栅化一次，缓存纹理约
/// 0.8MB（宽 × 页头高 × dpr²），滚动时不重绘。
class HeaderFade extends StatelessWidget {
  const HeaderFade({
    super.key,
    required this.canvasHeight,
    this.topInset = 0,
    this.solidHeight = 76,
    this.height = headerBlockHeight,
  });

  /// 整页高度（= [AuroraBackground] 的画布高度）。
  ///
  /// 必须是**背景那一层**的高度，不是本层的高度：本层只有页头那么高，
  /// 按它布局光团的话位置会整体错开，颜色就对不上了。
  final double canvasHeight;

  /// 状态栏高度（本层铺到屏幕最上面，坐标从 y=0 起算）
  final double topInset;

  /// 从这里开始渐隐（页头文字区的下沿）
  final double solidHeight;

  /// 本层在页面坐标里的底边（= 列表顶部留白）
  final double height;

  @override
  Widget build(BuildContext context) {
    final double solidStop = (topInset + solidHeight) / canvasHeight;
    final double endStop = (topInset + height) / canvasHeight;

    return IgnorePointer(
      // 静态内容：滚动时不必跟着列表一起重绘
      child: RepaintBoundary(
        child: ClipRect(
          // 让背景按整页高度布局，只露出最上面这一段
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minHeight: canvasHeight,
            maxHeight: canvasHeight,
            child: ShaderMask(
              // 只改不透明度：dstIn 用 shader 的 alpha 乘上去，颜色不动
              blendMode: BlendMode.dstIn,
              shaderCallback: (Rect bounds) => LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: const <Color>[
                  Color(0xFFFFFFFF),
                  Color(0xFFFFFFFF),
                  Color(0x00FFFFFF),
                ],
                stops: <double>[0, solidStop, endStop],
              ).createShader(bounds),
              child: const AuroraBackground(),
            ),
          ),
        ),
      ),
    );
  }
}

/// 列表顶部要让开页头的高度（= [HeaderFade.height]）。
///
/// 从 96 加到 112 是**为了让第一张卡片躲开渐隐区**：留白 96 时卡片顶边
/// 落在 98，正踩在 76→112 的渐隐段里，上沿会被盖掉一截、比卡身灰一档；
/// 留白抬到 112 之后卡片从 114 才开始，渐隐段对它零影响。
const double headerBlockHeight = 112;

/// 一团**没有边界**的光，圆心按画布归一化坐标放置。
///
/// 颜色从「实色 → 全透明」的两点渐变，换成 [_kFalloff] 的七点高斯衰减；
/// 尺寸整体放大，让圆的外缘基本落在屏幕外。
///
/// ⚠️ **为什么不用 `Align`**：`Align` 的 alignment 是「子元素相对父元素的
/// 偏移比例」，公式是 `childCenter = parentCenter + align * (parent - child)/2`。
/// 一旦光团尺寸超过父容器，`(parent - child)` 变负，**偏移方向整体反转**。
/// v6 第一版就踩了这个坑：把顶光 size 从 720 提到 900（超过屏幕高度）之后，
/// 本该在左上角的金光跑到了屏幕正中，显出一个边界清晰的橙色圆盘——看起来
/// 像"光晕画坏了"，实际是坐标算反了。
///
/// 现在显式计算圆心：`at = (0,0)` 是画布左上角，`(1,1)` 是右下角，
/// 允许超出（圆心在画布外时只有上缘进画面）。位置与尺寸完全解耦。
Positioned _mistGlow(
  double canvasW,
  double canvasH, {
  required double size,
  required Color color,
  required Offset at,
}) {
  final double cx = at.dx * canvasW;
  final double cy = at.dy * canvasH;
  return Positioned(
    left: cx - size / 2,
    top: cy - size / 2,
    width: size,
    height: size,
    child: IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: <Color>[
              for (int i = 0; i < _kFalloff.length; i++)
                color.withValues(alpha: color.a * _kFalloff[i]),
            ],
            stops: _kFalloffStops,
          ),
        ),
      ),
    ),
  );
}

/// 液态玻璃面板：磨砂背景 + 半透明白渐变 + 发丝边 + 顶部镜面高光 + 斜向眩光。
///
/// 结构顺序（从下到上）：阴影 → 裁剪 → 背景模糊 → 玻璃填充/描边 → 高光 → 内容。
///
/// ⚠️ 这个类**不走** [kGlassSurface]（那是 LiquidGlassWidgets 的参数，给行情卡
/// 用的）。弹层用的是这里的自绘实现，所以「弹层要更透」改的是本类的默认
/// [tint] 与调用点传进来的 [blur]——这两处才是弹层那层白膜的真实来源。
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.radius = 26,
    this.blur = 26,
    this.padding = EdgeInsets.zero,
    this.tint,
    this.lifted = true,
    this.isolateChild = true,
  });

  final Widget child;
  final double radius;
  final double blur;
  final EdgeInsetsGeometry padding;

  /// 自定义玻璃填充（默认是白 30% → 白 12% 的对角渐变）
  final Gradient? tint;

  /// 是否带外阴影（悬浮卡片 true，内嵌元素 false）
  final bool lifted;

  /// 内容是否独占一个图层（默认 true）。
  ///
  /// **这不是可选的优化，是结构约束**：`BackdropFilter` 的子节点与滤镜在同一个
  /// 图层里，内容一重绘就会把 `sigma=blur` 的模糊整块重跑一遍。
  ///
  /// 列表卡片那边早就踩过并修正了同一个坑（`quote_tile.dart` 的类注释：
  /// 「试验过把 RepaintBoundary 放进玻璃内部，实测无效」——那是因为那里的玻璃
  /// 是 `GlassContainer`，它会把子内容画进自己的图层。这里的 `GlassPanel` 是
  /// 自绘实现，子内容**确实**是 `BackdropFilter` 的 child，隔一层就生效）。
  ///
  /// 只有"玻璃本身很小、内容几乎不重绘"的地方（如错误提示条）才值得关掉，
  /// 省下一个合成层。
  final bool isolateChild;

  @override
  Widget build(BuildContext context) {
    final BorderRadius r = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: lifted
            ? const <BoxShadow>[
                // 投影再轻一档：玻璃透了之后，原来那圈 10% 的深蓝投在
                // 浅雾上会变成一条明显的"脏边"，比不悬浮还难看
                BoxShadow(
                  color: Color(0x12213A5C),
                  blurRadius: 26,
                  spreadRadius: -8,
                  offset: Offset(0, 14),
                ),
                BoxShadow(
                  color: GlassPalette.shadowSoft,
                  blurRadius: 4,
                  offset: Offset(0, 1),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: DecoratedBox(
            decoration: BoxDecoration(
              // 白 55%→24% 降到 30%→12%：这层是弹层"发灰白"的主犯。
              // 背后已经有一层 blur 和深色 barrier，再压 55% 白就只剩塑料片。
              //
              // 30%→12% 又回到 **74%→60%**（A05）。上一版只算了「看起来透
              // 不透」，没算「字还能不能读」：15% 遮罩把页面压到 #E8E7E5，
              // 再叠 12% 白，面板只剩 L≈0.62 —— 中灰面。小字要 4.5:1 就要求
              // 文字 L ≤ 0.09，那已经是纯黑，红绿更是无解（跌绿只有 2.3:1）。
              // 内容层不是装饰层，它必须**足够亮到能承载文字**；"透"靠边缘
              // 高光、模糊和色相渗透保留，不靠把整块面板拉灰。
              gradient:
                  tint ??
                  const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[Color(0xBDFFFFFF), Color(0x99FFFFFF)],
                  ),
              borderRadius: r,
              border: Border.all(color: GlassPalette.stroke, width: 1),
            ),
            child: Stack(
              children: <Widget>[
                // 顶部 1px 镜面反光，玻璃的「厚度」主要靠它。
                // 收到 65%：白纱减半后，原来那条 90% 的纯白线会独自变成
                // 卡顶上一条刺眼的白边
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: <Color>[Color(0xA6FFFFFF), Color(0x00FFFFFF)],
                      ),
                    ),
                  ),
                ),
                // 底部 1px 环境反射，让玻璃看起来有厚度
                const Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  height: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: <Color>[
                          Color(0x00FFFFFF),
                          Color(0x47FFFFFF),
                          Color(0x00FFFFFF),
                        ],
                      ),
                    ),
                  ),
                ),
                // 斜向眩光
                const Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.center,
                          colors: <Color>[Color(0x1FFFFFFF), Color(0x00FFFFFF)],
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: padding,
                  // 内容独占图层：跳价 / 滚动只重绘这一层，不必回灌上面的
                  // BackdropFilter（否则每次重绘都要重跑一次 sigma=blur 的模糊）
                  child: isolateChild ? RepaintBoundary(child: child) : child,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
