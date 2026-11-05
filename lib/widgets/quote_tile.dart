import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../config/app_config.dart';
import '../models/quote.dart';
import '../utils/format.dart';
import 'freshness_ticker.dart';
import 'glass.dart';

/// 单只股票的行情卡片（液态玻璃卡片）。
///
/// 卡片内部自带 ValueListenableBuilder：只有自己那一条 notifier 变化时才重建，
/// 玻璃层只重绘这一张卡，列表和外层页面都不参与。
///
/// 点击整张卡 → 打开详情弹层（今开/最高/最低/昨收/量额/交易状态）。
class QuoteTile extends StatelessWidget {
  const QuoteTile({
    super.key,
    required this.stock,
    required this.quote,
    this.onTap,
    this.now = DateTime.now,
  });

  final StockConfig stock;
  final ValueNotifier<Quote> quote;
  final VoidCallback? onTap;

  /// 可注入时钟：决定「快照」角标出不出现。
  ///
  /// 必须可注入，理由与交易时段角标相同：截图像素由它决定。
  /// 固定报价 + 真实墙钟 = 今天跑出「实时」、明天跑出「快照」，
  /// golden 会自己失效；预览里钉死一个时刻才能复现。
  final DateTime Function() now;

  /// 布局只有一个：左（名称/代码）右（价格/涨跌）。
  ///
  /// 曾经还有一个「大字体 / 窄屏切上下堆叠」的分支，已删：
  /// 1) 它触发的前提是左列有**三行**（名称/代码/时间），时间行删掉后
  ///    左列只剩两行，横向空间宽裕得多；
  /// 2) 溢出防护都在——名称/代码有省略号，价格与涨跌胶囊套 FittedBox，
  ///    放多大都只会缩小不会挤出卡片；
  /// 3) 产品决定：价格永远待在右侧原位，堆叠会把价格挤到代码下面去
  ///    （真机 2026-11-03 用户截图实证），这比「极端字体下省略号更长」
  ///    难看得多。

  @override
  Widget build(BuildContext context) {
    // 结构要点（性能）：**玻璃在监听器外面**。
    //
    // 以前 ValueListenableBuilder 包在最外层，价格每 3 秒变一次就重建整棵
    // 子树，premium 玻璃跟着重绘——而玻璃重绘 = 重新捕获背景纹理 + 跑一遍
    // 折射着色，是最贵的一步（test/paint_isolation_test.dart 用 paint 计数
    // 抓的就是这个）。
    //
    // 现在玻璃只建一次（settings/shape 都是常量），监听器下沉到内容层，
    // 外面再套一层 RepaintBoundary：价格跳动只重绘文字那一层，
    // 玻璃的着色结果原样复用。
    // 结构（性能关键）：**玻璃是背景层，内容是叠在上面的一层**。
    //
    // 试验过「把 RepaintBoundary 放进玻璃内部」，实测无效——玻璃的画笔会
    // 把子内容一起画进自己的图层，内容一变，整块玻璃（背景捕获 + 折射
    // 着色）就得重跑一遍。价格每 3 秒变一次，等于每 3 秒重捕获一次，
    // 这是列表里最贵的一笔开销。
    //
    // 拆成 Stack 后，玻璃只负责「背景 + 边沿光学」，内容在自己的图层里
    // 更新；价格跳动只重绘文字层，玻璃的着色结果原样复用。
    // test/paint_isolation_test.dart 用 paint 计数守着这条不变量。
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: GlassContainer(
            useOwnLayer: true,
            // 关键发现（2026-11-03，读包源码确认）：**standard(2D) 轻量
            // 着色器既不画 frost，也不画 rim light，更没有 3D 折射**——
            // 它只会把 frost 换成普通模糊、把 rim 换成 iOS 26 高光，
            // 所以无论怎么调 thickness/rimShade 都像一张白板。
            // 想「边缘像玻璃」必须走 premium（完整折射 + rim）。
            quality: GlassQuality.premium,
            shape: const LiquidRoundedSuperellipse(borderRadius: 28),
            settings: kGlassSurface,
            child: const SizedBox.shrink(),
          ),
        ),
        RepaintBoundary(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              splashColor: const Color(0x140F172A),
              highlightColor: const Color(0x0A0F172A),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 15, 16, 15),
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints box) {
                    return ValueListenableBuilder<Quote>(
                      valueListenable: quote,
                      builder: (BuildContext context, Quote q, Widget? _) {
                        // 新鲜度只在这里算一次，读屏语义共用；
                        // FreshnessTicker 负责在「由实时变快照」的那一刻重建
                        // （行情停了以后 notifier 不再发声，光靠它不会更新。
                        // 可见的「快照」角标已移除，重建现在只服务读屏播报）
                        return FreshnessTicker(
                          quote: q,
                          now: now,
                          builder: (BuildContext context, bool stale) {
                            return Semantics(
                              container: true,
                              button: onTap != null,
                              label: _semanticLabel(stock, q, stale),
                              hint: onTap == null
                                  ? null
                                  : '单击查看今开、最高、最低、成交量等详情',
                              child: _RowLayout(stock: stock, q: q, box: box),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 给读屏软件的一句话播报（含涨跌方向，不靠颜色传达信息）
  ///
  /// [stale] 用于说明这条报价是不是「已经不动了」：卡片上已无可见角标
  /// （2026-11-05 移除），但读屏用户仍要靠这句话知道「这不是实时价」。
  static String _semanticLabel(StockConfig stock, Quote q, bool stale) {
    if (!q.hasData) {
      return '${stock.name}，代码 ${stock.code}，等待行情';
    }
    final String direction = switch (q.trend) {
      QuoteTrend.up => '上涨',
      QuoteTrend.down => '下跌',
      QuoteTrend.flat => '持平',
    };
    final String status = q.tradingStatus.isAbnormal
        ? '，${q.tradingStatus.label}'
        : '';
    return '${stock.name}，代码 ${stock.code}，最新价 ${formatPrice(q.price)}，'
        '$direction ${formatSigned(q.changePercent, suffix: '%')}$status'
        '${stale ? '，收盘快照' : ''}';
  }
}

/// 常规布局：两行逐行对齐——第一行 名称+角标 ↔ 价格，第二行 代码 ↔ 涨跌胶囊
class _RowLayout extends StatelessWidget {
  const _RowLayout({
    required this.stock,
    required this.q,
    required this.box,
  });

  final StockConfig stock;
  final Quote q;
  final BoxConstraints box;

  /// 右列最多占内容宽度的比例。给上限后配合 FittedBox：
  /// 空间够保持原字号，不够就等比缩小，不会把左侧挤爆。
  static const double _priceMaxRatio = 0.55;

  @override
  Widget build(BuildContext context) {
    // 两行结构，左右两列逐行对齐（用户 2026-11-03 截图反馈：旧的两列各自
    // 垂直居中，左列矮右列高，名称对不上价格、代码对不上胶囊，看起来歪的）：
    //   第一行  名称+角标 ↔ 价格      （同一行内垂直居中）
    //   第二行  代码      ↔ 涨跌胶囊  （同一行内垂直居中）
    // 行距 7px 两列共享，天然对称。
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(
              child: _NameRow(stock: stock, q: q),
            ),
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: box.maxWidth * _priceMaxRatio,
              ),
              child: _ScaledPrice(q: q, alignment: Alignment.centerRight),
            ),
          ],
        ),
        const SizedBox(height: 7),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(child: _CodeText(code: stock.code)),
            const SizedBox(width: 10),
            // 必须是 Expanded 而不是 Flexible：Flexible(loose) 只占内容宽度，
            // 盒子紧跟在代码列后面——胶囊就「漂」在卡片中部，不在股价正下方
            // （用户 2026-11-03 截图实证）。Expanded 把盒子撑到行尾，
            // FittedBox 的 centerRight 再把内容贴到右缘，与上方价格的
            // 右缘对齐；内容过宽时整体缩小，不溢出。
            Expanded(
              child: _ScaledBadge(q: q, alignment: Alignment.centerRight),
            ),
          ],
        ),
      ],
    );
  }
}

/// 名称 + 市场角标 + 异常状态角标
///
/// 原来的「快照」角标已于 2026-11-05 按用户拍板移除：界面不再显示「快照」
/// 字样。「这是收盘价不是实时价」的信息改由读屏播报（`_semanticLabel` 的
/// 「收盘快照」）与详情页脚的新鲜度翻转继续承载。
class _NameRow extends StatelessWidget {
  const _NameRow({required this.stock, required this.q});

  final StockConfig stock;
  final Quote q;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Flexible(
          child: Text(
            stock.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
              color: GlassPalette.ink,
            ),
          ),
        ),
        const SizedBox(width: 6),
        // 角标组自己也必须是 Flexible：3.0x 下「SH + 异常角标」的固定宽度会
        // 超过名称行剩余空间。两个 loose flex 在正常字号下都只占自身内容宽，
        // 主轴位置与原来的裸 Row 逐像素一致；只有真放不下时才各自收缩——
        // 名称走省略号，角标整体等比缩小。
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _MarketTag(region: stock.region),
                if (q.tradingStatus.isAbnormal) ...<Widget>[
                  const SizedBox(width: 5),
                  _StatusTag(status: q.tradingStatus),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _CodeText extends StatelessWidget {
  const _CodeText({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    return Text(
      code,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        letterSpacing: 1.2,
        color: GlassPalette.inkSoft,
        fontFeatures: kTabularFigures,
      ),
    );
  }
}

/// 价格：外套 FittedBox，空间不够时等比缩小而不是溢出
class _ScaledPrice extends StatelessWidget {
  const _ScaledPrice({required this.q, required this.alignment});

  final Quote q;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: alignment,
      child: Text(
        q.hasData ? formatPrice(q.price) : '--',
        maxLines: 1,
        style: TextStyle(
          // 24 而不是 28：用户反馈原字号太喧宾夺主；名称 17、价格 24，
          // 主次还在但不再压得住整张卡
          fontSize: 24,
          height: 1.05,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.6,
          color: _accentOf(q),
          fontFeatures: kTabularFigures,
        ),
      ),
    );
  }
}

/// 涨跌胶囊：同样是 FittedBox 兜底
class _ScaledBadge extends StatelessWidget {
  const _ScaledBadge({required this.q, required this.alignment});

  final Quote q;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: alignment,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: _badgeBgOf(q),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: GlassPalette.strokeSoft),
        ),
        child: Text(
          _changeText(q),
          maxLines: 1,
          style: TextStyle(
            // 14 而不是 12：用户反馈字太小；与代码同字号但 w600 更重，
            // 胶囊在第二行和代码平起平坐
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.1,
            color: _accentOf(q),
            fontFeatures: kTabularFigures,
          ),
        ),
      ),
    );
  }
}

Color _accentOf(Quote q) => switch (q.trend) {
  QuoteTrend.up => GlassPalette.up,
  QuoteTrend.down => GlassPalette.down,
  QuoteTrend.flat => GlassPalette.flat,
};

/// 涨跌胶囊底色：同色低透明度，玻璃上依然能透出背景
Color _badgeBgOf(Quote q) => switch (q.trend) {
  QuoteTrend.up => const Color(0x1FE03A2F),
  QuoteTrend.down => const Color(0x1F0E9F5B),
  QuoteTrend.flat => const Color(0x14000000),
};

/// "+0.45  +1.23%"
String _changeText(Quote q) {
  if (!q.hasData) {
    return '--';
  }
  return '${formatSigned(q.change)}  '
      '${formatSigned(q.changePercent, suffix: '%')}';
}

/// 市场角标：SH / SZ
class _MarketTag extends StatelessWidget {
  const _MarketTag({required this.region});

  final String region;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0x1F0F172A),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        region,
        style: const TextStyle(
          fontSize: 9,
          height: 1.3,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: GlassPalette.inkSoft,
        ),
      ),
    );
  }
}

/// 异常交易状态角标（停牌 / 已退市 / 熔断）——越显性越好，别让人猜为什么价格不动
class _StatusTag extends StatelessWidget {
  const _StatusTag({required this.status});

  final TradingStatus status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0x2EFFB020),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        status.label,
        style: const TextStyle(
          fontSize: 9,
          height: 1.3,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
          color: Color(0xFF8A5A00),
        ),
      ),
    );
  }
}
