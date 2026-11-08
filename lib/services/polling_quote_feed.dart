import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../models/quote.dart';
import '../utils/app_log.dart';
import '../utils/beijing_clock.dart';
import 'quote_feed.dart';
import 'rest_client.dart';
import 'source/polling_source.dart';
import 'source/polling_sources.dart';

/// 轮询型行情通道：**主备双内核 + 自动故障切换**。
///
/// ## 为什么是这个形状
///
/// 新浪 / 腾讯都是公开接口，服务器端做了缓存，所以延迟不是靠"问得更快"缩短的
/// （实测 300ms 反而更旧）。它们真正的价值是**没有 Key、没有配额、不会因为
/// 一条连接被踢而全盘失联**。既然拿到了这个好处，就必须补上推送本来免费送的
/// 两个东西：
///
/// 1. **新鲜度**：靠固定 3s 节奏（[AppConfig.pollInterval]）；
/// 2. **不中断**：靠主备两个内核轮着试（本类的核心）。
///
/// ## 三层保险
///
/// | 层 | 触发 | 动作 |
/// | --- | --- | --- |
/// | 单次请求 | 超时 / HTTP 非 200 / 解析空 | 记一次失败，按原节奏重试 |
/// | 连续 3 次失败 | 见 [AppConfig.pollFailoverAfter] | 换下一个内核 |
/// | 一圈都失败 | 回到主力源 | 轮询间隔退避（最长 30s），界面报「都不通」 |
///
/// 单次失败**不**换源：偶发一次超时（地铁进隧道）换源只会让状态胶囊闪，
/// 而且备份源用的还是同一条隧道内的网络，换了也一样失败。
///
/// ## 一个不显眼但很重要的细节
///
/// 切换内核后，新源的时间戳可能比旧源**更早**（两个源缓存刷新时刻不同）。
/// 如果直接下发，界面上的价格会"倒退"一下。所以每个标的最新的时间戳被记在
/// [_lastQuoteMs] 里，更旧的直接丢掉——宁可少一次更新，也不要价格往回跳。
class PollingQuoteFeed implements QuoteFeed {
  PollingQuoteFeed({
    required this.onQuotes,
    List<PollingSource>? chain,
    this.regionBackup,
    List<StockConfig>? stocks,
    HttpGetBytes? httpGet,
    DateTime Function()? now,
    Duration? interval,
    Duration? timeout,
  }) : _chain = List<PollingSource>.unmodifiable(
         (chain == null || chain.isEmpty) ? PollingSources.defaultChain : chain,
       ),
       _stocks = List<StockConfig>.unmodifiable(stocks ?? AppConfig.stocks),
       _httpGet = httpGet ?? defaultHttpGetBytes,
       _now = now ?? beijingNow,
       _interval = interval ?? AppConfig.pollInterval,
       _timeout = timeout ?? AppConfig.restTimeout;

  /// 解析出的行情回调（每轮一次，可能包含多只）
  final void Function(List<Quote> quotes) onQuotes;

  @override
  final ValueNotifier<FeedStatus> status = ValueNotifier<FeedStatus>(
    FeedStatus.disconnected,
  );

  @override
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  /// 主备内核，按顺序尝试；第一个是主力
  final List<PollingSource> _chain;

  /// 区域补位源：主链覆盖不到的市场由它兜底（目前只有美股）。
  ///
  /// 它**不参与**主备轮转——主链的健康度只看 [_chain] 里的源。补位源只负责
  /// 「主链管不着的那些标的」，失败也只影响那些标的，不触发整体切源。
  final PollingSource? regionBackup;

  final HttpGetBytes _httpGet;
  final DateTime Function() _now;
  final Duration _interval;
  final Duration _timeout;

  List<StockConfig> _stocks;

  @override
  List<StockConfig> get stocks => _stocks;

  @override
  String get sourceLabel => _chain[_activeIndex].displayName;

  /// 当前生效的内核下标
  int _activeIndex = 0;

  /// 当前内核连续失败次数
  int _failStreak = 0;

  /// 补位源连续失败次数（只用于提示，不触发主链切源）
  int _backupFailStreak = 0;

  /// 已经连续失败了多少「圈」（一圈 = 所有内核都试过一遍）
  int _backoffLevel = 0;

  /// 单飞：上一次请求还没回来就不叠发。
  ///
  /// 不这么做的话，网络变慢时定时器会不断堆积请求，最后同时回来一串
  /// **过期**的响应，界面反而更乱。
  bool _busy = false;

  Timer? _timer;
  bool _paused = false;
  bool _disposed = false;

  /// 每个标的最后一次下发的时间戳（防切源后价格倒退）
  final Map<String, int> _lastQuoteMs = <String, int>{};

  /// 当前生效的内核（调试/展示用）
  PollingSource get activeSource => _chain[_activeIndex];

  /// 当前的轮询间隔（退避后会变长）
  Duration get currentInterval => _delay();

  // ==================== 对外方法 ====================

  @override
  void connect() {
    // _paused 不可在此清除：connect 的唯一调用点是启动流程，而切后台可能
    // 恰好发生在「读存档的 await」与 connect 之间——清了就会在后台恢复
    // 3s 轮询，违反「只在前台盯盘」的承诺。恢复前台是 resume 的职责。
    if (_disposed || _paused || _timer != null || _busy) {
      return;
    }
    if (_stocks.isEmpty) {
      status.value = FeedStatus.disconnected;
      return;
    }
    AppLog.i('开始轮询：${_label()}，间隔 ${_interval.inMilliseconds}ms');
    status.value = FeedStatus.connecting;
    _schedule(Duration.zero);
  }

  @override
  void pause() {
    if (_disposed || _paused) {
      return;
    }
    _paused = true;
    _cancelTimer();
    AppLog.i('App 进入后台 → 停止轮询');
    status.value = FeedStatus.disconnected;
  }

  @override
  void resume() {
    if (_disposed) {
      return;
    }
    _paused = false;
    _backoffLevel = 0;
    _failStreak = 0;
    _backupFailStreak = 0;
    if (_stocks.isEmpty) {
      // 空订阅没有可拉的对象。_poll 的空列表分支在 finally 之前早退，
      // 若这里仍置 connecting 并 schedule，状态会永久卡在「连接中」。
      _cancelTimer();
      status.value = FeedStatus.disconnected;
      lastError.value = null;
      return;
    }
    if (_timer != null || _busy) {
      return; // 还在正常跑，不必打断节奏
    }
    AppLog.i('回到前台 → 立即恢复轮询');
    status.value = FeedStatus.connecting;
    _schedule(Duration.zero);
  }

  @override
  void reconnectNow() {
    if (_disposed) {
      return;
    }
    _paused = false;
    _backoffLevel = 0;
    _failStreak = 0;
    _backupFailStreak = 0;
    _cancelTimer();
    status.value = FeedStatus.connecting;
    lastError.value = null;
    _schedule(Duration.zero);
  }

  @override
  void updateStocks(List<StockConfig> next) {
    // M-01（review-2026-11-05）：原来这里有一个手写的 _sameStocks，
    // 与 quote_list_page 的那份逐字节相同——重复实现只会互相漂移，
    // 统一收敛到 foundation.listEquals（元素按 StockConfig == 逐一比较，
    // 语义与原实现完全一致）。
    if (listEquals(next, _stocks)) {
      return;
    }
    final Set<String> keep = next.map((StockConfig s) => s.key).toSet();
    _lastQuoteMs.removeWhere((String key, int _) => !keep.contains(key));
    _stocks = List<StockConfig>.unmodifiable(next);
    AppLog.i('订阅列表已更新：${_stocks.length} 只');
    if (_disposed || _paused) {
      return;
    }
    if (_stocks.isEmpty) {
      // 空列表没有可拉的对象：显式停摆并把状态归位，别让 timer 链走进
      // _poll 的空列表早退后无声熄火、status 残留「已连接」的假象。
      _cancelTimer();
      status.value = FeedStatus.disconnected;
      lastError.value = null;
      return;
    }
    // 立刻拉一轮，不要等下一个 3s 周期：新加的票应该马上有价
    _cancelTimer();
    _schedule(Duration.zero);
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _cancelTimer();
    status.dispose();
    lastError.dispose();
  }

  // ==================== 轮询 ====================

  void _schedule(Duration delay) {
    if (_disposed || _paused) {
      return;
    }
    _cancelTimer();
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(_poll());
    });
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _poll() async {
    if (_disposed || _paused || _busy) {
      return;
    }
    if (_stocks.isEmpty) {
      // 这个早退在 finally 之外，必须自己把状态归位。
      if (status.value != FeedStatus.disconnected) {
        status.value = FeedStatus.disconnected;
        lastError.value = null;
      }
      return;
    }
    _busy = true;
    try {
      final PollingSource source = _chain[_activeIndex];
      // 只问这个内核**声明支持**的市场（`PollingSource.markets`）。
      // 把不支持的标的拼进 URL 换来的是一行 `v_pv_none_match`：解析器跳过它，
      // 而整批仍有别的票有价，于是这一轮被判「成功」——被跳过的那只从此
      // 不再更新，且没有任何提示（见 _coverageGap）。
      final List<StockConfig> targets = _coveredBy(source);
      final List<Quote> quotes = <Quote>[];
      Object? primaryError;
      bool primaryOk = false;

      if (targets.isEmpty) {
        primaryError = const _PollFailure('当前内核不覆盖任何订阅市场');
      } else {
        try {
          quotes.addAll(await _fetchQuotes(source, targets));
          primaryOk = true;
        } on Object catch (e) {
          if (e is ArgumentError) {
            // requireHttps 抛的是 Error：scheme 写错属于编码错误，不是
            // 一次可重试的网络失败。单独上报，不切源、不退避。
            _onConfigurationError(e);
            return;
          }
          primaryError = e;
        }
      }

      // 主链声明覆盖不到的市场（美股）以及这一轮没拿到的美股，由补位源补一次。
      // 补位源只声明自己的 markets，主链漏掉的 A/H 行补不了，缺口由
      // _coverageGap 按本轮实际结果说话。
      // 正常路径（主链把美股也拿全了）不会多发任何请求；补位失败已在
      // _fillFromBackup 里记日志，这里不再重复刷屏。
      await _fillFromBackup(quotes);

      if (primaryOk) {
        _onSuccess(quotes);
      } else {
        // 主源这轮失败，但补位拿到的价仍然要推给 UI——美股不该跟着 A/H
        // 一起冻结。先落地行情，再记失败：_onFailure 会改状态与退避，
        // 但不会清掉已经推下去的报价。
        _applyQuotes(quotes);
        final Set<String> got = <String>{
          for (final Quote q in quotes) StockConfig.keyOf(q.code, q.region),
        };
        _onFailure(
          primaryError ?? const _PollFailure('本轮没有任何行情'),
          backupComplete:
              quotes.isNotEmpty &&
              _stocks.every((StockConfig s) => got.contains(s.key)),
        );
      }
    } finally {
      _busy = false;
      if (!_disposed && !_paused) {
        _schedule(_delay());
      }
    }
  }

  /// 一次请求 + 解析；失败抛 [_PollFailure]。
  Future<List<Quote>> _fetchQuotes(
    PollingSource source,
    List<StockConfig> targets,
  ) async {
    final HttpRawResponse res = await _httpGet(
      source.batchQuoteUri(targets),
      source.requestHeaders(),
    ).timeout(_timeout);
    if (!res.isOk) {
      throw _PollFailure(res.failureLabel);
    }
    final List<Quote> quotes = source.parseBatchQuotes(
      res.body,
      stocks: targets,
    );
    if (quotes.isEmpty) {
      // HTTP 200 但一条都解析不出来：报文结构变了，或者全是被过滤的脏数据。
      // 这比 404 更危险（看起来是成功的），所以按失败处理并换源。
      throw const _PollFailure('响应里没有可用的报价');
    }
    return quotes;
  }

  /// 用补位源补齐 [quotes] 里缺的标的。
  ///
  /// 两种情况会补：
  /// 1. 主链**不声明**支持这个市场（腾讯没有美股）；
  /// 2. 主链声明支持、但这一轮报文里没有这只票（新浪偶发漏行）。
  Future<void> _fillFromBackup(List<Quote> quotes) async {
    final PollingSource? backup = regionBackup;
    if (backup == null) {
      return;
    }
    final Set<String> got = <String>{
      for (final Quote q in quotes) StockConfig.keyOf(q.code, q.region),
    };
    final List<StockConfig> need = _stocks
        .where((StockConfig s) => backup.markets.contains(s.region))
        .where((StockConfig s) => !got.contains(s.key))
        .toList(growable: false);
    if (need.isEmpty) {
      _backupFailStreak = 0; // 这轮不用补 = 主链自己够了
      return;
    }
    try {
      quotes.addAll(await _fetchQuotes(backup, need));
      if (_backupFailStreak != 0) {
        AppLog.i('补位已恢复：${backup.displayName}');
        _backupFailStreak = 0;
      }
    } on Object catch (e) {
      _backupFailStreak++;
      AppLog.w(
        '补位失败 ${backup.displayName} '
        '（连续 $_backupFailStreak 次）：${_describe(e)}',
      );
    }
  }

  void _onSuccess(List<Quote> quotes) {
    // dispose 与在途请求是并发的（dispose 不等一轮轮询结束）：请求落地时
    // notifier 可能已经释放，继续走只会把「A ValueNotifier was used after
    // being disposed」吞成一条假失败日志。
    //
    // `_paused` 同理：pause 只停掉了定时器，在途请求照样会落地。不管它的话，
    // 一次「切后台时正好有请求在飞」会把 pause 刚置的 disconnected 顶回
    // connected，并继续往后台的 UI 推数据——而契约承诺的是「不保留任何
    // 后台活动」（quote_feed.dart）。
    if (_disposed || _paused) {
      return;
    }
    _failStreak = 0;
    if (_backoffLevel != 0) {
      _backoffLevel = 0;
      AppLog.i('轮询已恢复，退避清零');
    }
    final String? gap = _coverageGap(_chain[_activeIndex], quotes);
    if (status.value != FeedStatus.connected || lastError.value != gap) {
      if (status.value != FeedStatus.connected) {
        AppLog.i('轮询成功：${_chain[_activeIndex].displayName}');
      }
      lastError.value = gap;
      status.value = FeedStatus.connected;
    }
    _applyQuotes(quotes);
  }

  /// 落地报价（棘轮 + 回调），**不碰状态机**。
  ///
  /// 单独拆出来，是因为「主源失败、补位有价」这一档要推数据，但不能把状态
  /// 改成「已连接」——那会让用户以为 A/H 也好了。
  void _applyQuotes(List<Quote> quotes) {
    if (_disposed || _paused || quotes.isEmpty) {
      return;
    }
    final int nowMs = _now().millisecondsSinceEpoch;
    // 在途请求用的是 await 之前的订阅快照；落地时订阅可能已被删改。
    // 按「当前」订阅过滤，否则旧标的会重新写回棘轮与 UI。
    final Set<String> subscribed = <String>{
      for (final StockConfig s in _stocks) s.key,
    };
    final List<Quote> applied = <Quote>[];
    for (final Quote quote in quotes) {
      final String key = StockConfig.keyOf(quote.code, quote.region);
      if (!subscribed.contains(key)) {
        continue;
      }
      final int ms = quote.timestamp?.millisecondsSinceEpoch ?? nowMs;
      // 未来时间戳必须挡在棘轮**之前**：`_lastQuoteMs` 只增不减、没有 TTL，
      // 一个被 DateTime 归一化出来的「2027 年」脏时间戳会让这只票此后每一轮
      // 都被判「更旧」而丢弃；而 `isStale` 对负 age 返回「不陈旧」，界面
      // 于是永久停在旧价、还坚持说这是实时价。
      if (ms > nowMs + _maxFutureSkew.inMilliseconds) {
        AppLog.w('丢弃未来时间戳的报价 $key：$ms 比现在晚太多');
        continue;
      }
      final int? previous = _lastQuoteMs[key];
      if (previous != null && ms < previous) {
        AppLog.d('丢弃更旧的报价 $key：$ms < $previous（多半是刚切过内核）');
        continue;
      }
      _lastQuoteMs[key] = ms;
      applied.add(quote);
    }
    if (applied.isNotEmpty) {
      onQuotes(applied);
    }
  }

  /// 数据源配置错误（目前只有 [requireHttps] 抛的 ArgumentError）。
  ///
  /// 它是编码错误，不是网络失败：不累计失败次数、不切源、不退避。
  /// 只把事实写进 [lastError]，让排查方向停在「URI 配错了」。
  void _onConfigurationError(Object error) {
    if (_disposed || _paused) {
      return;
    }
    lastError.value = '数据源配置错误：${_describe(error)}';
  }

  void _onFailure(Object error, {bool backupComplete = false}) {
    // 与 _onSuccess / _applyQuotes 同一条纪律：pause 只停定时器，
    // 在途请求照样落地。后台期间的失败也不得推进切源、退避或写提示。
    if (_disposed || _paused) {
      return;
    }
    _failStreak++;
    final PollingSource source = _chain[_activeIndex];
    AppLog.w(
      '轮询失败 ${source.displayName} '
      '（连续 $_failStreak 次）：${_describe(error)}',
    );

    if (_failStreak >= AppConfig.pollFailoverAfter && _chain.length > 1) {
      _failStreak = 0;
      final int from = _activeIndex;
      _activeIndex = _nextViableIndex(from);
      if (_activeIndex == 0) {
        _backoffLevel++;
      }
      if (_activeIndex == from) {
        // 没有「能带队」的备源：不切。切过去会让它不覆盖的那几只票静默
        // 冻结，而整批仍被判成功——比继续在主源上退避更糟。
        AppLog.w(
          '${_chain[from].displayName} 连续失败，但没有能带队的备源 → '
          '原地退避 ${currentInterval.inSeconds}s',
        );
      } else {
        AppLog.w(
          '${_chain[from].displayName} 连续失败 → '
          '切到 ${_chain[_activeIndex].displayName}',
        );
      }
    } else if (_failStreak >= AppConfig.pollFailoverAfter) {
      // 只有一个内核：没有可切的，直接进退避
      _failStreak = 0;
      _backoffLevel++;
    }

    if (backupComplete) {
      // 主源确实挂了，但每个订阅标的都有价（补位源补全）。数据是完整的：
      // 状态按「有数据」算，也不放慢节奏——慢下来只会让补位的数据更旧。
      // 失败次数照常累计（该切源还是要切），只是不打扰用户。
      _backoffLevel = 0;
      if (status.value != FeedStatus.connected || lastError.value != null) {
        AppLog.w('主源不可用，当前由补位源供数');
        status.value = FeedStatus.connected;
        lastError.value = null;
      }
      return;
    }

    if (_backoffLevel > 0) {
      final String detail = _describe(error);
      lastError.value =
          '行情源暂时都不通：$detail'
          '（已放慢到 ${currentInterval.inSeconds}s 重试）';
      status.value = FeedStatus.reconnecting;
    } else if (status.value == FeedStatus.connecting) {
      status.value = FeedStatus.reconnecting;
    }
  }

  /// 下一次轮询的延迟：正常节奏，或退避后的节奏。
  ///
  /// 退避按 2 倍增长、封顶 [AppConfig.pollBackoffMax]。为什么失败还要继续问：
  /// 这是自用的盯盘界面，用户会一直看着它——主动放弃不如把节奏放慢，
  /// 网络一恢复就能自己好起来，不需要用户手动点重试。
  Duration _delay() {
    if (_backoffLevel <= 0) {
      return _interval;
    }
    final int factor = 1 << (_backoffLevel.clamp(0, 4));
    final Duration d = _interval * factor;
    return d > AppConfig.pollBackoffMax ? AppConfig.pollBackoffMax : d;
  }

  /// 低于这个量级的「未来」时间戳按设备时钟偏差处理，不丢弃。
  ///
  /// 一天的余量要同时满足两件事：容得下设备时钟不准（分钟级）和服务端写入
  /// 延迟，又能在「越界月份被 DateTime 归一化成下一年」这类脏值上兜住。
  static const Duration _maxFutureSkew = Duration(days: 1);

  /// 当前内核声明支持、且订阅里确实存在的那部分标的。
  List<StockConfig> _coveredBy(PollingSource source) => _stocks
      .where((StockConfig s) => source.markets.contains(s.region))
      .toList(growable: false);

  /// 当前内核覆盖不到几只订阅标的（补位源能兜的不算）；全覆盖时返回 null。
  ///
  /// 第二个分支是**补位源自己的健康度**：配置了补位不等于补得上。连续失败
  /// 达到阈值时也要说话，否则「美股卡又不动了」会退回到「神不知鬼不觉」。
  String? _coverageGap(PollingSource source, List<Quote> quotes) {
    final int missing = _stocks
        .where((StockConfig s) => !_canServe(s, source))
        .length;
    if (missing > 0) {
      return '${source.displayName} 不提供 $missing 只标的的行情，它们会停在旧价';
    }
    final PollingSource? backup = regionBackup;
    if (backup != null && _backupFailStreak >= AppConfig.pollFailoverAfter) {
      return '${backup.displayName}（备用源）连续失败，它负责的标的会停在旧价';
    }
    // 市场声明上的覆盖 ≠ 本轮真的拿到了。补位源只供自己声明的市场，
    // 主链偶发漏掉的 A/H 行既补不了、也不会被上面的「声明缺口」发现；
    // 不在这里说话，整轮就会被判成功且界面显示「已连接」。
    final Set<String> got = <String>{
      for (final Quote q in quotes) StockConfig.keyOf(q.code, q.region),
    };
    final int skipped = _stocks
        .where((StockConfig s) => !got.contains(s.key))
        .length;
    if (skipped > 0) {
      return '本轮有 $skipped 只标的没返回行情，它们会停在旧价';
    }
    return null;
  }

  /// [source] 自己或补位源能覆盖这只票的市场吗？
  bool _canServe(StockConfig stock, PollingSource source) =>
      source.markets.contains(stock.region) ||
      (regionBackup?.markets.contains(stock.region) ?? false);

  /// 下一个**能带队**的内核下标；都不行时按原顺序轮转。
  ///
  /// 「能带队」= 至少自己覆盖一个订阅市场（不能全靠补位源）+ 全市场都有人管。
  /// 只订阅美股时，腾讯一个市场都不覆盖，切过去等于空转——即使补位源能供美股，
  /// 也不该把主链切到一个纯摆设上。
  int _nextViableIndex(int from) {
    for (int step = 1; step <= _chain.length; step++) {
      final int index = (from + step) % _chain.length;
      if (_canLead(_chain[index])) {
        return index;
      }
    }
    return (from + 1) % _chain.length;
  }

  /// [source] 能当主力吗：自己至少覆盖一只订阅标的，且缺口有补位源兜。
  bool _canLead(PollingSource source) =>
      _stocks.any((StockConfig s) => source.markets.contains(s.region)) &&
      _stocks.every((StockConfig s) => _canServe(s, source));

  String _label() {
    final PollingSource? backup = regionBackup;
    final String suffix = backup == null ? '' : ' + 补位 ${backup.displayName}';
    return '${_chain[_activeIndex].displayName}'
        '（主备 ${_chain.length} 个内核$suffix）';
  }

  static String _describe(Object error) {
    if (error is _PollFailure) {
      return error.message;
    }
    if (error is TimeoutException) {
      return '请求超时';
    }
    return '$error';
  }
}

/// 一次轮询的「可解释失败」（HTTP 状态码 / 空报文）
class _PollFailure implements Exception {
  const _PollFailure(this.message);

  final String message;

  @override
  String toString() => message;
}
