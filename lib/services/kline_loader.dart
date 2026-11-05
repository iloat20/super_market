import '../config/app_config.dart';
import '../models/kline.dart';
import '../utils/app_log.dart';
import 'rest_client.dart';
import 'source/kline_source.dart';
import 'source/kline_sources.dart';

/// 拉走势数据：主备切换 + 短期缓存。
///
/// 为什么要有这一层，而不是让 UI 直接调某个源：
///
/// 1. **主备**。新浪的日线不含当日、腾讯含；新浪的分时靠 1 分钟线、腾讯靠
///    minute/query。UI 不该知道这些差异，也不该自己写"失败了换一个"。
/// 2. **缓存**。详情页在「分时 / 日 K」之间来回切是高频操作，每次都打一次
///    外网既慢又没必要——30 秒内的同一请求直接复用。
/// 3. **失败不抛**。走势图是装饰性数据，拉不到就少一块，绝不能让详情页崩。
class KlineLoader {
  KlineLoader({
    List<KlineSource>? chain,
    HttpGetBytes? httpGet,
    DateTime Function()? now,
  }) : _chain = chain ?? KlineSources.chain,
       _httpGet = httpGet ?? defaultHttpGetBytes,
       _now = now ?? DateTime.now;

  final List<KlineSource> _chain;
  final HttpGetBytes _httpGet;
  final DateTime Function() _now;

  /// key = `000001@SZ|daily`，value = 数据 + 过期时间
  final Map<String, _Entry<Object>> _cache = <String, _Entry<Object>>{};

  /// 拉日线。[count] 为空时用 [KlineSource.defaultDailyCount]。
  ///
  /// [count] 是「往前翻历史」的唯一旋钮：两个源的日线接口都是
  /// 「给我最近 N 根」（新浪 `datalen`、腾讯 `param` 的第 5 段），没有
  /// 游标/时间窗。所以翻页的实现就是**把 N 加大重新拉一次**——这也意味着
  /// 第二页会把第一页的数据再传一遍（80→160 多传 80 根，约 10KB），
  /// 换源也不用改协议。
  Future<KlineResult<Kline>> loadDaily(StockConfig stock, {int? count}) async {
    // 夹在合法区间而不是信任调用方：`datalen` 是直接拼进 URL 的，
    // 一个 0 或负数会让服务端返回空、却表现为「这只股票没有走势数据」。
    final int n = (count ?? KlineSource.defaultDailyCount).clamp(
      1,
      KlineSource.maxDailyCount,
    );
    return _load<Kline>(
      '<${stock.key}|daily|$n>',
      (KlineSource s) => s.dailyUri(stock, n),
      (KlineSource s, List<int> bytes) => s.parseDaily(bytes, stock),
      (Kline k) => k.time,
      supports: (KlineSource s) => s.supports(stock),
    );
  }

  /// 拉当日分时。
  Future<KlineResult<IntradayPoint>> loadIntraday(StockConfig stock) {
    return _load<IntradayPoint>(
      '<${stock.key}|intraday>',
      (KlineSource s) => s.intradayUri(stock),
      (KlineSource s, List<int> bytes) => s.parseIntraday(bytes, stock),
      (IntradayPoint p) => p.time,
      supports: (KlineSource s) => s.supports(stock),
    );
  }

  /// 清空缓存（切换订阅列表、手动刷新时用）。
  void clear() => _cache.clear();

  /// 缓存容量上限。
  ///
  /// key 里带 `count`（80/160/240/320/400/480 六档），满配额 30 只 × 7 种组合
  /// = 210 个 key，每份 240~480 根 K 线。没有上限时，一个"逐只切、来回翻历史"
  /// 的用户能把这里堆到几 MB —— 而"长时内存增长"恰恰是这个项目没测过的一项。
  ///
  /// 12 的取值：一屏能同时关心的标的最多几只，加上来回切的两三档就够。
  static const int maxCacheEntries = 12;

  /// 写入并按 LRU 淘汰（`Map` 保持插入顺序，所以"先删后插"= 移到队尾）。
  void _remember(String key, _Entry<Object> entry) {
    _cache.remove(key);
    _cache[key] = entry;
    while (_cache.length > maxCacheEntries) {
      _cache.remove(_cache.keys.first); // 最久未用
    }
  }

  Future<KlineResult<T>> _load<T>(
    String key,
    Uri Function(KlineSource source) uriOf,
    List<T> Function(KlineSource source, List<int> bytes) parseOf,
    DateTime Function(T item) timeOf, {
    bool Function(KlineSource source) supports = _always,
  }) async {
    final _Entry<Object>? hit = _cache[key];
    if (hit != null && !hit.isExpired(_now())) {
      // 命中也要"续命"，否则淘汰策略退化成 FIFO：一个刚看过的股票
      // 会因为它是"最早插入的"而被踢出去
      _remember(key, hit);
      return KlineResult<T>(items: hit.items.cast<T>(), sourceId: hit.sourceId);
    }

    // 主备：按顺序试，第一个**解析出数据**的胜出。
    // 注意判据是"有没有数据"而不是"HTTP 有没有 200"——实测见过 200 但
    // body 是 `null` / `{"result":{"data":null}}`，那跟失败没有区别，
    // 必须继续试下一个，否则主源一坏图就永远空白。
    String? lastError;
    for (final KlineSource source in _chain) {
      if (!supports(source)) {
        continue; // 不支持该市场（新浪 × 港股 K 线），直接跳过，不发请求
      }
      try {
        final HttpRawResponse res = await _httpGet(
          uriOf(source),
          source.headers,
        );
        if (!res.isOk) {
          lastError = '${source.displayName} ${res.failureLabel}';
          AppLog.w('走势 $key：${source.id} ${res.failureLabel}，换下一个源');
          continue;
        }
        final List<T> items = parseOf(source, res.body);
        if (items.isEmpty) {
          lastError = '${source.displayName} 没有返回走势数据';
          AppLog.w('走势 $key：${source.id} 解析为空（${res.byteLength} 字节），换下一个源');
          continue;
        }
        // 防御：接口偶尔乱序，统一按时间升序，UI 不必假设顺序
        items.sort((T a, T b) => timeOf(a).compareTo(timeOf(b)));
        _remember(
          key,
          _Entry<Object>(
            items: items.cast<Object>(),
            sourceId: source.id,
            expiresAt: _now().add(AppConfig.klineCacheTtl),
          ),
        );
        return KlineResult<T>(items: items, sourceId: source.id);
      } on Object catch (e) {
        // R-02（review-2026-11-05）：必须连 Error 一起拦。上游接口形状突变时
        // 解析器/请求层可能抛 Error（RangeError、StateError 等），`on Exception`
        // 拦不住，异常会穿透 loadDaily 把详情页挂在「加载走势…」。
        // 与 symbol_directory（R-04）、PollingQuoteFeed._poll 同一条纪律：
        // 走势是装饰性数据，任何失败都只能变成 failed 结果。
        lastError = '${source.displayName} 请求异常';
        AppLog.w('走势 $key：${source.id} 请求异常（$e），换下一个源');
      }
    }
    return KlineResult<T>.failed(lastError ?? '没有可用的走势数据源');
  }
}

class _Entry<T> {
  const _Entry({
    required this.items,
    required this.sourceId,
    required this.expiresAt,
  });

  final List<T> items;
  final String sourceId;
  final DateTime expiresAt;

  bool isExpired(DateTime now) => !now.isBefore(expiresAt);
}

/// 默认过滤条件：全部支持。
bool _always(KlineSource _) => true;
