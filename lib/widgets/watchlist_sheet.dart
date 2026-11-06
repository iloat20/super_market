import 'dart:async';

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../config/app_config.dart';
import '../services/symbol_directory.dart';
import '../services/watchlist_repository.dart';
import '../utils/frame_rate.dart';
import '../utils/haptics.dart' as haptics;
import 'glass.dart';
import 'hit_target.dart';

/// 打开「订阅管理」弹层。
///
/// 返回值：
/// - `null`：用户取消（点了遮罩/返回键），调用方不应做任何改动；
/// - 列表：用户确认后的订阅列表（可能和原来一样，调用方需自己判断有没有变化）。
Future<List<StockConfig>?> showWatchlistSheet(
  BuildContext context, {
  required List<StockConfig> stocks,
  required SymbolDirectory directory,
  int quota = AppConfig.publicSourceMaxStocks,
}) {
  return showModalBottomSheet<List<StockConfig>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    // 遮罩 36% → 20% → 14%（A05）：这一层是编辑界面（搜索、删除），背景
    // 确实需要退得更远，但「退得远」的代价直接记在对比度上——遮罩每加深
    // 一档，面板就暗一档，9~11px 的说明文字就更接近不可读。14% 在全屏
    // 列表上仍能明显分出前后层，同时保住面板的亮度。
    barrierColor: const Color(0x240B1220),
    builder: (BuildContext ctx) =>
        _WatchlistSheet(initial: stocks, directory: directory, quota: quota),
  );
}

class _WatchlistSheet extends StatefulWidget {
  const _WatchlistSheet({
    required this.initial,
    required this.directory,
    required this.quota,
  });

  final List<StockConfig> initial;
  final SymbolDirectory directory;
  final int quota;

  @override
  State<_WatchlistSheet> createState() => _WatchlistSheetState();
}

class _WatchlistSheetState extends State<_WatchlistSheet> {
  late List<StockConfig> _stocks = List<StockConfig>.of(widget.initial);
  final TextEditingController _query = TextEditingController();
  final FocusNode _focus = FocusNode();

  /// 远端（搜索建议接口）返回的结果
  List<StockConfig> _remote = const <StockConfig>[];

  /// 上面这批结果对应的关键词。
  ///
  /// 必须记下来：用户把「600」改成「6005」的一瞬间，`_remote` 里还是
  /// 「600」的结果，若直接展示就会出现「搜 6005 却列出 600 的股票」——
  /// 而列表看起来完全正常，只是错的。
  String _remoteFor = '';

  bool _searching = false;

  /// 远端搜索失败（null = 没失败）。与「搜到 0 条」是两件事。
  String? _searchError;

  Timer? _debounce;

  /// 请求序号：只认最后一次输入的结果。
  ///
  /// 250ms 防抖之后仍可能有两个请求同时在飞（用户打完立刻回车、
  /// 或者网络一快一慢）。带序号丢弃过期响应，比「假设响应有序」可靠。
  int _seq = 0;

  String? _hint; // 一次性提示（已达上限 / 已订阅 …）

  @override
  void initState() {
    super.initState();
    _query.addListener(_onQueryChanged);
    unawaited(_prepareDirectory());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query
      ..removeListener(_onQueryChanged)
      ..dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    final String query = _query.text.trim();
    _debounce?.cancel();

    if (query.isEmpty) {
      setState(() {
        _hint = null;
        _remote = const <StockConfig>[];
        _remoteFor = '';
        _searching = false;
        _searchError = null;
      });
      return;
    }

    setState(() {
      _hint = null;
      // 关键词变了就把上一批远端结果丢掉，避免显示"上一次搜索"的答案
      if (_remoteFor != query) {
        _remote = const <StockConfig>[];
        _remoteFor = '';
      }
      _searching = true;
      _searchError = null;
    });

    _debounce = Timer(
      AppConfig.searchDebounce,
      () => unawaited(_search(query)),
    );
  }

  Future<void> _search(String query) async {
    final int seq = ++_seq;
    final List<StockConfig>? items = await widget.directory.searchRemote(query);
    if (!mounted || seq != _seq) {
      return; // 已经有更新的一次输入，这次结果作废
    }
    setState(() {
      _searching = false;
      _remoteFor = query;
      _remote = items ?? const <StockConfig>[];
      _searchError = items == null ? '搜索服务暂时不可用' : null;
    });
  }

  /// 后台预热本地目录。
  ///
  /// **不再阻塞输入、也不再显示进度**：搜索走远端建议接口（实测 170–380ms），
  /// 目录只负责「没网时也能搜」。原来是「先下载完 5577 条目录才能搜」，
  /// 那一次要 68 秒——把离线能力当成了搜索的前提。
  Future<void> _prepareDirectory() async {
    if (widget.directory.isLoaded) {
      return;
    }
    await widget.directory.ensureLoaded();
    if (!mounted) {
      return;
    }
    // 目录到位后重绘一次：同样的关键词，现在本地也能命中了
    setState(() {});
  }

  /// 本地命中的按 query 缓存。
  ///
  /// `directory.search()` 是 5200 条的全表扫描（四条 startsWith/contains），
  /// 单次 0.2~0.5ms；而它在 `build` 里，每次按键、每次 `setState` 都要跑一遍。
  ///
  /// 键里必须带**目录版本**（`count`）：目录是异步加载的。用户打完字、目录
  /// 恰好在这一刻到位时，如果只按 query 命中缓存，界面会永远停在"没搜到"，
  /// 直到他再动一下输入框——这条正是下面那条用例守的。
  String _localQuery = '';
  int _localCount = -1;
  List<StockConfig> _localHits = const <StockConfig>[];

  List<StockConfig> _localMatches(String query) {
    final int count = widget.directory.count;
    if (query == _localQuery && count == _localCount) {
      return _localHits;
    }
    _localQuery = query;
    _localCount = count;
    return _localHits = widget.directory.search(query);
  }

  /// 本地命中优先，远端独有的追加在后面。
  ///
  /// 为什么本地优先：目录是按代码精确排序的，且离线可用；远端的排序是
  /// 「联想」语义（搜「银行」前几条全是 ETF，已被解析层滤掉，但剩下的
  /// 也不按代码排）。两条合并后仍然以「精准匹配」开头，符合预期。
  List<StockConfig> _merge(String query) {
    if (query.isEmpty) {
      return const <StockConfig>[];
    }
    final List<StockConfig> merged = <StockConfig>[..._localMatches(query)];
    final Set<String> keys = merged.map((StockConfig s) => s.key).toSet();
    if (_remoteFor == query) {
      for (final StockConfig s in _remote) {
        if (keys.add(s.key)) {
          merged.add(s);
        }
      }
    }
    return merged.take(12).toList(growable: false);
  }

  /// 空结果时的文案。
  ///
  /// 三种情况必须分开，否则用户不知道该做什么：正在搜（等一下）、
  /// 请求失败（检查网络）、真的没有（换个词）。合成一句「没找到」
  /// 的话，断网时用户会以为这只股票不存在。
  String _emptyHint(String query) {
    if (_searching) {
      return '搜索中…';
    }
    if (_searchError != null) {
      return '$_searchError，检查网络后重试';
    }
    return '没找到「$query」';
  }

  bool get _full => _stocks.length >= widget.quota;

  void _add(StockConfig stock) {
    // 判重必须按身份键（code@region），不能用 StockConfig ==：名称会漂移
    //（公司更名、搜索源与目录源不同步），按 name 判重会把同一只票加成
    // 两张同价卡（C-05，review-2026-11-05）。`==` 里 name 参与是有意保留的
    // （_sameStocks 要能感知名称更新），所以这里单独比 key。
    if (_stocks.any((StockConfig s) => s.key == stock.key)) {
      setState(() => _hint = '${stock.name} 已经在订阅列表里了');
      return;
    }
    if (_full) {
      setState(() => _hint = '最多 ${widget.quota} 只，先删一只再加');
      return;
    }
    unawaited(haptics.selectionClick());
    setState(() {
      _stocks = <StockConfig>[..._stocks, stock];
      _hint = null;
      _query.clear();
    });
    _focus.requestFocus();
  }

  void _addByCode(String code) {
    final String? region = WatchlistRepository.regionForCode(code);
    if (region == null) {
      setState(() => _hint = '无法识别代码 $code：A 股 6 位、港股 5 位数字，北交所暂不支持');
      return;
    }
    _add(StockConfig(code: code, name: code, region: region));
  }

  void _remove(StockConfig stock) {
    if (_stocks.length <= 1) {
      setState(() => _hint = '至少保留 1 只，否则界面会是空的');
      return;
    }
    unawaited(haptics.mediumImpact());
    setState(() {
      _stocks = _stocks.where((StockConfig s) => s != stock).toList();
      _hint = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final String query = _query.text.trim();
    final List<StockConfig> results = _merge(query);
    // 5 位（港股）或 6 位（A 股）纯数字都能手输添加；曾写死 6 位，
    // 港股接入后 00700 这类代码到不了 _addByCode
    final bool canAddByCode =
        WatchlistRepository.isValidCode(query) &&
        !results.any((StockConfig s) => s.code == query);

    // 列表内容先排成一个 List。
    //
    // 这里**不能**换成 `ListView.builder` 图"懒布局"：`shrinkWrap: true` 是
    // 弹层"贴合内容高度"的实现手段，两者不能共存（builder + shrinkWrap 仍然
    // 会量完全部子项，而 builder 单独用会让弹层撑满，见下面 ListView 处的注释）。
    // 真正省下来的是这里把 30 行订阅的 Widget 构造收敛到一处，读起来也短。
    final List<Widget> rows = <Widget>[
      if (query.isNotEmpty) ...<Widget>[
        const _SectionLabel('搜索结果'),
        if (results.isEmpty && !canAddByCode) _EmptyRow(_emptyHint(query)),
        for (final StockConfig s in results)
          _ResultRow(
            stock: s,
            disabled: _full || _stocks.contains(s),
            onTap: () => _add(s),
          ),
        if (canAddByCode) ...<Widget>[
          const SizedBox(height: 6),
          _ResultRow(
            stock: StockConfig(
              code: query,
              name: '按代码添加',
              region: WatchlistRepository.regionForCode(query) ?? '?',
            ),
            disabled: _full,
            onTap: () => _addByCode(query),
          ),
        ],
        const SizedBox(height: 10),
      ],
      _SectionLabel('当前订阅（${_stocks.length}/${widget.quota}）'),
      for (final StockConfig s in _stocks)
        _CurrentRow(stock: s, onRemove: () => _remove(s)),
      const SizedBox(height: 6),
      Text(
        _full ? '已达免费档上限，删除一只后才能添加新的。' : '改动会在点「完成」后生效，并自动重新订阅。',
        style: const TextStyle(
          fontSize: 10.5,
          height: 1.5,
          color: GlassPalette.inkSoft,
        ),
      ),
    ];

    return Padding(
      padding: EdgeInsets.only(
        left: 10,
        right: 10,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 10,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        ),
        // 玻璃是**背景层**，内容与它平级（quote_tile.dart 的同一条结构约束）：
        // 内容一重绘（打字、搜索结果变化）不会把 premium 玻璃的背景捕获
        // 与折射着色拖下水。v19 起底色膜与玻璃色都取
        // GlassPalette.background，和详情弹层同一个色号。
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: Stack(
            children: <Widget>[
              // v19：93% 底色膜，与详情弹层一致。压住背后的列表文字，
              // 也给 premium 着色器一个可控的底色；只换 kSheetGlassSurface
              // 的 76% glassColor 挡不住内容，两处要一起接背景令牌。
              Positioned.fill(
                child: ColoredBox(
                  color: GlassPalette.background.withValues(alpha: 0.93),
                ),
              ),
              Positioned.fill(
                child: GlassContainer(
                  useOwnLayer: true,
                  quality: GlassQuality.premium,
                  shape: LiquidRoundedRectangle(borderRadius: 28),
                  settings: kSheetGlassSurface,
                  child: SizedBox.shrink(),
                ),
              ),
              RepaintBoundary(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const SizedBox(height: 8),
                    const _SheetHandle(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 10, 12, 4),
                      child: Row(
                        children: <Widget>[
                          // 标题和配额胶囊成组靠左，「完成」靠右。1.0x 下 Wrap 只排
                          // 一行、间距同为 8px，位置与原来的 Row + Spacer 逐像素一致；
                          // 3.0x 下胶囊整块换到第二行，而不是把「完成」顶出右边界。
                          Expanded(
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 2,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: <Widget>[
                                const Text(
                                  '订阅管理',
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.3,
                                    color: GlassPalette.ink,
                                  ),
                                ),
                                _QuotaPill(
                                  count: _stocks.length,
                                  quota: widget.quota,
                                ),
                              ],
                            ),
                          ),
                          // 48dp 命中区只放宽 hitTest，不撑高标题行：下方搜索框
                          // 在 Column 里排在本行之后，向下扩会被它先命中。
                          HitTarget(
                            alignment: Alignment.bottomCenter,
                            child: TextButton(
                              onPressed: () => Navigator.of(context).pop(_stocks),
                              style: TextButton.styleFrom(
                                foregroundColor: const Color(0xFF1D6BF3),
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                                minimumSize: const Size(0, 34),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: const Text(
                                '完成',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
                      child: _SearchField(
                        controller: _query,
                        focusNode: _focus,
                        enabled: true,
                      ),
                    ),
                    if (_hint != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            const Icon(
                              Icons.info_outline_rounded,
                              size: 13,
                              color: Color(0xFF8A5A00),
                            ),
                            const SizedBox(width: 5),
                            Expanded(
                              child: Text(
                                _hint!,
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  height: 1.35,
                                  color: Color(0xFF8A5A00),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                        Flexible(
                          child: ScrollFrameRate(
                            controller: appFrameRateController,
                            child: ListView(
                              // ⚠️ shrinkWrap 在这里是**布局契约**，不是性能冗余：
                              // 弹层要"贴合内容高度"（只订了 3 只时不能撑满 0.82 屏）。
                              // 换成 `ListView.builder`（或去掉 shrinkWrap）会让列表去
                              // 吃满 Flexible 给的全部高度，弹层底部留一大片空白——
                              // 2026-11-05 试过，被 `preview/app_preview_test` 的
                              // watchlist golden 当场打红（见 PERF-AUDIT §10.4）。
                              // 真要做懒加载，前提是先把弹层高度固定成产品决定的值。
                              shrinkWrap: true,
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                              children: rows,
                            ),
                          ),
                        ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 4,
      decoration: BoxDecoration(
        color: const Color(0x33101828),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

class _QuotaPill extends StatelessWidget {
  const _QuotaPill({required this.count, required this.quota});

  final int count;
  final int quota;

  @override
  Widget build(BuildContext context) {
    final bool full = count >= quota;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: full ? const Color(0x1FFF9F0A) : const Color(0x14101828),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        '$count / $quota',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
          color: full ? const Color(0xFF8A5A00) : GlassPalette.inkSoft,
          fontFeatures: kTabularFigures,
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 6),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          color: GlassPalette.inkSoft,
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.enabled,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x66FFFFFF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: GlassPalette.strokeSoft),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: <Widget>[
            const Icon(
              Icons.search_rounded,
              size: 17,
              color: GlassPalette.inkSoft,
            ),
            const SizedBox(width: 6),
            Expanded(
              // hintText 输入后即消失，读屏聚焦时需要一个持久字段名。
              // 用 Semantics 而不是 InputDecoration.labelText：后者会多出
              // 浮动 label，改变可见布局与像素。
              child: Semantics(
                label: '搜代码或名称，按代码或名称搜索股票',
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  enabled: enabled,
                  keyboardType: TextInputType.text,
                  textInputAction: TextInputAction.search,
                  style: const TextStyle(fontSize: 14, color: GlassPalette.ink),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: '搜代码或名称，如 600519 / 茅台',
                    // 3.0x 下一行放不下，默认单行会把提示截成
                    // 「搜代码或名称…」——示例代码正是要教用户怎么输。
                    hintMaxLines: 4,
                    hintStyle: TextStyle(
                      fontSize: 13,
                      color: GlassPalette.inkSoft,
                    ),
                    contentPadding: EdgeInsets.symmetric(vertical: 11),
                  ),
                ),
              ),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (BuildContext context, TextEditingValue value, _) {
                if (value.text.isEmpty) {
                  return const SizedBox(width: 2);
                }
                // 余量朝右、上：左侧是输入框（不能偷它的点击），下方
                // 结果列表在 Column 里排本行之后，向下扩会被它先命中。
                return HitTarget(
                  alignment: Alignment.bottomLeft,
                  child: IconButton(
                    onPressed: controller.clear,
                    icon: const Icon(Icons.close_rounded, size: 15),
                    color: GlassPalette.inkSoft,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    tooltip: '清空',
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyRow extends StatelessWidget {
  const _EmptyRow(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
      child: Text(
        text,
        style: const TextStyle(fontSize: 12, color: GlassPalette.inkSoft),
      ),
    );
  }
}

/// 当前订阅的一条
class _CurrentRow extends StatelessWidget {
  const _CurrentRow({required this.stock, required this.onRemove});

  final StockConfig stock;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return _RowShell(
      child: Row(
        children: <Widget>[
          Expanded(child: _StockLabel(stock: stock)),
          _MarketTag(region: stock.region),
          const SizedBox(width: 2),
          // 余量朝右、上：左侧是市场角标（无交互），下方一行在 Column
          // 里排本行之后，向下扩会被它先命中。
          HitTarget(
            alignment: Alignment.bottomLeft,
            child: IconButton(
              onPressed: onRemove,
              icon: const Icon(Icons.remove_circle_outline_rounded, size: 19),
              color: const Color(0xFFB4453B),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
              padding: EdgeInsets.zero,
              tooltip: '删除 ${stock.name}',
            ),
          ),
        ],
      ),
    );
  }
}

/// 搜索结果的一条
class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.stock,
    required this.disabled,
    required this.onTap,
  });

  final StockConfig stock;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 整行本来就约 52dp 高，这里只是把 48dp 下限钉死：minSize 不产生
    // 额外扩展，占位与 golden 逐字节不变。
    return HitTarget(
      child: Semantics(
        button: true,
        enabled: !disabled,
        label: '${disabled ? '已订阅' : '添加'} '
            '${stock.name} ${stock.code} ${stock.region}',
        child: Opacity(
          opacity: disabled ? 0.45 : 1,
          child: InkWell(
            onTap: disabled ? null : onTap,
            borderRadius: BorderRadius.circular(14),
            child: _RowShell(
              child: Row(
                children: <Widget>[
                  Expanded(child: _StockLabel(stock: stock)),
                  _MarketTag(region: stock.region),
                  const SizedBox(width: 6),
                  Icon(
                    disabled
                        ? Icons.check_rounded
                        : Icons.add_circle_outline_rounded,
                    size: 19,
                    color: disabled
                        ? GlassPalette.inkSoft
                        : const Color(0xFF1D6BF3),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RowShell extends StatelessWidget {
  const _RowShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
      decoration: BoxDecoration(
        color: const Color(0x4DFFFFFF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: GlassPalette.strokeSoft),
      ),
      child: child,
    );
  }
}

class _StockLabel extends StatelessWidget {
  const _StockLabel({required this.stock});

  final StockConfig stock;

  @override
  Widget build(BuildContext context) {
    final Text name = Text(
      stock.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: GlassPalette.ink,
      ),
    );
    final Text code = Text(
      stock.code,
      style: const TextStyle(
        fontSize: 11,
        letterSpacing: 0.6,
        color: GlassPalette.inkSoft,
        fontFeatures: kTabularFigures,
      ),
    );
    // 并排时名称得跟代码抢宽度：3.0x 下代码一行就吃掉整个宽度，名称只剩
    // 一个字（「贵…」）。放大到名称一整个字都放不下时改上下堆叠——
    // 名称是这一行的主信息，不能为了保持一行而把它省略掉。
    if (MediaQuery.textScalerOf(context).scale(14) > 26) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[name, const SizedBox(height: 1), code],
      );
    }
    return Row(
      children: <Widget>[
        Flexible(child: name),
        const SizedBox(width: 6),
        code,
      ],
    );
  }
}

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
          // 这枚 9px 标签压在自己的深色底（12% 墨）上，底色比面板暗一档，
          // `inkSoft` 在它上面只有 4.31:1。标签本身是「代码归属」的硬信息，
          // 不是次要说明文字，直接用主文字色——顺便也把这一层拉开。
          color: GlassPalette.ink,
        ),
      ),
    );
  }
}
