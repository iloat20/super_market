import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:material_ui/material_ui.dart';

import 'glass_rim.dart';

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
  //
  // ✅ v18 实色底色是 `#F0EEE9`（L≈0.856），仍高于上面取色用的
  // L≈0.79 基线：inkSoft / 涨红 / 跌绿估算都过 4.5:1。
  // contrast_test 仍按叫停未跑，估算不等于实测。
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
  //
  /// 整页底色（v18 用户指定 `#F0EEE9`）：实色层、极光层、详情弹层底色膜共用。
  ///
  /// `#F0EEE9`：RGB 240/238/233，近白的中性微暖（R-G-B 只差 2~5），
  /// 相对亮度 L≈0.856 —— 与 v17 的 `#F5EDE2`（0.855）几乎相同，
  /// 但**色相更中性**：v17 的暖调来自 R-B 差 19，这版只差 7。
  ///
  /// 单一实色，无渐变、无雾团。详情弹层的底色膜是本色的 93% 版本
  /// （v15 起玻璃层是卡片那套 `GlassContainer.card` + `kGlassSurface`），
  /// 滚动磨砂带 `_DetailHeaderScrim` 也取本常量；v19 起订阅弹层的
  /// 93% 底色膜与 76% `glassColor` 同样取本常量 —— 改这一处，
  /// 背景 / 详情页 / 订阅弹层一起换色。
  ///
  /// ✅ 亮度仍高于项目基线「面板最暗处 L≈0.79」：按基线估算
  /// inkSoft ≈5.3:1、涨红 ≈4.9:1、跌绿 ≈5.2:1，三档都过 4.5:1；
  /// 且无绿相，v14 淡绿与「跌绿」撞相的问题不再有。
  /// `contrast_test` 仍按叫停未跑，**估算不等于实测**。
  static const Color background = Color(0xFFF0EEE9);

  // v10（用户「背景色用白色」）：三档基色收成同一实色（纯白）。
  // v11（豆腐白）/ v12（#F5F5F0）/ v13（#E6E5D6，含详情弹层）/
  // v14（#D3DFD3）/ v15（详情弹层改卡片玻璃）/ v16（#E8E3D9）/
  // v17（#F5EDE2）/ v18（#F0EEE9）：实色一律取 [background]。
  // v9 那三档只在 [kSolidBackground] 关掉、极光重新启用时才用得上，
  // 历史值见 git。
  static const Color bgTop = background;
  static const Color bgMid = background;
  static const Color bgBottom = background;
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

/// 整页背景是否为**单一实色**（v10 起；v11 把这块实色定为豆腐白）。
///
/// `true`：[AuroraBackground] 只画一层不透明的 [GlassPalette.background]，
/// 雾团 / 白纱 / 底部压暗全部不绘制。类名和调用点保持不变，页头
/// [HeaderFade] 仍复用同一个 Widget，「盖上去之后顶部像素零色差」这条
/// 保证因此依然成立。
///
/// `false`：回到 v9 的极光实现（底色同样取 [GlassPalette.background]），
/// 白底上仍留极淡的雾与底部压暗——玻璃背后多一点可折射的层次。
/// **只改这一个常量即可回退**，v1~v9 的调参记录与绘制代码都原样留在
/// 下面，没有删。
///
/// ⚠️ 单一实色的代价（v2 的老教训）：背景没有明暗和色相起伏时，卡片的
/// premium 折射、色散、边缘光学基本读不出来，接近普通白卡。豆腐白只比
/// 纯白多给一点底色，救不回折射；要更多层次就把开关翻成 false。
const bool kSolidBackground = true;

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
/// v1~v9 的极光背景**刻意不含绿色**：绿色在本 App 里专属「跌」，
/// 背景出绿会误导。v14 曾短暂换成淡绿 `#D3DFD3`（用户指定），
/// v16 又回到无绿相的暖米灰 `#E8E3D9`，这条约束恢复。
/// 类名保留 `AuroraBackground`：页 / 弹层 / 预览 harness 的调用点不动。
///
/// ## v10：背景色用白色
///
/// 从 v1 到 v9 一直在做减法（降饱和 → 降 alpha → 加白纱），到这里用户
/// 直接要白色。所以 [build] 在 [kSolidBackground] 为 true 时提前返回
/// 一层不透明实色，下面 v5~v9 那整套极光画布**不参与绘制**；代码保留是为了
/// 一行常量就能回退，也为了留住这九轮调参的原因（不是只留结论）。
///
/// ## v11：实色由纯白改豆腐白 / v12~v18：色号连续拍板
///
/// 用户看了纯白真机截图后要「豆腐白」：仍是单一实色、仍无雾团，只把
/// [GlassPalette.background] 从 `#FFFFFF` 换成豆腐白；19:07 指定
/// `#F5F5F0`（替换我先前自选的 `#F7F5EF`），19:29 改 `#E6E5D6`，
/// 19:37 换 `#D3DFD3`，19:53 `#E8E3D9`，20:11 `#F5EDE2`，
/// 20:32 再定 `#F0EEE9`。改一处即全生效，页头 [HeaderFade]、
/// Widget Previews 复用本类自动跟上。
///
/// ## v13：背景与详情弹层统一色号 / v14：只改一个常量
///
/// 19:29 用户「背景色和详情页改这个色号」。整页背景、页头、预览走本类；
/// 详情弹层是 `quote_detail_sheet.dart` 里独立的自绘 `GlassPanel`，
/// 当时把它的 `tint` 和滚动磨砂带都接到了 [GlassPalette.background]
/// 上（玻璃层本来不吃这个令牌）。所以 v14 换色时**只动了一个常量**，
/// 背景与详情页自动联动。订阅弹层走 `kSheetGlassSurface` 的 premium
/// 材质，两轮都未改。
///
/// ## v15：详情弹层改用卡片玻璃
///
/// 用户「详情页的玻璃用卡片的玻璃效果」。详情弹层从自绘 `GlassPanel`
/// （`BackdropFilter` + 白膜 + `GlassRim`）迁到 `GlassContainer.card`
/// + `kGlassSurface` premium，与 `QuoteTile` 同一个入口、同一套材质；
/// 结构照 `quote_tile.dart` 的 Stack 分层（玻璃背景层 / 内容平级 +
/// `RepaintBoundary`）。底色膜最终定在 93% 的 [GlassPalette.background]：
/// 首版 72% 在真机上压不住背后的列表价格，弹层文字与列表叠成一片；
/// 调实一档后可读性恢复，边缘折射 / rim / 色散仍可见。
///
/// ⚠️ `test/detail_paint_layers_test.dart` 两条断言写死了 `GlassPanel`
/// 与「内容到 `BackdropFilter` 之间必须有 `RepaintBoundary`」，新结构下
/// 会红，需同步改断言（本轮按叫停未跑、未改测试）。
///
/// ## v16：换回暖米灰 `#E8E3D9`
///
/// 用户「换这个色号」。只改 [GlassPalette.background] 一个常量：
/// 整页背景、页头、预览、详情弹层底色膜、滚动磨砂带全部联动。
/// 淡绿带来的「与跌色撞相」问题随之消失，亮度回到 v13 附近；
/// 详情弹层的卡片玻璃（v15）与本轮无关，未动。
///
/// ## v17：暖米白 `#F5EDE2`，对比度风险解除
///
/// 用户「换这个色号」。仍然只改 [GlassPalette.background] 一个常量。
/// 这档 L≈0.855 已高于项目对比度基线 0.79，v13~v16 一直贴着
/// 4.5:1 的涨红按估算终于过线；`contrast_test` 按叫停未跑，
/// 估算值不等于实测值。详情弹层的卡片玻璃与 93% 底色膜都未动。
///
/// ## v18：中性近白 `#F0EEE9`
///
/// 用户「换这个色号」。仍只改 [GlassPalette.background] 一个常量。
/// 亮度与 v17 几乎相同（L≈0.856），差别在色相：暖调压到 R-B 差 7，
/// 更接近中性白。对比度结论不变（估算三档都过 4.5:1，
/// `contrast_test` 仍未跑）。详情弹层结构与 93% 底色膜都未动。
///
/// ## v19：订阅弹层接入同一色号
///
/// 用户「订阅管理弹层也用这个色号」。它原本走 `kSheetGlassSurface`
/// 的 76% **白**膜，不吃背景令牌。两处一起改：膜的 `glassColor` 换成
/// [GlassPalette.background] 的 76%，玻璃层下面再铺一层 93% 底色膜
/// （和详情弹层一致，用于挡住背后的列表文字）。至此整页背景、
/// 详情弹层、订阅弹层三处表面共用一个色号。
///
/// 实色层比极光版更省：少 8 个径向渐变、少一层白纱和一层明暗渐变，
/// 静态层光栅化一次即可。[HeaderFade] 复用本类，两边同为同一实色，
/// 任何画幅下都零色差。
class AuroraBackground extends StatelessWidget {
  const AuroraBackground({super.key});

  @override
  Widget build(BuildContext context) {
    if (kSolidBackground) {
      return const ColoredBox(color: GlassPalette.background);
    }
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
/// （这条路线到 v10 把斜向 rimLight 请了回来；v20 曾补回白纱与轻霜，被
/// v21 整组撤销回到透明玻璃。v22 曾把边缘暗部与投影全清零，结果只剩一圈
/// 白边、丢了折射与玻璃感，已按用户要求**回退到 v21**。下面几节是版本史，
/// 最终值以文件末尾的 v21 为准。注意 v11~v19 是**背景色号**的版本序列，
/// 别和这里的卡片材质版本混了。）
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
///
/// ## v10：把边缘光「换个方向」请回来
///
/// v6 清零 rimLight 是因为它当时的光轴在**正上方**（原生 π/2）：两个光瓣落在
/// 上下两条边的正中，在 100dp 高的扁卡上就是「上下各一条白带」，看着像发光框
/// 而不是玻璃。那一版之后卡片只剩折射 + 暗发丝边 + 色散，于是又走到另一个
/// 极端——真机上看是一块「边上有暗线的半透明片」，没有受光面，所以平。
///
/// 这次不是把亮度加回来，而是**把光轴转到左上斜角**（[kGlassLightAngle]）：
/// 同样的 `rimLight`，光瓣落在左上/右下两个**圆角**上，读起来是「一块斜着
/// 受光的玻璃」。三个值配套改：
/// - `rimLight` 0 → **0.75**（原生 1.0；我们的卡比原生控制件薄、更透，
///   满强度会变成一圈白描边，先给 3/4）；
/// - `edgeAbsorption` 0.14 → **0.18**：边缘变厚，透光损失更多，暗部才有地方
///   接住高光（只提亮不压暗 = 发光边）；
/// - `refractiveIndex` 1.52 → **1.55**：真玻璃约 1.5，边缘弯曲再强一档，
///   在雾团渐变上能看出「背景被弯了一下」。
///
/// 宽幅镜面（`lightIntensity`）仍然是 0——它才是「整条白带」的来源，
/// `rimLight` 只是贴着轮廓的两个光瓣，两者不是一回事。
///
/// ## v20：整体再推一档，让「这里有块玻璃」一眼可读
///
/// ⚠️ **这一版的白纱 / 霜 / 模糊已被 v21 整组撤销**：用户要的是透明玻璃，
/// 不是磨砂玻璃。以下保留作版本史，别照着它调。
///
/// （沿用材质调参序列：v19 是订阅弹层换色。v11~v19 里的 v11 指背景豆腐白，
/// 与本节无关。）
///
/// v10 把斜向边缘光请回来之后，真机上是一块受光的透明片，但**卡身与背景
/// 几乎同色**，静止画面里读不出材质。这次不换方向重做，只把同一套光学各
/// 加一档，再补极轻的一层「体」：
/// - `glassColor` 全透明 → **4% 白**（v5 之前白纱的量级）。包用的是保亮度
///   tint（`applyGlassColorLW`），只借色相不压亮度，不会把背景洗白；
/// - `frostOpacity` 0 → **0.16**、`blur` 0.6 → **1.2**：背景在卡内被轻轻
///   糊一下，卡内外才有「隔着一层」的差别。frost 只走 premium，blur 在
///   降级路径也生效；
/// - 边缘光学：`refractiveIndex` 1.55 → **1.60**、`thickness` 44 → **48**、
///   `fresnelStrength` 0.9 → **1.1**、`rimLight` 0.75 → **0.9**、
///   `edgeAbsorption` 0.18 → **0.22**、`chromaticAberration` 0.55 → **0.65**、
///   `glowIntensity` 1.0 → **1.2**（降级路径的边缘光也跟着亮一档）；
/// - `saturation` 1.5 → **1.6**：补回白纱/霜之后颜色不能发灰。
///
/// 三条**不能越过的线**（都是真机踩过的）：
/// 1. `lightIntensity` 仍为 0——一旦回来就是横贯上下边的整条白带；
/// 2. `rimLight` 不到 1.0、光轴仍是左上 3π/4——满强度会变成一圈白描边；
/// 3. `thickness` 不到 56——v9 时透镜带卷进来的那圈亮边就是一条白带。
/// `bodyShade` 仍为 0（0.3 会把卡身压成灰塑料）。
///
/// ## v21：改回透明玻璃（2026-11-07 用户拍板）
///
/// v20 补的 4% 白纱 + 0.16 轻霜 + blur 1.2 把卡片做成了**磨砂玻璃**：
/// 卡身糊了一层雾，背景不再原样透出来。用户要的是「透明玻璃」——卡身
/// 必须完全透，玻璃感全部由**边缘光学**承担。这一版：
/// - 白纱、霜、模糊整组撤掉：`glassColor` 全透明、`frost: 0`、
///   `frostOpacity: 0`、`blur: 0`，`saturation` 回 1.5。顺带省掉 premium
///   的 frost / blur 两个 pass；
/// - 少了「体」，纯光学再推一档顶上：`thickness` 48 → **52**、
///   `refractiveIndex` 1.60 → **1.64**、`fresnelStrength` 1.1 → **1.25**、
///   `rimLight` 0.9 → **0.95**、`edgeAbsorption` 0.22 → **0.26**、
///   `chromaticAberration` 0.65 → **0.7**。这些都是**形变 / 反射**而不是
///   加色：卡身像素仍等于背景，只有轮廓一圈被弯折、提亮、压暗、拆出彩边
///   ——透明玻璃正是靠这一圈被认出来的。
/// - **最关键的一项**：`bodyMode` 从默认 `adaptive` 改成
///   `GlassBodyMode.clear`。包源码写得很明白：adaptive「matches Apple's
///   Glass.regular」，是保亮度归一化的**半透明常规玻璃**，会把卡身整体
///   提亮；clear「matches Apple's Glass.clear」，才是按 alpha 直接合成的
///   **透明玻璃**，且 specular / Fresnel / rim 物理全部保留。前面把 white
///   项清得再干净，只要还是 adaptive，卡身就仍是一块白片。订阅弹层的
///   `kSheetGlassSurface` 早就用 clear。
///
/// 红线照旧：`lightIntensity = 0`、`rimLight < 1.0` 且光轴左上 3π/4、
/// `thickness < 56`、`bodyShade = 0`。
///
/// ## v22（已回退）：只清暗部会变成一圈白边
///
/// 曾按「完全透明、不要灰色边缘」把 `rimShade` / `rimShadeEnds` /
/// `edgeAbsorption` / `shadow` / `shadowElevation` 全清零，亮边也收一档。
/// 灰边确实消失了，但**玻璃感也一起没了**：用户反馈「变成白边了，没有了
/// 边缘折射，没有了玻璃感」。按用户要求整体回退到 v21，本节只留踩坑记录。
///
/// 根因（2026-11-07 查包源码确认）：premium 折射是
/// `texture(uBackgroundTexture, uv + displacement)` 采样**背景纹理**做 UV
/// 弯折；而 `kSolidBackground = true` 把背景画成单一实色 `#F0EEE9`，位移后
/// 采到的颜色完全相同，折射在视觉上根本不存在。边缘之所以看得见，靠的是
/// 「加色亮部 + 减色暗部」这一对对比；清掉暗部后只剩加色项，就成了白边。
/// 想既不留灰、又要有折射，得让背景本身有可折的明暗/色相起伏——这是背景
/// 设计取舍，不能只靠调 `kGlassSurface` 解决。
final LiquidGlassSettings kGlassSurface = LiquidGlassSettings.ios27Light
    .copyWith(
      // 透明玻璃：卡身不叠任何颜色、不起任何雾。包文档明确 blur: 0 是
      // "clear optical glass"（跳过模糊 pass，但保留镜面高光 / 菲涅尔 /
      // 亚像素边缘折射），不是纯色填充。
      // 关键：包默认 `adaptive` 是 Apple 的 Glass.regular（保亮度归一化的
      // 半透明常规玻璃），会把卡身整体提亮成白片，光清 white 项没用。
      // clear = Apple 的 Glass.clear：按 alpha 直接合成，glassColor 为 0 时
      // 卡身像素就等于背景，specular / Fresnel / rim 物理照旧保留。
      bodyMode: GlassBodyMode.clear,
      saturation: 1.5, // 回到 v10 基线：没有白纱/霜要补色
      glassColor: const Color(0x00FFFFFF), // 全透明，背景原样透出来
      frost: 0, // 显式关掉霜层的 blur pass（frostOpacity 0 时本就不画）
      frostOpacity: 0.0,
      blur: 0,
      // 卡身透明之后，玻璃只能靠「边缘」显形，光学项比 v20 再推一档：
      // 厚度 48 → 52，仍不到 v9 那条 56 的亮边白带红线
      thickness: 52,
      refractiveIndex: 1.64, // 真玻璃约 1.5，边缘弯折更明确
      lightIntensity: 0.0, // 必须为 0：宽镜面高光是整条白带的来源
      fresnelStrength: 1.25, // 轮廓反射（物理项，不加白膜）
      // 光轴保持左上斜角：光瓣落在对角圆角上，不再横贯上下边
      lightAngle: kGlassLightAngle,
      rimLight: 0.95, // 逼近原生 1.0 但不到顶，避免一圈白描边
      rimShade: 1.0, // 暗发丝边保留，才接得住高光
      rimShadeEnds: 0.2,
      edgeAbsorption: 0.26, // 透明玻璃靠背光侧的暗部显形
      bodyShade: 0.0, // 必须为 0：0.3 会把卡身压成灰色
      glowIntensity: 1.2, // 降级路径（flutter_tester / 无 Impeller）的边缘光
      chromaticAberration: 0.7, // 色散是玻璃最强的签名；包标注 WIP，别再往上
    );

/// 订阅弹层的玻璃材质（v19 起**只服务订阅弹层**；详情弹层 v15 已改走
/// [kGlassSurface]）。
///
/// 边缘光学（折射 / rim light / 暗发丝边 / 色散）与模糊 18 沿用原值。
///
/// `bodyMode: clear` 是关键：默认的 adaptive 会「保住背景亮度、只取色相」，
/// 玻璃色再高也提不亮深色背景；clear 才是真正的 alpha 合成。
///
/// v19（用户「订阅管理弹层也用这个色号」）：`glassColor` 从 76% 白换成
/// [GlassPalette.background] 的 76% —— 白膜会把底色洗成白，必须连膜一起
/// 换色，弹层才呈 `#F0EEE9`。与详情弹层的 93% 底色膜是同一套思路，
/// 以后改背景令牌时自动联动。
final LiquidGlassSettings kSheetGlassSurface = LiquidGlassSettings.ios27Light
    .copyWith(
      bodyMode: GlassBodyMode.clear,
      glassColor: GlassPalette.background.withValues(alpha: 0.76),
      blur: 18,
      frost: 0,
      saturation: 1.2,
      thickness: 34,
      refractiveIndex: 1.45,
      lightAngle: kGlassLightAngle,
      lightIntensity: 0.25,
      fresnelStrength: 0.85,
      rimLight: 0.55,
      rimShade: 1,
      rimShadeEnds: 0.2,
      edgeAbsorption: 0.12,
      chromaticAberration: 0.35,
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
    // 页头内容底边：top 0 + padding 8 + 太极区 48 + padding 10（2026-11-05
    // 页头上移 10px 后的值；调用方 quote_list_page 传的也是它）
    this.solidHeight = 66,
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
/// 历史上从 96 加到 112，是为了让第一张卡片躲开渐隐区：留白 96 时卡片顶边
/// 落在 98，正踩在 76→112 的渐隐段里，上沿会被盖掉一截、比卡身灰一档。
///
/// 2026-11-05 两轮收紧（用户：「卡片区域往上提一点」→「再上移 20px」）：
/// 112 → 100（-12）→ **80**（-20）。页头底边在 66（页头上移 10px 后），
/// 渐隐起点动不了，靠压缩渐隐段（36 → 24 → **14px**）上移底边——卡片从
/// 82 开始，仍在渐隐段之外，不会被压灰。渐隐段只剩 14px，上滑时卡片被
/// 「吃掉」的过程比较急促，这是紧凑布局的代价；再往上提就要连页头一起
/// 重排了（卡片与页头底边只剩 16px 视觉间隔）。
const double headerBlockHeight = 80;

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

/// 液态玻璃面板：磨砂背景 + 半透明白渐变 + 边缘光学（见 [GlassRim]）。
///
/// ⚠️ **这是本工程自绘的组件，不是 `liquid_glass_widgets` 的 API**。
/// 包 1.16.1 里不存在 `GlassPanel`（`lib/` 与 CHANGELOG 均零命中），
/// 所以「某版本起废弃、应迁到 `GlassCard`」不适用于这个类；反过来
/// `GlassCard` 才是包里已 `@Deprecated`、2.0.0 移除的那个。别按包名
/// 想当然地替换——本类的 `GlassRim` 边缘光学、边缘去白膜与零 saveLayer
/// 实现是真机调出来的，没有包内等价物。见 `test/glass_card_api_test.dart`。
///
/// 结构顺序（从下到上）：阴影 → 裁剪 → 背景模糊 → 玻璃填充 → 边缘光学 → 眩光 → 内容。
///
/// ⚠️ 这个类**不走** [kGlassSurface]（那是 LiquidGlassWidgets 的参数，给行情卡
/// 用的）。「弹层要更透」改的是本类的默认 [tint] 与调用点传进来的 [blur]
/// ——这两处才是那层白膜的真实来源。
///
/// ⚠️ v15 起**详情弹层已不再用本类**（迁到 `GlassContainer.card` +
/// `kGlassSurface` premium，见 `quote_detail_sheet.dart`）。本类现在只服务
/// 列表页的错误提示条；它承载 17:08 那次「零 saveLayer / 零 MaskFilter」
/// 的真机掉帧修复，别因为「弹层都不用了」就顺手删掉。
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

  /// 自定义玻璃填充（默认是白 74% → 60% 的对角渐变）
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
    // 边缘去白膜的宽度。
    //
    // 悬浮面板（弹层）才有：它的边缘必须能看见**背后的东西**，玻璃才立得住。
    // 提示条（lifted = false）高度只有 40 上下，上下各切 16px 会把红色底全
    // 擦光，所以那一档不切。
    final double edgeClear = lifted ? 9 : 0;
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
          child: Stack(
            children: <Widget>[
              // 玻璃填充：白膜 + 边缘去白膜。
              //
              // 白 55%→24% 降到 30%→12%：这层是弹层"发灰白"的主犯。
              // 背后已经有一层 blur 和深色 barrier，再压 55% 白就只剩塑料片。
              //
              // 30%→12% 又回到 **74%→60%**（A05）。上一版只算了「看起来透
              // 不透」，没算「字还能不能读」：15% 遮罩把页面压到 #E8E7E5，
              // 再叠 12% 白，面板只剩 L≈0.62 —— 中灰面。小字要 4.5:1 就要求
              // 文字 L ≤ 0.09，那已经是纯黑，红绿更是无解（跌绿只有 2.3:1）。
              // 内容层不是装饰层，它必须**足够亮到能承载文字**；"透"靠边缘
              // 高光、模糊和色相渗透保留，不靠把整块面板拉灰。
              Positioned.fill(
                child: CustomPaint(
                  painter: _GlassFillPainter(
                    radius: radius,
                    gradient:
                        tint ??
                        const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: <Color>[Color(0xBDFFFFFF), Color(0x99FFFFFF)],
                        ),
                    edgeClear: edgeClear,
                  ),
                ),
              ),
              // 边缘光学：暗发丝边 / 亮芯 / 内侧反光 / 色散 / 底部反光。
              // 这一层替代了原来的「均匀 1px 白边 + 上下两条直线高光」——
              // 那三样不看光源方向，是「平」的根源。
              Positioned.fill(
                child: GlassRim(
                  radius: radius,
                  // 提示条面积小，完整的八道描边在小尺寸上会描得太重
                  intensity: lifted ? 1 : 0.7,
                ),
              ),
              // 斜向眩光：整块玻璃接住的漫反射。12% → 8%：边缘光学立起来之后，
              // 大面积的斜向白会盖住它，点到为止即可。
              const Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.center,
                        colors: <Color>[Color(0x14FFFFFF), Color(0x00FFFFFF)],
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
    );
  }
}

/// 玻璃填充：整块白膜，但**轮廓内侧 [edgeClear] 的一圈把白膜分三档变薄**
/// （55% → 70% → 87% → 内部 100%）。
///
/// ## 为什么必须薄这一圈
///
/// 玻璃的「厚度」只能从边缘读出来，而白膜是一张盖住整块面板的纸——它把边缘
/// 也盖住了。改动期量过：白膜 74%→60% 时，边缘处背景只透出 26~40%，在倒角带里
/// 加一圈「低模糊 + 1.05 倍放大」的透镜，整张图最大像素差只有 **4/255**，等于
/// 没有。变薄之后同一处能透出 50~60%，背景的卡片边界、文字块在倒角里重新出现，
/// 「这块玻璃有厚度」才成立。内部的白膜**一点没动**，所以文字对比度
/// （`test/contrast_test.dart` 量的就是文字左侧 4dp）不受影响。
///
/// ## 为什么是「分档直填」而不是 saveLayer + dstOut
///
/// 两个原因，都硬：
///
/// 1. **帧率**。`saveLayer` 会开一块**整个面板大小**的离屏；弹层滑入动画期间
///    这棵子树逐帧重栅格化，等于每帧 1 次全面板离屏。再算上边缘光学里原本的
///    4 道 `MaskFilter.blur`（每道也是一次离屏），一帧 5 次全面板通道——
///    真机上打开弹层直接掉帧（2026-11-06 真机反馈）。改成 evenOdd 环形路径
///    逐档直填之后，填充本身就是 4 次普通渐变绘制，没有任何离屏。
/// 2. **可复现**。`dstOut` + `MaskFilter.blur` 在软件光栅下还会产出 1 阶随机
///    噪声（同一次提交连跑两遍 `--update-goldens` md5 不同），golden 永远
///    对不上。直填是纯几何，逐像素确定。
///
/// 档与档之间的过渡带用 evenOdd（外环减内环）画，同一份渐变、只按档位把
/// alpha 缩放——三档每级只差 0.03 左右亮度，1x 看不出阶梯。
class _GlassFillPainter extends CustomPainter {
  const _GlassFillPainter({
    required this.radius,
    required this.gradient,
    required this.edgeClear,
  });

  final double radius;
  final Gradient gradient;
  final double edgeClear;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    RRect shapeOf(double inset) => RRect.fromRectAndRadius(
      rect.deflate(inset),
      Radius.circular(math.max(0, radius - inset)),
    );
    final Paint fill = Paint()..shader = gradient.createShader(rect);

    if (edgeClear <= 0) {
      canvas.drawRRect(shapeOf(0), fill);
      return;
    }

    // 环形分档：(内缩起点, 内缩终点, 白膜强度)。外圈最薄，向内逐档回到全值。
    void band(double outer, double inner, double factor) {
      final Path ring = Path()
        ..fillType = PathFillType.evenOdd
        ..addRRect(shapeOf(outer))
        ..addRRect(shapeOf(inner));
      canvas.drawPath(
        ring,
        Paint()..shader = _fadedGradient(gradient, factor).createShader(rect),
      );
    }

    band(0, 2.0, 0.55);
    band(2.0, 6.0, 0.70);
    band(6.0, edgeClear, 0.87);
    canvas.drawRRect(shapeOf(edgeClear), fill);
  }

  /// 同一份渐变、整体缩放 alpha。弹层的 tint 都是 [LinearGradient]，
  /// 其它类型直接原样返回（当前调用面只有 toast 的斜向渐变，且它不开变薄）。
  static Gradient _fadedGradient(Gradient g, double factor) {
    if (g is LinearGradient) {
      return LinearGradient(
        begin: g.begin,
        end: g.end,
        colors: <Color>[
          for (final Color c in g.colors) c.withValues(alpha: c.a * factor),
        ],
        stops: g.stops,
        tileMode: g.tileMode,
      );
    }
    return g;
  }

  @override
  bool shouldRepaint(_GlassFillPainter oldDelegate) =>
      oldDelegate.radius != radius ||
      oldDelegate.gradient != gradient ||
      oldDelegate.edgeClear != edgeClear;
}
