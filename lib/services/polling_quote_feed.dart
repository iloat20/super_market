import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../models/quote.dart';
import '../utils/app_log.dart';
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
       _now = now ?? DateTime.now,
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
    _cancelTimer();
    status.value = FeedStatus.connecting;
    lastError.value = null;
    _schedule(Duration.zero);
  }

  @override
  void updateStocks(List<StockConfig> next) {
    if (_sameStocks(next, _stocks)) {
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
      return;
    }
    _busy = true;
    final PollingSource source = _chain[_activeIndex];
    try {
      final HttpRawResponse res = await _httpGet(
        source.batchQuoteUri(_stocks),
        source.requestHeaders(),
      ).timeout(_timeout);

      if (!res.isOk) {
        throw _PollFailure(res.failureLabel);
      }
      final List<Quote> quotes = source.parseBatchQuotes(
        res.body,
        stocks: _stocks,
      );
      if (quotes.isEmpty) {
        // HTTP 200 但一条都解析不出来：报文结构变了，或者全是被过滤的脏数据。
        // 这比 404 更危险（看起来是成功的），所以按失败处理并换源。
        throw const _PollFailure('响应里没有可用的报价');
      }
      _onSuccess(quotes);
    } on Object catch (e) {
      _onFailure(e);
    } finally {
      _busy = false;
      if (!_disposed && !_paused) {
        _schedule(_delay());
      }
    }
  }

  void _onSuccess(List<Quote> quotes) {
    // dispose 与在途请求是并发的（dispose 不等一轮轮询结束）：请求落地时
    // notifier 可能已经释放，继续走只会把「A ValueNotifier was used after
    // being disposed」吞成一条假失败日志。
    if (_disposed) {
      return;
    }
    _failStreak = 0;
    if (_backoffLevel != 0) {
      _backoffLevel = 0;
      AppLog.i('轮询已恢复，退避清零');
    }
    if (status.value != FeedStatus.connected || lastError.value != null) {
      AppLog.i('轮询成功：${_chain[_activeIndex].displayName}');
      lastError.value = null;
      status.value = FeedStatus.connected;
    }

    final List<Quote> applied = <Quote>[];
    for (final Quote quote in quotes) {
      final String key = StockConfig.keyOf(quote.code, quote.region);
      final int ms =
          quote.timestamp?.millisecondsSinceEpoch ??
          _now().millisecondsSinceEpoch;
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

  void _onFailure(Object error) {
    // 同 _onSuccess：dispose 后只许安静退出
    if (_disposed) {
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
      _activeIndex = (_activeIndex + 1) % _chain.length;
      if (_activeIndex == 0) {
        _backoffLevel++;
      }
      AppLog.w(
        '${_chain[from].displayName} 连续失败 → '
        '切到 ${_chain[_activeIndex].displayName}',
      );
    } else if (_failStreak >= AppConfig.pollFailoverAfter) {
      // 只有一个内核：没有可切的，直接进退避
      _failStreak = 0;
      _backoffLevel++;
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

  String _label() =>
      '${_chain[_activeIndex].displayName}（主备 ${_chain.length} 个内核）';

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
