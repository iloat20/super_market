import 'dart:math' as math;

import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:material_ui/material_ui.dart';

import '../config/app_config.dart';
import '../models/kline.dart';
import '../models/quote.dart';
import '../services/kline_loader.dart';
import '../services/quote_feeds.dart';
import '../utils/beijing_clock.dart';
import '../utils/format.dart';
import 'freshness_ticker.dart';
import 'glass.dart';
import 'hit_target.dart';
import 'kline_chart.dart';

/// 弹出某只股票的行情详情（液态玻璃底部弹层）。
///
/// 数据来源两路，互不影响：
/// - 八项指标全部来自已有的 quote 轮询，**不新增订阅**；
/// - 走势图（分时 / 日 K）在打开弹层时才拉一次，失败只是少一块，不影响指标。
///
/// 弹层内部同样是 ValueListenableBuilder：打开着的时候行情继续实时跳动，
/// 走势图的最后一根/最后一个点也跟着用实时价补，避免「头部在跳、图上不动」。
Future<void> showQuoteDetailSheet(
  BuildContext context, {
  required StockConfig stock,
  required ValueNotifier<Quote> quote,
  KlineLoader? loader,
  DateTime Function() now = beijingNow,
  /// 来源名取自**调用方运行期**的 feed（`QuoteFeed.sourceLabel`）。
  ///
  /// 用 getter 而不是 String：主备切换可能在弹层打开期间发生，而页脚是
  /// 跟着行情一起重建的——每次 build 现取，才不会显示一个打开瞬间的快照。
  /// 默认值是编译期常量，仅为让既有测试不必改签名。
  String Function() sourceLabel = _defaultSourceLabel,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    // 遮罩 24% → 15% → 10%（A05）：遮罩越重，面板越灰，小字越不可能达标。
    // 10% 仍然把背后的列表压退一层（色相还在，但看不出内容），
    // 而面板能升到 L≈0.79 —— 4.5:1 的前提在这里，不在字的颜色里。
    barrierColor: const Color(0x1A0B1220),
    isScrollControlled: true,
    useSafeArea: true,
    builder: (BuildContext context) => _QuoteDetailSheet(
      stock: stock,
      quote: quote,
      loader: loader,
      now: now,
      sourceLabel: sourceLabel,
    ),
  );
}

/// 没有传 feed 时的兜底：编译期的主力源名（与旧行为一致）
String _defaultSourceLabel() => QuoteFeeds.label;

class _QuoteDetailSheet extends StatefulWidget {
  const _QuoteDetailSheet({
    required this.stock,
    required this.quote,
    this.loader,
    this.now = beijingNow,
    this.sourceLabel = _defaultSourceLabel,
  });

  final StockConfig stock;
  final ValueNotifier<Quote> quote;

  /// 只在测试里注入；生产走默认的 [KlineLoader]（真网 + 30s 缓存）
  final KlineLoader? loader;

  /// 可注入时钟：页脚「收盘快照 / 实时推送」由它算新鲜度，预览要能复现
  final DateTime Function() now;

  /// 运行期来源名（主备切换后会变）
  final String Function() sourceLabel;

  @override
  State<_QuoteDetailSheet> createState() => _QuoteDetailSheetState();
}

class _QuoteDetailSheetState extends State<_QuoteDetailSheet> {
  late final KlineLoader _loader = widget.loader ?? KlineLoader();

  /// 美股默认打开**日 K**：分时在免费源上只有盘中可能有数据（收盘时段必空，
  /// 见 README 二·三十三），打开就撞一个注定失败的占位毫无意义；日 K 是
  /// 唯一被真网探针证实稳定可用的美股走势。A/H 维持分时优先。
  /// （late 初始化器延迟到首次访问，可以读 [widget]；美股的分时 tab 不渲染，
  /// _switchMode 实际不会被调到 intraday。）
  late ChartMode _mode = widget.stock.region == 'US'
      ? ChartMode.daily
      : ChartMode.intraday;

  KlineResult<Kline>? _daily;
  KlineResult<IntradayPoint>? _intraday;
  bool _loading = true;
  String? _error;

  // ==================== 走势补丁的记忆化 ====================
  //
  // `patchTodayBar` / `patchLatestPrice` 每次调用都返回**新 List**，而
  // `_KlinePainter.shouldRepaint` 用的是 `identical`（见 kline_chart.dart）。
  // 直接调用的后果：一条"只有成交额变了"的报文（盘口常态）也会让日 K 每 3 秒
  // 全量重栅格化一次——240~480 根蜡烛 + 两条 MA + 同数量柱，全部白画。
  //
  // 键必须**恰好**是补丁函数的输入集：多一个字段（比如 turnover）会让缓存
  // 永远不命中，少一个（比如 high）会画出上一笔的影线。

  List<Kline> _bars = const <Kline>[];
  List<Kline> _barsSrc = const <Kline>[];
  Quote? _barsFor;

  List<IntradayPoint> _points = const <IntradayPoint>[];
  List<IntradayPoint> _pointsSrc = const <IntradayPoint>[];
  Quote? _pointsFor;

  /// 当日日线序列（含由实时报价拼出的今日那根），输入没变就复用同一个 List。
  List<Kline> _patchedBars(Quote q) {
    final List<Kline> src = _daily?.items ?? const <Kline>[];
    final Quote? previous = _barsFor;
    if (identical(src, _barsSrc) &&
        previous != null &&
        previous.price == q.price &&
        previous.timestamp == q.timestamp &&
        previous.open == q.open &&
        previous.high == q.high &&
        previous.low == q.low &&
        previous.volume == q.volume) {
      return _bars;
    }
    _barsSrc = src;
    _barsFor = q;
    return _bars = patchTodayBar(src, q);
  }

  /// 分时点序列（末点被实时价覆盖），输入没变就复用同一个 List。
  List<IntradayPoint> _patchedPoints(Quote q) {
    final List<IntradayPoint> src = _intraday?.items ?? const <IntradayPoint>[];
    final Quote? previous = _pointsFor;
    if (identical(src, _pointsSrc) &&
        previous != null &&
        previous.price == q.price &&
        previous.timestamp == q.timestamp) {
      return _points;
    }
    _pointsSrc = src;
    _pointsFor = q;
    return _points = patchLatestPrice(src, q);
  }

  /// 详情内容的滚动位置：驱动顶部磨砂玻璃带的浮出（见 [_DetailScrollBody]）。
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final ChartMode asked = _mode;
    setState(() {
      _loading = true;
      _error = null;
    });

    if (asked == ChartMode.intraday) {
      final KlineResult<IntradayPoint> r = await _loader.loadIntraday(
        widget.stock,
      );
      if (!mounted || _mode != asked) {
        return; // 用户已经切走了，别用旧结果覆盖新图
      }
      setState(() {
        _intraday = r;
        _loading = false;
        _error = r.error;
      });
    } else {
      final KlineResult<Kline> r = await _loader.loadDaily(widget.stock);
      if (!mounted || _mode != asked) {
        return;
      }
      setState(() {
        _daily = r;
        _loading = false;
        _error = r.error;
      });
    }
  }

  void _switchMode(ChartMode mode) {
    if (mode == _mode) {
      return;
    }
    final bool cached = mode == ChartMode.intraday
        ? _intraday != null
        : _daily != null;
    setState(() {
      _mode = mode;
      _error = null;
    });
    if (!cached) {
      _load();
    }
  }

  void _retry() {
    _loader.clear(); // 手动重试要绕开 30s 缓存，否则点了没反应
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // 平板/横屏下不让弹层拉满整行，保持阅读宽度
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 520,
            // 加了走势图之后弹层会超过小屏（360×640）的可视高度，
            // 不设上限会直接 RenderFlex overflow —— 内容本身不该被裁，
            // 所以给高度上限 + 可滚动，而不是缩小图表。
            maxHeight: MediaQuery.sizeOf(context).height * 0.86,
          ),
          // v15：详情弹层的玻璃换成**卡片那一套** —— `GlassContainer.card`
          // + `kGlassSurface` premium，不再用自绘 `GlassPanel`
          // （`BackdropFilter` + 白膜 + GlassRim）。结构和 quote_tile.dart
          // 完全一致：玻璃只当背景层，内容在 Stack 的另一层并用
          // RepaintBoundary 隔开，3 秒一次的跳价不会重跑背景捕获。
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(30),
              boxShadow: const <BoxShadow>[
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
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(30),
              child: Stack(
                children: <Widget>[
                  // ① 底色膜：v14 指定的 `#D3DFD3`，留 7% 透。
                  //    v15 首版给的是 72%，真机上压不住背后的列表文字
                  //    ——弹层里的「今开/成交量」和列表价格叠成一片，
                  //    没法读。`kGlassSurface` 是为压在纯色背景上的卡片
                  //    调的（白纱清零 + frost 0），搬到压着内容的弹层上
                  //    几乎全透；所以可读性要由这层底色膜兜住，而不是
                  //    改卡片的材质参数。7% 透仍留一点结构给着色器，
                  //    边缘的折射 / rim light / 色散照样看得见。
                  Positioned.fill(
                    child: ColoredBox(
                      color: GlassPalette.background.withValues(alpha: 0.93),
                    ),
                  ),
                  // ② 卡片玻璃：同一入口、同一材质、同一套 premium 光学
                  //    （折射 / rim light / 暗发丝边 / 色散）。
                  Positioned.fill(
                    child: GlassContainer.card(
                      useOwnLayer: true,
                      quality: GlassQuality.premium,
                      shape: const LiquidRoundedSuperellipse(
                        borderRadius: 30,
                      ),
                      settings: kGlassSurface,
                      padding: EdgeInsets.zero,
                      surfaceStyle: GlassSurfaceStyle.glass,
                      child: const SizedBox.shrink(),
                    ),
                  ),
                  // ③ 内容：与玻璃平级、自带独立图层。
                  //    Stack 的尺寸由这个非 positioned 子节点决定。
                  RepaintBoundary(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
                      child: ValueListenableBuilder<Quote>(
                        valueListenable: widget.quote,
                        builder: (BuildContext context, Quote q, Widget? _) {
                          return _DetailScrollBody(
                            controller: _scrollController,
                            // 整棵内容树在这里建好、交给 AnimatedBuilder
                            // 的 child 缓存：滚动每帧只重建 Stack + 顶部
                            // 那条带，图表/指标一概不碰。
                            body: _body(context, q),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 弹层内容（两种外壳共用）。
  Widget _body(BuildContext context, Quote q) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Center(child: _Handle()),
        const SizedBox(height: 10),
        _Header(stock: widget.stock, quote: q),
        const SizedBox(height: 12),
        _ChartSection(
          mode: _mode,
          region: widget.stock.region,
          onModeChanged: _switchMode,
          // 只把当前形态要用的那份传下去：报价每 3 秒跳一次，
          // 两个模式的数据都做一遍补丁是白算。
          //
          // 走 `_patched*` 而不是直接调 `patch*`：只有"真的变了"
          // 才允许产生新 List，否则日 K 的 RepaintBoundary 光栅
          // 缓存每 3 秒失效一次（判据是 identical，见 kline_chart）。
          bars: _mode == ChartMode.daily
              ? _patchedBars(q)
              : const <Kline>[],
          points: _mode == ChartMode.intraday
              ? _patchedPoints(q)
              : const <IntradayPoint>[],
          prevClose: q.previousClose,
          loading: _loading,
          error: _error,
          sourceId:
              (_mode == ChartMode.intraday
                  ? _intraday?.sourceId
                  : _daily?.sourceId) ??
              '',
          onRetry: _retry,
        ),
        const SizedBox(height: 16),
        _Metrics(
          quote: q,
          region: widget.stock.region,
          now: widget.now,
        ),
        const SizedBox(height: 14),
        _StatusRow(
          quote: q,
          now: widget.now,
          sourceLabel: widget.sourceLabel,
        ),
      ],
    );
  }
}

/// 磨砂带从 0 浮到完全显现所需的滚动距离。
///
/// 28dp 是「刚好盖过拖拽条 + 标题下行」的距离：再长，用户已经滚走小半屏
/// 头部才立起来；再短，手指一碰就跳出一根白边。
const double _kScrimFadeRange = 28;

/// 详情内容 + 顶部滚动感应的玻璃带。
///
/// 结构是刻意的：滚动视图是 Stack 的**非定位子节点**，它收到的约束与原来
/// 直接放在 `GlassPanel` 里完全一致 —— 静止态（offset=0）多一个子层都不会
/// 进树，golden 零变化；磨砂带是定位子节点，只在 offset>0 时才出现。
///
/// `AnimatedBuilder` 监听的是 `ScrollController`（ChangeNotifier），并把整棵
/// 内容树放进 `child` 缓存：滚动只重建这一个 Stack 和一条 30dp 的带，不会
/// 连带重建 `_body`（图表、指标、状态行），也不会碰外层 sigma=18 的
/// `BackdropFilter`。
class _DetailScrollBody extends StatelessWidget {
  const _DetailScrollBody({required this.controller, required this.body});

  final ScrollController controller;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      child: SingleChildScrollView(controller: controller, child: body),
      builder: (BuildContext context, Widget? scrollView) {
        final double offset = controller.hasClients ? controller.offset : 0.0;
        final double progress = (offset / _kScrimFadeRange).clamp(0.0, 1.0);
        return Stack(
          children: <Widget>[
            scrollView!,
            if (progress > 0)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: _DetailHeaderScrim(
                    key: const Key('detailHeaderScrim'),
                    progress: progress,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 顶部磨砂带：随滚动量线性浮出，底边一根发丝高光把「栏」立住。
///
/// 与自绘 `GlassRim` 同一套语言：靠**边缘**而不是靠一大片白来说明这里有
/// 一块玻璃。刻意**不加第二层 BackdropFilter** —— 外层 `GlassPanel` 已经做
/// 了一次 sigma=18 的全面板模糊，再套一层会在滚动时每帧重跑模糊（列表侧
/// 和弹层侧都踩过这个坑）。这里只有一层确定性渐变 + 描边，纯几何绘制、
/// 逐像素可复现，不产生 saveLayer。
class _DetailHeaderScrim extends StatelessWidget {
  const _DetailHeaderScrim({super.key, required this.progress});

  /// 0 = 完全不画，1 = 完全浮出。
  final double progress;

  @override
  Widget build(BuildContext context) {
    // v13：磨砂带必须跟弹层同色，否则在豆腐色面板上滚动时会浮出一条白带。
    const Color scrim = GlassPalette.background;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            scrim.withValues(alpha: 0.88 * progress),
            scrim.withValues(alpha: 0.52 * progress),
            scrim.withValues(alpha: 0.0),
          ],
          stops: const <double>[0, 0.55, 1],
        ),
        border: Border(
          bottom: BorderSide(
            color: scrim.withValues(alpha: 0.92 * progress),
            width: 0.8,
          ),
        ),
      ),
      child: const SizedBox(height: 30),
    );
  }
}

/// 走势图区块：上面是「分时 / 日K」切换 + 数据来源，下面是图。
class _ChartSection extends StatelessWidget {
  const _ChartSection({
    required this.mode,
    required this.region,
    required this.onModeChanged,
    required this.bars,
    required this.points,
    required this.prevClose,
    required this.loading,
    required this.error,
    required this.sourceId,
    required this.onRetry,
  });

  final ChartMode mode;

  /// 市场代码（`HK` = 港股）：分时轴 330 分钟、刻度到 16:00
  final String region;
  final ValueChanged<ChartMode> onModeChanged;
  final List<Kline> bars;
  final List<IntradayPoint> points;
  final double prevClose;
  final bool loading;
  final String? error;
  final String sourceId;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final bool empty = mode == ChartMode.intraday
        ? points.length < 2
        : bars.isEmpty;

    // 美股：走势不可用就**直接不显示**（2026-11-05 用户拍板）。A/H 的
    // 「点此重试」占位对美股不适用——分时收盘必空是常态而非故障，一个
    // 永远修不好的重试按钮只会让人怀疑 App 坏了。日 K 是美股唯一的
    // 走势 tab（分时没有入口），它也拿不到数据时整块收起，详情页只剩
    // 头部 + 指标。loading 期间照常出骨架：短暂且语义正确。
    if (region == 'US' && !loading && (empty || error != null)) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            // 两个 tab 的余量各自朝外侧扩，避免互相盖住对方的点击区。
            // 美股没有分时 tab（收盘时段必空，见上方注释），只留日 K。
            if (region != 'US')
              HitTarget(
                alignment: Alignment.centerRight,
                child: _Segment(
                  mode: ChartMode.intraday,
                  current: mode,
                  onTap: onModeChanged,
                ),
              ),
            if (region != 'US') const SizedBox(width: 6),
            HitTarget(
              alignment: Alignment.centerLeft,
              child: _Segment(
                mode: ChartMode.daily,
                current: mode,
                onTap: onModeChanged,
              ),
            ),
            const Spacer(),
            // 走势源单独标出来：主备切换是静默的，图换源了得能看见
            if (sourceId.isNotEmpty)
              Text(
                sourceId == 'sina' ? '新浪' : '腾讯',
                style: const TextStyle(
                  fontSize: 9.5,
                  color: GlassPalette.inkSoft,
                  letterSpacing: 0.2,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: KlineChart.height,
          child: loading
              ? const _ChartSkeleton()
              : (empty || error != null)
              ? _ChartError(error: error, onRetry: onRetry)
              : _ChartFade(
                  mode: mode,
                  child: KlineChart(
                    mode: mode,
                    bars: bars,
                    points: points,
                    prevClose: prevClose,
                    region: region,
                  ),
                ),
        ),
      ],
    );
  }
}

/// 切图时的一次性淡入。
///
/// ## 为什么不是 `AnimatedSwitcher` 的默认交叉淡化
///
/// 图表是重绘大户（`CustomPaint` + 几百根蜡烛）。交叉淡化意味着过渡期间
/// **两张图同时在树上**，raster 直接翻倍；而这是个 120ms、用户点一下才发生
/// 的过渡，翻倍的那几帧最容易掉帧。所以这里让旧图立刻消失、新图淡入——
/// 观感上是"换了一张"，不是"两张叠化"，代价只有一次 `saveLayer`。
///
/// ## 为什么用 `key: ValueKey(mode)`
///
/// `TweenAnimationBuilder` 换 key 等于换 State：新图从 0 重新淡入，
/// 旧图直接销毁。不做这个，切回分时的时候会停在上一次的值上不重播。
///
/// 稳态零成本：`Opacity` 在 1.0 时会跳过 `saveLayer`，动画结束就不再有开销。
class _ChartFade extends StatelessWidget {
  const _ChartFade({required this.mode, required this.child});

  final ChartMode mode;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 与 tab 胶囊、太极一致：系统开了「减少动态效果」就直接出终态。
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      key: ValueKey<ChartMode>(mode),
      tween: Tween<double>(begin: 0, end: 1),
      duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      builder: (BuildContext context, double t, Widget? child) =>
          Opacity(opacity: t, child: child),
      child: child,
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.mode,
    required this.current,
    required this.onTap,
  });

  final ChartMode mode;
  final ChartMode current;
  final ValueChanged<ChartMode> onTap;

  @override
  Widget build(BuildContext context) {
    final bool selected = mode == current;
    // 系统开启「减少动态效果」时取消 tab 切换的颜色/阴影过渡。
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    return GestureDetector(
      onTap: () => onTap(mode),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? const Color(0xE6FFFFFF) : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: selected ? GlassPalette.stroke : GlassPalette.strokeSoft,
          ),
          boxShadow: selected
              ? const <BoxShadow>[
                  BoxShadow(
                    color: GlassPalette.shadowSoft,
                    blurRadius: 6,
                    offset: Offset(0, 1),
                  ),
                ]
              : null,
        ),
        child: Text(
          mode.label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? GlassPalette.ink : GlassPalette.inkSoft,
          ),
        ),
      ),
    );
  }
}

/// 加载态的骨架。
///
/// **刻意不放 `CircularProgressIndicator`**：它是无限动画，会让任何
/// `pumpAndSettle()` 永远等不到静止（既有用例就是这么崩的）。而且它在这个
/// 场景本来就没必要——数据通常 200~400ms 就回来了，转圈只会闪一下。
/// 用一块静态的淡底 + 一行小字，既稳又不闪。
class _ChartSkeleton extends StatelessWidget {
  const _ChartSkeleton();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x070F172A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Center(
        child: Text(
          '加载走势…',
          style: TextStyle(
            fontSize: 10,
            color: GlassPalette.inkSoft,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}

/// 失败态：一行小字 + 点一下重试。走势图是装饰性数据，不值得弹错误对话框。
class _ChartError extends StatelessWidget {
  const _ChartError({required this.error, required this.onRetry});

  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onRetry,
      behavior: HitTestBehavior.opaque,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.show_chart_rounded,
              size: 18,
              color: GlassPalette.inkSoft,
            ),
            const SizedBox(height: 4),
            Text(
              error == null ? '暂无走势数据' : '走势暂不可用 · 点此重试',
              style: const TextStyle(
                fontSize: 10.5,
                color: GlassPalette.inkSoft,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 顶部小拖拽条（纯视觉，滚动由内容高度决定）
class _Handle extends StatelessWidget {
  const _Handle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 4,
      decoration: BoxDecoration(
        color: const Color(0x330F172A),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.stock, required this.quote});

  final StockConfig stock;
  final Quote quote;

  @override
  Widget build(BuildContext context) {
    final Color accent = _accentOf(quote);
    // 34px 的价格是「显示型数字」，不是正文。跟满 3.0x 会变成一行 102px 高、
    // 三百多 px 宽，只能在字符中间折行（"143" / "9.10" / "0"）——比小一点更难读。
    // 限到 1.3x：仍然放大，但保证它始终是一整个数字。正文小字不设上限。
    final TextScaler displayScale = MediaQuery.textScalerOf(context)
        .clamp(maxScaleFactor: 1.3);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // 名称和代码用 Wrap 而不是 Row：够宽时排在同一行、间距同为 8px
        // （单行时布局结果与 Row 逐像素一致），不够时整块换行，
        // 而不是被 RenderFlex 直接裁掉右侧。
        Wrap(
          spacing: 8,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Text(
              stock.name,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
                color: GlassPalette.ink,
              ),
            ),
            Text(
              '${stock.code} · ${stock.region}',
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.6,
                color: GlassPalette.inkSoft,
                fontFeatures: kTabularFigures,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: <Widget>[
            Text(
              quote.hasData ? formatPrice(quote.price) : '--',
              textScaler: displayScale,
              style: TextStyle(
                fontSize: 34,
                height: 1,
                fontWeight: FontWeight.w700,
                letterSpacing: -1.1,
                color: accent,
                fontFeatures: kTabularFigures,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                quote.hasData
                    ? '${formatSigned(quote.change)}  '
                          '${formatSigned(quote.changePercent, suffix: '%')}'
                    : '--',
                textScaler: displayScale,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: accent,
                  fontFeatures: kTabularFigures,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 八宫格指标：今开 / 最高 / 最低 / 昨收 / 成交量 / 成交额 / 振幅 / 更新时间
class _Metrics extends StatelessWidget {
  const _Metrics({
    required this.quote,
    required this.region,
    required this.now,
  });

  final Quote quote;

  /// 「更新时间」要靠它判断是不是跨天：只写 `15:35:45` 的话，早上 9 点看到
  /// 的昨收价会被读成今早的价（真机 2026-11-05 09:01 的误读现场）。
  final DateTime Function() now;

  /// 港/美股时成交额标注币种——A 股是人民币不用标，港股是港币、美股是
  /// 美元，不标的话「成交额 5.4 亿」会被读成人民币，差了 17%（美股差 7 倍）。
  final String region;

  @override
  Widget build(BuildContext context) {
    final Quote q = quote;
    final List<Widget> cells = <Widget>[
      _Metric(
        label: '今开',
        value: q.open > 0 ? formatPrice(q.open) : '--',
        color: _relative(q.open, q.previousClose),
        note: noteFor(q.open, q.previousClose),
      ),
      _Metric(
        label: '最高',
        value: q.high > 0 ? formatPrice(q.high) : '--',
        color: _relative(q.high, q.previousClose),
        note: noteFor(q.high, q.previousClose),
      ),
      _Metric(
        label: '最低',
        value: q.low > 0 ? formatPrice(q.low) : '--',
        color: _relative(q.low, q.previousClose),
        note: noteFor(q.low, q.previousClose),
      ),
      _Metric(
        label: '昨收',
        value: q.previousClose > 0 ? formatPrice(q.previousClose) : '--',
      ),
      _Metric(
        label: '成交量',
        value: q.volume > 0 ? formatCompact(q.volume) : '--',
      ),
      _Metric(
        label: switch (region) {
          'HK' => '成交额 (HKD)',
          'US' => '成交额 (USD)',
          _ => '成交额',
        },
        value: q.turnover > 0 ? formatCompact(q.turnover) : '--',
      ),
      _Metric(
        label: '振幅',
        value: q.amplitude > 0 ? '${q.amplitude.toStringAsFixed(2)}%' : '--',
      ),
      _Metric(label: '更新时间', value: formatUpdateTime(q.timestamp, now())),
    ];
    // 两列时每格只有 (面板宽 − 12) / 2 ≈ 157dp。「1486.00」15.5px 放大到
    // 3.0x 要 300dp 以上，单格放不下就只剩「149…」——不溢出，可主要信息没了。
    // 放大到单格装不下一整个价格（约 1.55x）时改单列：8 行，弹层本来可滚动。
    // 两列时每格只有 (面板宽 − 12) / 2 ≈ 157dp。「1486.00」15.5px 放大到
    // 3.0x 要 300dp 以上，单格放不下就只剩「149…」——不溢出，可主要信息没了。
    // 放大到单格装不下一整个价格（约 1.55x）时改单列：8 行，弹层本来可滚动。
    final bool singleColumn = MediaQuery.textScalerOf(context).scale(15.5) > 24;
    final int columns = singleColumn ? 1 : 2;
    final List<Widget> rows = <Widget>[];
    for (int i = 0; i < cells.length; i += columns) {
      if (i > 0) {
        rows.add(const SizedBox(height: 12));
      }
      rows.add(_row(cells.sublist(i, math.min(i + columns, cells.length))));
    }
    return Column(children: rows);
  }

  static Widget _row(List<Widget> cells) {
    if (cells.length == 1) {
      return Row(children: <Widget>[Expanded(child: cells.first)]);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(child: cells[0]),
        const SizedBox(width: 12),
        Expanded(child: cells[1]),
      ],
    );
  }

  /// 相对昨收上色：高于昨收红、低于昨收绿（A 股习惯），昨收缺失时中性
  static Color _relative(double value, double prevClose) {
    if (value <= 0 || prevClose <= 0) {
      return GlassPalette.ink;
    }
    if (value > prevClose) {
      return GlassPalette.up;
    }
    if (value < prevClose) {
      return GlassPalette.down;
    }
    return GlassPalette.ink;
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    this.color,
    this.note,
  });

  final String label;
  final String value;
  final Color? color;

  /// 方向词（A10）：`高于昨收` / `低于昨收` / `与昨收持平`，没有可比对象时为 null。
  ///
  /// 必须是**可见文字**，不能只放进 `Semantics`：红绿色盲、灰度截图、强光下
  /// 的屏幕都读不到颜色，而读屏用户反而只是其中一小部分。
  final String? note;

  /// 指标值的统一样式：等宽数字，避免 3 秒一跳的价把整行宽度带着抖。
  static TextStyle _valueStyle(Color? color) => TextStyle(
    fontSize: 15.5,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    color: color ?? GlassPalette.ink,
    fontFeatures: kTabularFigures,
  );

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label $value${note == null ? '' : '，$note'}',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                letterSpacing: 0.2,
                color: GlassPalette.inkSoft,
              ),
            ),
            const SizedBox(height: 3),
            // 宁可整体缩一点，也不要把「07:52:10」截成「07:52…」——
            // 时间少一段等于一个错的时间。1.0x 与常规字号下不触发缩放
            // （child 本来就在约束内），像素不变。
            //
            // 例外：带空格的值（跨天更新时间 `11-03 07:52`）在 3.0x 下整行
            // 放不下，等比缩到 64% 已经不算「跟随系统字体」了。这种值有天然
            // 断行点，交给 Text 自己折成两行：放得下时不折，1.0x 逐像素不变。
            // 单段数字（`1486.00`）没有断行点，仍走 FittedBox 等比缩小。
            if (value.contains(' '))
              Text(
                value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: _valueStyle(color),
              )
            else
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value, maxLines: 1, style: _valueStyle(color)),
              ),
            if (note != null) ...<Widget>[
              const SizedBox(height: 1),
              Text(
                note!,
                style: const TextStyle(
                  fontSize: 9.5,
                  height: 1.25,
                  letterSpacing: 0.1,
                  color: GlassPalette.inkSoft,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 底部状态：交易状态（停牌/熔断这类异常显性化）+ 行情来源说明
class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.quote,
    required this.now,
    required this.sourceLabel,
  });

  final Quote quote;
  final DateTime Function() now;

  /// 运行期来源名（主备切换后会变）
  final String Function() sourceLabel;

  @override
  Widget build(BuildContext context) {
    // 弹层开着跨过判决线时也要自己翻（行情停了不再 notify，
    // 只靠 ValueListenableBuilder 会一直停在「轮询更新」）
    return FreshnessTicker(
      quote: quote,
      now: now,
      builder: (BuildContext context, bool stale) => _buildRow(context, stale),
    );
  }

  Widget _buildRow(BuildContext context, bool stale) {
    final TradingStatus status = quote.tradingStatus;
    final bool abnormal = status.isAbnormal;
    // 3.0x 下胶囊本身就要 190dp，剩给来源的只有 128dp —— 11 个字怎么折
    // 都放不下。Wrap + spaceBetween：够宽时胶囊贴左、来源贴右（1.0x 下
    // 位置与原来的 Row + Expanded 逐像素一致），不够时来源换到下一行。
    return SizedBox(
      // Wrap 本身会收缩到内容宽（Row 是撑满的），不撑满的话 spaceBetween
      // 会把「轮询更新 · 新浪财经」的右边缘从 326 挪到 196。
      width: double.infinity,
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              // 8% → 6% 墨：胶囊底比面板暗一档，每多 1% 就从 11px 文字的
              // 对比度里扣一点。12% 时「正常交易」只有 3.2:1（A05 实测）。
              color: abnormal
                  ? const Color(0x2EFFB020)
                  : const Color(0x0F000000),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: GlassPalette.strokeSoft),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  abnormal
                      ? Icons.error_outline_rounded
                      : Icons.check_circle_outline_rounded,
                  size: 12,
                  color: abnormal
                      ? const Color(0xFF8A5200)
                      : GlassPalette.inkSoft,
                ),
                const SizedBox(width: 4),
                Text(
                  status.label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: abnormal
                        ? const Color(0xFF8A5200)
                        : GlassPalette.inkSoft,
                  ),
                ),
              ],
            ),
          ),
          Text(
            // 来源必须说清楚。2026-11-05 用户拍板：界面不再显示「快照」字样，
            // stale 时只留来源名；「轮询更新 ↔ 只留来源」的翻转仍在——盘中
            // 看得见「在动」，收盘后只剩来源（配合页头交易时段角标一起读）。
            //
            // 「实时推送」这个词名不副实：链路是 3 秒 HTTP 轮询
            // （AppConfig.pollInterval），没有任何推送通道。改成「轮询更新」。
            // 不写死「3 秒」是因为失败退避会把间隔翻倍到 pollBackoffMax，
            // 那正是最需要说清楚「多久更新一次」的时候，写死反而说错。
            stale ? sourceLabel() : '轮询更新 · ${sourceLabel()}',
            textAlign: TextAlign.end,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: GlassPalette.inkSoft),
          ),
        ],
      ),
    );
  }
}

Color _accentOf(Quote q) => switch (q.trend) {
  QuoteTrend.up => GlassPalette.up,
  QuoteTrend.down => GlassPalette.down,
  QuoteTrend.flat => GlassPalette.flat,
};
