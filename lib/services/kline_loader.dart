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
/// 4. **增量刷新**（见 [_tryDelta]）。日线 TTL 过期后若同源缓存还在，
///    只拉最新 2 根、用锚点证明连续性再本地拼接，而不是重传 80 根。
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
  ///
  /// 三种出口，按优先级：命中未过期缓存（0 请求）→ 过期但可增量（2 根）
  /// → 全量主备（N 根）。UI 完全不用知道走了哪一条，`_retry()` 的
  /// [clear] 会把缓存清空，保证手动重试仍是实打实的全量重拉。
  Future<KlineResult<Kline>> loadDaily(StockConfig stock, {int? count}) async {
    // 夹在合法区间而不是信任调用方：`datalen` 是直接拼进 URL 的，
    // 一个 0 或负数会让服务端返回空、却表现为「这只股票没有走势数据」。
    final int n = (count ?? KlineSource.defaultDailyCount).clamp(
      1,
      KlineSource.maxDailyCount,
    );
    final String key = '<${stock.key}|daily|$n>';
    final KlineResult<Kline>? hit = _freshHit<Kline>(key);
    if (hit != null) {
      return hit;
    }

    // 过期的条目**不删**：它正是增量拼接的基线。拿不到可用增量时，
    // 下面的全量主备会照常覆盖它，行为与改造前一致。
    final _Entry<Object>? stale = _cache[key];
    if (stale != null && n >= _deltaProbeCount) {
      final KlineResult<Kline>? delta = await _tryDelta(stock, n, key, stale);
      if (delta != null) {
        return delta;
      }
    }

    return await _load<Kline>(
      key,
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

  /// 取未过期的缓存并续命。抽出来是因为 [loadDaily] 要先于增量判断查一次，
  /// [_load] 在全量回退时还得再查一次（两处必须是同一个判据）。
  KlineResult<T>? _freshHit<T>(String key) {
    final _Entry<Object>? hit = _cache[key];
    if (hit == null || hit.isExpired(_now())) {
      return null;
    }
    // 命中也要"续命"，否则淘汰策略退化成 FIFO：一个刚看过的股票
    // 会因为它是"最早插入的"而被踢出去
    _remember(key, hit);
    return KlineResult<T>(
      items: hit.items.cast<T>(),
      sourceId: hit.sourceId,
      includesToday: hit.includesToday,
    );
  }

  Future<KlineResult<T>> _load<T>(
    String key,
    Uri Function(KlineSource source) uriOf,
    List<T> Function(KlineSource source, List<int> bytes) parseOf,
    DateTime Function(T item) timeOf, {
    bool Function(KlineSource source) supports = _always,
  }) async {
    final KlineResult<T>? hit = _freshHit<T>(key);
    if (hit != null) {
      return hit;
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
            createdAt: _now(),
            includesToday: _includesToday(source.id),
          ),
        );
        return KlineResult<T>(
          items: items,
          sourceId: source.id,
          includesToday: _includesToday(source.id),
        );
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

  /// 增量探测取几根：**2**。
  ///
  /// 不是需求里写的 1 根，因为 1 根**证明不了连续性**：App 后台几天、
  /// 长假或停牌后，缓存末根是 D-5、服务端末根是 D，只拉 1 根就会把
  /// 「D-5 后面紧跟 D」当成正常序列 append 上去 —— 中间少 4 根，
  /// 图上不报错，但 MA 全算错。除权除息时腾讯 qfq 会把**全部历史价**
  /// 重算一遍，1 根同样发现不了。
  ///
  /// 改成拉 2 根：第 1 根当锚点，必须与缓存里的某根**逐字段相同**；
  /// 第 2 根才是要拼的最新一根。锚点对不上就回退全量，宁可多花一次
  /// 请求也不能画错。`tool/probe_kline_delta.py` 实测多加这一根只多
  /// 242 B（新浪）/ 71 B（腾讯），相对 80 根仍省 97.3% / 75.3%。
  static const int _deltaProbeCount = 2;

  /// 用过期缓存做增量刷新；任何可疑情况返回 null，由调用方回退全量主备。
  ///
  /// 三条硬约束（对应 `kline_incremental_test.dart` 的守门用例）：
  ///
  /// 1. **同源**。缓存是新浪给的就只问新浪。新浪日线不含当日、腾讯含当日
  ///    且实时更新；新浪不复权、腾讯 `qfq` 前复权。跨源拼接会把两种价格
  ///    基准混进一条序列，且完全不报错。
  /// 2. **锚点校验**。新响应的前一根必须与缓存末根（多了一个交易日）或
  ///    倒数第二根（最后一根被刷新）逐字段相同。字段里含价格与成交量，
  ///    所以缺口、复权重算、源格式变化都会在这里被挡下。
  /// 3. **失败即全量**。增量请求失败、根数不对、解析为空、抛 Error，一律
  ///    返回 null。走势是装饰性数据，绝不能因为一次小优化把图搞坏。
  Future<KlineResult<Kline>?> _tryDelta(
    StockConfig stock,
    int count,
    String key,
    _Entry<Object> stale,
  ) async {
    final List<Kline> cached = stale.items.cast<Kline>().toList();
    // 少于两根就没有锚点可比（也覆盖 count=1 的调用）。
    if (cached.length < _deltaProbeCount) {
      return null;
    }

    KlineSource? source;
    for (final KlineSource s in _chain) {
      if (s.id == stale.sourceId && s.supports(stock)) {
        source = s;
        break;
      }
    }
    if (source == null) {
      return null; // 出数据的源已不在链里 / 不支持该市场 → 交给全量主备
    }

    try {
      final HttpRawResponse res = await _httpGet(
        source.dailyUri(stock, _deltaProbeCount),
        source.headers,
      );
      if (!res.isOk) {
        AppLog.w('走势 $key：增量 ${source.id} ${res.failureLabel}，回退全量');
        return null;
      }
      final List<Kline> probe =
          source.parseDaily(res.body, stock)
            ..sort((Kline a, Kline b) => a.time.compareTo(b.time));
      if (probe.length != _deltaProbeCount) {
        AppLog.w('走势 $key：增量 ${source.id} 返回 ${probe.length} 根，回退全量');
        return null;
      }

      final Kline anchor = probe.first;
      final Kline latest = probe.last;
      if (!anchor.isValid || !latest.isValid || !latest.time.isAfter(anchor.time)) {
        return null;
      }

      final Kline last = cached.last;
      final Kline beforeLast = cached[cached.length - 2];
      List<Kline> merged;
      if (_sameBar(anchor, last)) {
        // 恰好多了一个交易日 → 追加最新一根
        merged = <Kline>[...cached, latest];
      } else if (_sameBar(anchor, beforeLast) &&
          _sameDay(latest.time, last.time) &&
          !latest.time.isBefore(last.time)) {
        // 没有新交易日，只是最后一根被刷新（腾讯当日实时 bar）→ 覆盖
        merged = <Kline>[...cached.sublist(0, cached.length - 1), latest];
      } else {
        AppLog.w('走势 $key：增量锚点对不上（缺口或复权重算），回退全量');
        return null;
      }

      // 窗口宽度由 count 决定：追加后超出的最旧一根要挤掉，否则序列会越拼越长。
      if (merged.length > count) {
        merged = merged.sublist(merged.length - count);
      }
      _remember(
        key,
        _Entry<Object>(
          items: merged.cast<Object>(),
          sourceId: source.id,
          expiresAt: _now().add(AppConfig.klineCacheTtl),
          createdAt: _now(),
          includesToday: _includesToday(source.id),
        ),
      );
      return KlineResult<Kline>(
        items: merged,
        sourceId: source.id,
        includesToday: _includesToday(source.id),
      );
    } on Object catch (e) {
      // 与 _load 同一条 R-02 纪律：Error 也要拦，增量失败只能是「回退」。
      AppLog.w('走势 $key：增量 ${source.id} 请求异常（$e），回退全量');
      return null;
    }
  }

  /// 逐字段相同，而不只是同一天：价格/成交量的变化正是「复权重算」的信号。
  /// 日期只按年月日归一化——解析器明确接受带时分秒 / 时区后缀的 `day`，
  /// `DateTime ==` 会把同一交易日判成两根，增量因此永久回退全量。
  static bool _sameBar(Kline a, Kline b) =>
      _sameDay(a.time, b.time) &&
      a.open == b.open &&
      a.high == b.high &&
      a.low == b.low &&
      a.close == b.close &&
      a.volume == b.volume;

  /// 日线的 DateTime 通常是当天 0 点，但不假设源一定不带时分秒。
  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// 该源是否自带当日实时 bar（腾讯 qfq），用于给结果标记价格口径。
  static bool _includesToday(String sourceId) => sourceId == 'tencent';
}

class _Entry<T> {
  const _Entry({
    required this.items,
    required this.sourceId,
    required this.expiresAt,
    required this.createdAt,
    required this.includesToday,
  });

  final List<T> items;
  final String sourceId;
  final DateTime expiresAt;
  final DateTime createdAt;
  final bool includesToday;

  bool isExpired(DateTime now) {
    // expiresAt 是绝对墙钟。本地时间被调回时它成了远期未来，缓存会数小时
    // 不刷新；宁可判过期重拉一次，也不要拿陈旧日线画图。
    if (now.isBefore(createdAt)) {
      return true;
    }
    // 与 isStale 同用开区间：恰好等于判决线时仍算新鲜。
    return now.isAfter(expiresAt);
  }
}

/// 默认过滤条件：全部支持。
bool _always(KlineSource _) => true;
