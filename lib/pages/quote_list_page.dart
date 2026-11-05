import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
// 只剩列表玻璃组（GlassBackdropGroup）还在用：页头那块玻璃已经拆掉
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../config/app_config.dart';
import '../models/quote.dart';
import '../services/kline_loader.dart';
import '../services/local_store.dart';
import '../services/quote_feed.dart';
import '../services/quote_feeds.dart';
import '../services/symbol_directory.dart';
import '../services/watchlist_repository.dart';
import '../utils/format.dart';
import '../utils/frame_rate.dart';
import '../utils/haptics.dart' as haptics;
import '../utils/lifecycle_pause.dart';

import '../widgets/glass.dart';
import '../widgets/hit_target.dart';
import '../widgets/market_session_badge.dart';
import '../widgets/quote_detail_sheet.dart';
import '../widgets/quote_tile.dart';
import '../widgets/taiji_mark.dart';
import '../widgets/watchlist_sheet.dart';

/// 行情列表页（液态玻璃视觉）。
///
/// 刷新策略不变：
/// - 每只股票一个 `ValueNotifier<Quote>`，卡片内 ValueListenableBuilder 局部刷新；
/// - 页面只在「首次挂载」和「生命周期切换」时变化，全程不 setState 列表。
class QuoteListPage extends StatefulWidget {
  const QuoteListPage({
    super.key,
    this.serviceBuilder,
    this.watchlistRepository,
    this.symbolDirectory,
    this.clock,
    this.klineLoader,
  });

  /// 仅测试使用：注入自定义服务实例。
  ///
  /// 为什么需要它：widget 测试一旦走默认构造就会真的发起网络轮询——
  /// 测试变成依赖外网、依赖机器网络状况，既慢又不确定。
  /// 注入后测试可以用一个不联网的假 feed，UI 行为与网络彻底解耦。
  ///
  /// 生产环境不传，走默认构造。
  final QuoteFeed Function(ValueChanged<List<Quote>> onQuotes)? serviceBuilder;

  /// 仅测试使用：注入订阅存档（默认落磁盘）
  final WatchlistRepository? watchlistRepository;

  /// 仅测试使用：注入股票目录（默认走 REST + 磁盘缓存）
  final SymbolDirectory? symbolDirectory;

  /// 仅测试使用：钉住「现在几点」。
  ///
  /// 交易时段角标的文字会进截图，读墙钟就会让 golden 随时间自己失效
  /// （08:30 是「盘前」、09:20 是「集合竞价」），预览必须能复现。
  final DateTime Function()? clock;

  /// 组合根下发的走势取数器：生产路径由 `main()` 注入，测试可不传。
  /// 不传时详情弹层仍走自己的默认 loader（保留兜底，测试零改动）。
  final KlineLoader? klineLoader;

  @override
  State<QuoteListPage> createState() => _QuoteListPageState();
}

class _QuoteListPageState extends State<QuoteListPage>
    with WidgetsBindingObserver {
  /// 「代码$市场」→ 该股票行情的 notifier。
  ///
  /// 键必须带市场：`000001` 在深市是平安银行、在沪市是上证指数，
  /// 只按代码做键会把两只完全不同的标的挤进同一张卡。
  final Map<String, ValueNotifier<Quote>> _notifiers =
      <String, ValueNotifier<Quote>>{};

  /// 当前订阅列表（可在 App 内修改，因此不再是编译期常量）
  List<StockConfig> _stocks = AppConfig.stocks;

  late final QuoteFeed _service;
  late final WatchlistRepository _watchlist;
  late final SymbolDirectory _directory;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 初始建表与"用户改订阅"走同一条路径：**只有一份实现**，不会再次出现
    // 「一处 putIfAbsent、一处覆盖」那种两个版本漂移的问题。
    _syncNotifiers();

    _service =
        widget.serviceBuilder?.call(_onQuotes) ??
        QuoteFeeds.create(onQuotes: _onQuotes);
    _watchlist =
        widget.watchlistRepository ?? WatchlistRepository(FileKeyValueStore());
    _directory =
        widget.symbolDirectory ?? SymbolDirectory(store: FileKeyValueStore());

    // 首帧之后再启动：避免建连/读盘异常影响首屏
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_bootstrap());
      }
    });
  }

  /// 启动顺序：读订阅存档 → 启动轮询。
  Future<void> _bootstrap() async {
    final List<StockConfig> saved = await _watchlist.load();
    if (!mounted) {
      return;
    }
    if (!_sameStocks(saved, _stocks)) {
      setState(() {
        _stocks = saved;
        _syncNotifiers();
      });
      _service.updateStocks(saved);
    }
    _service.connect();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // 场景 A：只在前台盯盘 → 进后台主动断开，不做任何后台保活
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _service.pause();
    } else if (state == AppLifecycleState.resumed) {
      // 回前台：立即恢复轮询
      _service.resume();
    }
    // inactive：下拉通知栏、来电等瞬时状态，不处理，避免频繁断连
  }

  // ==================== 订阅列表 ====================

  static bool _sameStocks(List<StockConfig> a, List<StockConfig> b) {
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  /// 让 notifier 集合与 [_stocks] 对齐：只补新的、只删旧的，**已存在的一律保留**。
  ///
  /// 曾经这里是「先无条件 `_buildNotifiersFor(_stocks)`，再删多余的」——那个写法
  /// 会把保留下来的标的也换成新的 `ValueNotifier(Quote.empty(...))`：用户每加
  /// 一只股票，整屏卡片的价格先变成 `--`，要等下一轮轮询（100~300ms）才回来。
  /// 而那只标的刚刚还有价，界面在那一帧里说的是假话。
  ///
  /// 被顶掉的旧实例还有第二个问题：它既不在 Map 里、也进不了 `dead`，
  /// 于是永远不会被 `dispose()`——虽然 GC 能回收（监听者会在重建时退订），
  /// 但这违反「谁创建谁释放」的纪律，且真的有人持有它时（比如详情弹层）会
  /// 变成静默泄漏。`putIfAbsent` 一并解决这两件事。
  void _syncNotifiers() {
    final Set<String> wanted = _stocks.map((StockConfig s) => s.key).toSet();

    for (final StockConfig stock in _stocks) {
      _notifiers.putIfAbsent(
        stock.key,
        () => ValueNotifier<Quote>(
          Quote.empty(stock.code, region: stock.region),
        ),
      );
    }

    final List<ValueNotifier<Quote>> dead = <ValueNotifier<Quote>>[];
    _notifiers.removeWhere((String key, ValueNotifier<Quote> notifier) {
      if (wanted.contains(key)) {
        return false;
      }
      dead.add(notifier);
      return true;
    });
    if (dead.isNotEmpty) {
      // 当前帧里可能还有 widget 在监听，等重建完再释放
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final ValueNotifier<Quote> notifier in dead) {
          notifier.dispose();
        }
      });
    }
  }

  /// 把一条行情路由到对应股票。
  ///
  /// 优先按「代码+市场」精确匹配；报文没带市场时退化成按代码找第一个匹配项
  /// （此时若用户同时订阅了沪深同号代码，只能取其一，属于已知边界）。
  ValueNotifier<Quote>? _notifierFor(Quote quote) {
    if (quote.region.isNotEmpty) {
      final ValueNotifier<Quote>? exact =
          _notifiers[StockConfig.keyOf(quote.code, quote.region)];
      if (exact != null) {
        return exact;
      }
    }
    final String prefix = '${quote.code}@';
    for (final MapEntry<String, ValueNotifier<Quote>> entry
        in _notifiers.entries) {
      if (entry.key.startsWith(prefix)) {
        return entry.value;
      }
    }
    return null;
  }

  /// 用户改完订阅列表后：存盘 → 让服务层按新列表重新轮询。
  Future<void> _openWatchlist() async {
    unawaited(haptics.selectionClick());
    final List<StockConfig>? next = await showWatchlistSheet(
      context,
      stocks: _stocks,
      directory: _directory,
      // 公开源配额：实测 30 只一次批量请求 OK
      quota: AppConfig.publicSourceMaxStocks,
    );
    if (!mounted || next == null || _sameStocks(next, _stocks)) {
      return;
    }

    setState(() {
      _stocks = next;
      _syncNotifiers();
    });
    await _watchlist.save(next);
    _service.updateStocks(next);
  }

  /// 行情到达计数：太极的「转一格」由它驱动（见 `TaijiMark` 的类注释）。
  ///
  /// 只统计**真的改了某张卡**的批次：收盘后快照仍会 3s 一次进来，而
  /// `shouldApplyQuote` 会把同时间戳的重复帧挡掉——那种「数据没动」的时刻，
  /// 图标也不该动。改完之后太极只在「有价真的跳了」时走一格。
  final ValueNotifier<int> _quoteTicks = ValueNotifier<int>(0);

  /// 服务层回调：只改对应 notifier，不动整页
  void _onQuotes(List<Quote> quotes) {
    bool changed = false;
    for (final Quote quote in quotes) {
      final ValueNotifier<Quote>? notifier = _notifierFor(quote);
      if (notifier == null) {
        // 未订阅的代码（例如服务端多推了指数），忽略
        continue;
      }
      // 与快照路径同闸：实时推送不能绕过 shouldApplyQuote 直赋，
      // 否则敌意/异常帧的非有限数值会一路冲进 build（R-05）
      final Quote before = notifier.value;
      if (shouldApplyQuote(before, quote)) {
        notifier.value = quote;
        // 放行不等于变了：同值帧不会触发 ValueNotifier 通知，也不该让太极转
        if (before != quote) {
          changed = true;
        }
      }
    }
    if (changed) {
      _quoteTicks.value++;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _service.dispose();
    _quoteTicks.dispose();
    for (final ValueNotifier<Quote> notifier in _notifiers.values) {
      notifier.dispose();
    }
    _notifiers.clear();
    super.dispose();
  }

  /// 「现在几点」的唯一入口。
  ///
  /// 页头秒表、交易时段角标、太极、卡片「快照」角标、详情页来源说明
  /// 必须看到同一个时刻，否则预览里会出现「角标说已收盘、卡片说实时」
  /// 这种自相矛盾；生产环境走 [DateTime.now]。
  DateTime Function() get _clock => widget.clock ?? DateTime.now;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 背景由 AuroraBackground 提供，Scaffold 保持透明才能全屏透出极光
      backgroundColor: Colors.transparent,
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // 背景那一层的画布高度。[HeaderFade] 要按同一个尺寸布局雾团，
          // 否则光团位置整体错开、颜色对不上背景（见它的类注释）
          final double canvasHeight = constraints.maxHeight;
          final double topInset = MediaQuery.paddingOf(context).top;

          return Stack(
            children: <Widget>[
              // 极光是完全静态的：单独切一个图层缓存起来，
              // 行情跳动时就不必连它一起重绘（它下面还有 8 层径向渐变）
              const Positioned.fill(
                child: RepaintBoundary(child: AuroraBackground()),
              ),
              // 列表：**撑满整屏**，靠内容 padding 让开页头。这样卡片上滑时
              // 不会被 viewport 在页头下沿裁出一条硬线，而是继续往上滑进
              // [HeaderFade]，被与背景同色的那一层「吃掉」。
              SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Stack(
                      children: <Widget>[
                        Positioned.fill(child: _buildScrollView()),
                      ],
                    ),
                  ),
                ),
              ),
              // 页头与列表之间的续接层：盖住「屏幕顶 → 页头文字下沿 + 渐隐段」。
              // 铺到屏幕最上面（含状态栏）是因为它画的是背景本身，
              // 坐标必须和背景那一层完全重合。
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: topInset + headerBlockHeight,
                child: HeaderFade(
                  canvasHeight: canvasHeight,
                  topInset: topInset,
                  // 页头内容的底边：top 0 + padding 8 + 太极区 48 + padding 10
                  // （2026-11-05 页头整体上移 10px：原 top 8 + padding 10）
                  solidHeight: 66,
                  height: headerBlockHeight,
                ),
              ),
              // 页头内容：压在最上面。不再有任何材质，直接浮在背景上。
              SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Stack(
                      children: <Widget>[
                        Positioned(
                          // 2026-11-05 用户要求页头上移 10px：top 8→0（-8），
                          // 再把 _buildHeader 上 padding 10→8（-2）。SafeArea
                          // 之内，不钻状态栏；太极顶距状态栏下沿 8px（原 18）。
                          top: 0,
                          left: 16,
                          right: 16,
                          child: _buildHeader(),
                        ),
                      ],
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

  /// 行情列表（抽出来是因为页头改成叠层后，列表要独立占满高度）
  ///
  /// ## 为什么整张列表包在 [GlassBackdropGroup] 里
  ///
  /// Impeller 下**每一块** `BackdropFilter` 都会切断 render pass 并拷贝整屏，
  /// 与玻璃本身多大无关；而 premium 档一块玻璃就有两次（iOS 27 的 frost 是
  /// 三次）。四张卡片 = 每帧 8 次全屏拷贝，90Hz（11.11ms 预算）下必然
  /// 超时——真机实测 raster p50 11.7ms、40/40 帧掉帧，而 build 只有 1.0ms，
  /// 说明瓶颈完全在 GPU 取样，不在重建。组内玻璃共享**一次**背景读取。
  ///
  /// ## 没有下拉刷新
  ///
  /// 产品要求去掉：`RefreshIndicator` 会在列表顶部塞一个转圈，且它是唯一
  /// 需要 `AlwaysScrollableScrollPhysics` 的理由。数据侧本来就不需要它——
  /// 轮询链每 3s 一次全量快照、推送链断线自己退避重连，用户拉那一下
  /// 换不来更新的数据，只换来一次 Haptic 和一根转动的圈。
  Widget _buildScrollView() {
    return GlassBackdropGroup(
      child: ScrollFrameRate(
        controller: appFrameRateController,
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          // 内存：默认 cacheExtent 是 250px，意味着列表外还
          // 多留两三张卡活着——每张 premium 玻璃都握着一份
          // 背景捕获纹理（≈宽×高×4B）。收到 120px 只留半屏
          // 以内的邻居，滚动时按需重建，内存换一点预建。
          scrollCacheExtent: const ScrollCacheExtent.pixels(120),
          slivers: <Widget>[
            // 页头留白 + 提示条（提示条是可选的，空时高度为 0）
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, headerBlockHeight, 16, 0),
              sliver: SliverToBoxAdapter(child: _buildHints()),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
              // 配额卡已按产品要求移除（订阅管理入口改到页头太极）
              sliver: SliverList.separated(
                itemCount: _stocks.length,
                separatorBuilder: (BuildContext context, int index) =>
                    const SizedBox(height: 12),
                itemBuilder: (BuildContext context, int index) {
                  final StockConfig stock = _stocks[index];
                  final ValueNotifier<Quote>? notifier = _notifiers[stock.key];
                  if (notifier == null) {
                    return const SizedBox.shrink();
                  }
                  return QuoteTile(
                    stock: stock,
                    quote: notifier,
                    now: _clock,
                    onTap: () => showQuoteDetailSheet(
                      context,
                      stock: stock,
                      quote: notifier,
                      loader: widget.klineLoader,
                      now: _clock,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 订阅/连接异常的提示条。
  ///
  /// 原本在列表上方的 `Column` 里占一条固定高度；列表改成「占满整屏 +
  /// 顶部 padding」之后，它必须是**滚动内容**——否则它会占据列表顶部，
  /// 把 viewport 又推回到页头下方。
  Widget _buildHints() {
    return ValueListenableBuilder<String?>(
      valueListenable: _service.lastError,
      builder: (BuildContext context, String? error, Widget? _) {
        if (error == null) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _ErrorHint(message: error, onRetry: _service.reconnectNow),
        );
      },
    );
  }

  /// 页头：太极（点开订阅管理）+ 秒表（左）与「AH · 时段」（右）。
  ///
  /// **没有背景材质**。页头原先是一块透明玻璃，但即使是「全透明」的玻璃，
  /// 也会在轮廓上画出菲涅尔亮边 + `rimShade` 暗线 + 色散彩边——在浅雾背景
  /// 上那就是一个看得见的 28 圆角矩形框，上滑时卡片一动，框就更扎眼
  /// （用户：「页头的分界线很明显」）。现在页头直接露出 [AuroraBackground]，
  /// 与股票区域是同一块背景，只在内容层保留一个 [RepaintBoundary]：
  /// 秒表每秒跳一次，只重绘这两行文字，不碰背景。
  Widget _buildHeader() {
    return RepaintBoundary(
      child: Padding(
        // 上 8：2026-11-05 页头上移 10px 的一部分（top 8→0 承担另外 8px）
        padding: const EdgeInsets.fromLTRB(14, 8, 10, 10),
        child: Row(
          children: <Widget>[
            // 圆形太极：订阅里任意市场在交易就自转（混合 A+H 自选时，
            // A 股收盘后港股还在跳，太极必须跟着转）、全部休市才静止
            // 太极 = 订阅管理入口（产品要求：点图标就弹出订阅管理）。
            // 视觉 36px，外面垫 6px 透明内边距把触控区撑到 48dp
            Semantics(
              button: true,
              label: '订阅管理',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _openWatchlist,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: TaijiMark(
                    now: widget.clock ?? DateTime.now,
                    regions: _stocks.map((StockConfig s) => s.region).toList(),
                    // 行情到达才转一格；没有数据就彻底静止（P1-5）
                    ticks: _quoteTicks,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              // 单行：秒表居左、市场/时段居右。
              // 秒表套 Flexible + FittedBox：正常字体下原样显示；极端大字体
              // （实测 360dp × 2.0 倍溢出 60px）整体缩小而不是把右侧挤爆——
              // 时间宁可变小也不能截断，右侧是次要信息才让省略号。
              child: Row(
                children: <Widget>[
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: _ClockTitle(now: widget.clock ?? DateTime.now),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        // 「AH」市场前缀已按用户要求移除（2026-11-05）：
                        // 角标本身已经按订阅市场并集判定时段，前缀是冗余信息
                        Flexible(
                          child: MarketSessionBadge(
                            now: widget.clock ?? DateTime.now,
                            // 与太极同一份订阅市场并集：混合 A+H 时
                            // 15:00–16:10 港股还在交易，角标不能写「已收盘」
                            regions: _stocks
                                .map((StockConfig s) => s.region)
                                .toList(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // 状态胶囊与刷新按钮已按产品要求移除：连接状态是系统内部的事，
            // 出问题时轮询链自己会换源重连（见 PollingQuoteFeed 的退避逻辑），
            // 不需要用户看到「已连接/已断开」再手动点刷新。
          ],
        ),
      ),
    );
  }
}

/// 连接状态胶囊：连接中 / 已连接 / 已断开 / 重连中
/// 页头标题：当前时间（`HH:mm:ss`，带秒）。
///
/// 1s 周期刷新。跟 [MarketSessionBadge] 同一条纪律：钉死的时钟
/// （测试 / 预览）秒位不变就**不 setState**——否则每秒一帧的节奏
/// 会让 pumpAndSettle 永远收不了敛，整个 widget 测试套件卡到超时。
class _ClockTitle extends StatefulWidget {
  const _ClockTitle({required this.now});

  final DateTime Function() now;

  @override
  State<_ClockTitle> createState() => _ClockTitleState();
}

class _ClockTitleState extends State<_ClockTitle>
    with LifecyclePause<_ClockTitle> {
  late String _text;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _text = formatClock(widget.now());
    startTicking();
  }

  @override
  void startTicking() {
    if (_timer != null) {
      return; // 幂等：onShow / onResume 可能各来一次
    }
    // 回前台立刻补上当前时间，不让用户盯着后台那一刻的旧秒数
    final String next = formatClock(widget.now());
    if (next != _text) {
      if (mounted) {
        setState(() => _text = next);
      } else {
        _text = next;
      }
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final String ticked = formatClock(widget.now());
      if (ticked != _text && mounted) {
        setState(() => _text = ticked);
      }
    });
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
    return Text(
      _text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.2,
        color: GlassPalette.ink,
        fontFeatures: kTabularFigures,
      ),
    );
  }
}

/// 致命错误的玻璃提示条（订阅超额）：把「为什么连不上」说清楚
class _ErrorHint extends StatelessWidget {
  const _ErrorHint({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      radius: 20,
      blur: 22,
      lifted: false,
      tint: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[Color(0xE6FFE1E1), Color(0xB3FFC9C9)],
      ),
      padding: const EdgeInsets.fromLTRB(13, 9, 9, 9),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.error_outline_rounded,
            size: 14,
            color: Color(0xFF9B1C1C),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: Color(0xFF9B1C1C),
              ),
            ),
          ),
          const SizedBox(width: 6),
          // 余量朝左、上：下方列表在滚动视图里排在本条之后，向下扩会被
          // 卡片先命中；左侧只是提示文案，没有交互。
          HitTarget(
            alignment: Alignment.bottomRight,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () {
                  unawaited(haptics.selectionClick());
                  onRetry();
                },
                borderRadius: BorderRadius.circular(12),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  child: Text(
                    '重试',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF9B1C1C),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
