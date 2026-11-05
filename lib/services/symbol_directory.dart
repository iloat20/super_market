import 'dart:convert';
import 'dart:isolate';

import '../config/app_config.dart';
import '../utils/app_log.dart';
import 'local_store.dart';
import 'rest_client.dart';
import 'source/polling_sources.dart';
import 'source/symbol_catalog.dart';
import 'source/symbol_search.dart';
import 'source/symbol_searches.dart';

/// 股票代码与名称的本地目录（沪深两市）+ 远端搜索。
///
/// 为什么两件事放在一个类里：**它们是同一个问题的两条路**——「用户想选中
/// 一只股票」。目录负责离线/快速命中，远端搜索负责「本地还没有这份目录时
/// 也能立刻搜」。界面上不需要知道现在走的是哪条。
///
/// 目录本身仍然值得存在：拉一次缓存 30 天，之后搜索完全离线、零延迟。
/// 但它**不该挡在搜索前面**——原来的做法是先下载 5577 条（68.6s）才能搜，
/// 这是把「离线能力」当成了「搜索的前提」。
///
/// 换源后这一层的逻辑没变，变的只是「怎么拉」——那件事已经交给
/// [SymbolCatalog.fetchSymbols]，本类不再知道 iTick 按市场拉 2 次、
/// 新浪要按页翻 56 次。
class SymbolDirectory {
  SymbolDirectory({
    KeyValueStore? store,
    HttpGetJson? httpGet,
    HttpGetBytes? httpGetBytes,
    DateTime Function() now = DateTime.now,
    SymbolCatalog? source,
    SymbolSearch? searcher,
  }) : _store = store ?? MemoryKeyValueStore(),
       _httpGet = httpGet ?? defaultHttpGet,
       _httpGetBytes = httpGetBytes ?? defaultHttpGetBytes,
       _source = source ?? PollingSources.defaultChain.first,
       _searcher = searcher ?? SymbolSearches.current,
       // 同上：命名参数不能写成 `this._now`，规则不适用
       // ignore: prefer_initializing_formals
       _now = now;

  /// 缓存键（带版本号）
  static const String storageKey = 'symbols.v1';

  final KeyValueStore _store;
  final HttpGetJson _httpGet;
  final HttpGetBytes _httpGetBytes;
  final SymbolCatalog _source;
  final SymbolSearch _searcher;
  final DateTime Function() _now;

  List<StockConfig> _items = const <StockConfig>[];
  bool _loaded = false;
  String? _error;

  /// 最近一次抓取失败的时间（冷却期内不再打免费接口）
  DateTime? _lastFailureAt;

  /// 目录已可用（不管来自网络还是缓存）
  bool get isLoaded => _loaded;

  /// 最近一次加载失败的原因（成功时为 null）
  String? get error => _error;

  /// 目录条数（调试/展示用）
  int get count => _items.length;

  /// 加载目录。命中未过期缓存则不发起任何网络请求。
  Future<void> ensureLoaded({bool force = false}) async {
    if (_loaded && !force) {
      return;
    }
    // 失败冷却：缓存不可用 + 源持续挂掉时，避免每次打开搜索面板都
    // 重新触发 6 并发 × 200 页的全量抓取（R-11）
    if (!force &&
        _lastFailureAt != null &&
        _now().difference(_lastFailureAt!) < AppConfig.symbolRetryCooldown) {
      return;
    }

    // 读缓存失败 ≠ 没有缓存。
    //
    // 这一行原来是裸 `await`，在下面那个 `try` **之外**：path_provider 一旦抛
    // （权限 / 磁盘 / 平台通道异常），异常就穿过 `ensureLoaded` 的调用方
    // （`_WatchlistSheetState._prepareDirectory`），被 `unawaited(...)` 吞成一条
    // 引擎级 unhandled error —— 界面上什么都不显示，本地搜索永远是空的。
    // 降级成"没有缓存"，继续走网络。
    _Cache? cache;
    try {
      cache = await _readCache();
    } on Object catch (e) {
      AppLog.w('目录缓存读取失败，按无缓存处理: $e');
    }
    if (!force && cache != null && !_isStale(cache.savedAt)) {
      _items = cache.items;
      _loaded = true;
      _error = null;
      AppLog.i('股票目录命中缓存：${_items.length} 条');
      return;
    }

    try {
      final List<StockConfig> fetched = await _source.fetchSymbols(
        httpGet: _httpGet,
      );
      if (fetched.isNotEmpty) {
        _items = fetched;
        _loaded = true;
        _error = null;
        _lastFailureAt = null;
        await _writeCache(fetched);
        AppLog.i('股票目录已更新：${fetched.length} 条');
        return;
      }
      _error = '目录为空';
    } on SymbolFetchException catch (e) {
      _error = e.message;
      AppLog.e('股票目录下载失败: $_error');
    } on Object catch (e) {
      // 边界层必须连 Error 一起拦：解析层的 UnsupportedError（如
      // Infinity.toInt()）是 Error 不是 Exception（R-04），漏出去会直接
      // 打穿调用方的 async gap 变成 unhandled error
      _error = '网络异常：$e';
      AppLog.e('股票目录下载失败: $_error');
    }
    _lastFailureAt = _now();

    // 失败时退回过期缓存：能搜到旧数据，也好过整个搜索功能不可用
    if (cache != null && cache.items.isNotEmpty) {
      _items = cache.items;
      _loaded = true;
      _error = '使用本地旧目录（${_items.length} 条），刷新失败';
    }
  }

  bool _isStale(DateTime savedAt) =>
      _now().difference(savedAt) > AppConfig.symbolCacheTtl;

  // ==================== 搜索 ====================

  /// 远端搜索（**输入即搜**，不依赖本地目录是否已下载）。
  ///
  /// 返回 `null` 表示**这一次请求失败**，与「搜到了 0 条」严格区分：
  /// 前者要让用户知道「可能是网络」，后者只是换个词的事。混成空列表的话，
  /// 断网时用户会以为是这只股票不存在。
  ///
  /// 调用方应该：本地 [search] 的结果先显示，这个结果回来了再合并。
  Future<List<StockConfig>?> searchRemote(String raw) async {
    final String query = raw.trim();
    if (query.isEmpty) {
      return const <StockConfig>[];
    }
    try {
      final HttpRawResponse res = await _httpGetBytes(
        _searcher.suggestUri(query),
        _searcher.requestHeaders,
      );
      if (!res.isOk) {
        AppLog.w('搜索「$query」失败：${res.failureLabel}');
        return null;
      }
      final List<StockConfig> items = _searcher.parse(res.body);
      AppLog.i('搜索「$query」→ ${items.length} 条（${_searcher.displayName}）');
      return items;
    } on Object catch (e) {
      // 同 ensureLoaded：Error 也不能穿出去（R-04），搜索失败降级为 null
      AppLog.w('搜索「$query」异常：$e');
      return null;
    }
  }

  /// 本地目录搜索（纯内存，零请求）。
  ///
  /// 排序意图：精确代码 > 代码前缀 > 名称前缀 > 名称包含。
  /// 例：输入 `000001` 会先把「平安银行(深)」和「上证指数(沪)」都列出来
  /// —— 这正是需要显示市场标识的原因，两个市场有大量同号代码。
  List<StockConfig> search(String raw, {int limit = 12}) {
    final String query = raw.trim();
    if (query.isEmpty || _items.isEmpty) {
      return const <StockConfig>[];
    }
    final String upper = query.toUpperCase();

    final List<StockConfig> exact = <StockConfig>[];
    final List<StockConfig> codePrefix = <StockConfig>[];
    final List<StockConfig> namePrefix = <StockConfig>[];
    final List<StockConfig> nameContains = <StockConfig>[];

    for (final StockConfig s in _items) {
      if (s.code == query) {
        exact.add(s);
      } else if (s.code.startsWith(query)) {
        codePrefix.add(s);
      } else if (s.name.startsWith(query) || s.name.startsWith(upper)) {
        namePrefix.add(s);
      } else if (s.name.contains(query)) {
        nameContains.add(s);
      }
    }

    return <StockConfig>[
      ...exact,
      ...codePrefix,
      ...namePrefix,
      ...nameContains,
    ].take(limit).toList(growable: false);
  }

  // ==================== 缓存 ====================

  Future<_Cache?> _readCache() async {
    final String? raw = await _store.read(storageKey);
    if (raw == null) {
      return null;
    }
    // 5200 行的存档约 195KB，`jsonDecode` 在中端机上 10~25ms —— 正好超过一帧
    // 预算，而它发生在"打开订阅弹层"的首帧（目录解码 + 首屏布局撞在一起）。
    // 超过阈值就丢进一次性 isolate：`Isolate.run` 用 `Isolate.exit` 把结果
    // 直接移交回来，不复制对象图，也没有额外的 socket/端口生命周期要管。
    //
    // 小 payload 不走 isolate：spawn 本身约 1~3ms，比解析还贵。
    final (int, List<StockConfig>)? parsed = raw.length >= _kOffloadDecodeBytes
        ? await Isolate.run(() => _parseCatalog(raw))
        : _parseCatalog(raw);
    if (parsed == null) {
      return null;
    }
    return _Cache(
      savedAt: DateTime.fromMillisecondsSinceEpoch(parsed.$1),
      items: parsed.$2,
    );
  }

  Future<void> _writeCache(List<StockConfig> items) async {
    // 用数组而不是对象：5200 条 × {"c":..,"n":..,"r":..} 的对象键名会多占约 60KB
    final List<List<String>> rows = items
        .map((StockConfig s) => <String>[s.code, s.region, s.name])
        .toList(growable: false);
    await _store.write(
      storageKey,
      jsonEncode(<String, Object>{
        'savedAt': _now().millisecondsSinceEpoch,
        'rows': rows,
      }),
    );
  }
}

class _Cache {
  const _Cache({required this.savedAt, required this.items});

  final DateTime savedAt;
  final List<StockConfig> items;
}

/// 超过这个体积才值得起 isolate。真实目录约 195KB，测试里的假目录小得多，
/// 天然走内联分支——所以这不是"给测试开的后门"，是按收益划线。
const int _kOffloadDecodeBytes = 64 * 1024;

/// 解析目录存档（纯函数，无 I/O）。
///
/// **必须是顶层函数**：`Isolate.run` 的闭包只能捕获可发送的值，写成实例方法
/// 会把 `this`（持有 HttpClient、KeyValueStore）一起捕获进去。
///
/// 返回 `null` 表示存档不可用（不是合法 JSON / 结构不对）——调用方按"没有缓存"
/// 处理，绝不能把它当成"目录为空"（后者会触发一次全量重抓）。
(int, List<StockConfig>)? _parseCatalog(String raw) {
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?>) {
    return null;
  }
  final Object? savedAt = decoded['savedAt'];
  final Object? rows = decoded['rows'];
  if (savedAt is! int || rows is! List<Object?>) {
    return null;
  }
  final List<StockConfig> items = <StockConfig>[];
  for (final Object? row in rows) {
    // 紧凑格式：[code, region, name]
    if (row is! List<Object?> || row.length < 3) {
      continue;
    }
    items.add(
      StockConfig(code: '${row[0]}', region: '${row[1]}', name: '${row[2]}'),
    );
  }
  return (savedAt, items);
}
