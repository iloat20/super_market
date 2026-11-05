/// 涨跌方向（A 股习惯：涨红、跌绿、平灰）
enum QuoteTrend { up, down, flat }

/// 行情来源。
///
/// 为什么要区分：iTick **只在有成交时推送**，收盘后价格自然静止。
/// 如果界面只有一个数字、不说来源，用户看到价格不动会以为卡死；
/// 标成「快照」才是对静止数据的正确解释（配合交易时段角标一起看）。
enum QuoteSource {
  /// WebSocket 实时推送
  socket('实时'),

  /// REST 拉取的快照（收盘后 / 开盘前，用于填充首屏）
  snapshot('快照');

  const QuoteSource(this.label);

  final String label;
}

/// 交易状态，对应官方 quote 报文里的 `ts` 字段。
///
/// ⚠️ 注意：`ts` **不是**时间戳（时间戳是 `t`），而是交易状态枚举。
/// 0 正常交易 / 1 停牌 / 2 已退市 / 3 熔断。
enum TradingStatus {
  normal('正常交易'),
  suspended('停牌'),
  delisted('已退市'),
  halted('熔断'),

  /// 未知值：官方后续新增枚举时，不让 UI 崩，也不瞎猜含义
  unknown('—');

  const TradingStatus(this.label);

  final String label;

  static TradingStatus fromCode(int? code) => switch (code) {
    0 => TradingStatus.normal,
    1 => TradingStatus.suspended,
    2 => TradingStatus.delisted,
    3 => TradingStatus.halted,
    _ => TradingStatus.unknown,
  };

  /// 是否需要提示用户「这只票现在不是正常交易」
  bool get isAbnormal =>
      this == TradingStatus.suspended ||
      this == TradingStatus.delisted ||
      this == TradingStatus.halted;
}

/// 单只股票的行情快照。
///
/// 用不可变对象 + `ValueNotifier<Quote>` 承载，UI 侧只做「整对象替换」，
/// 不需要字段级可变状态，避免半更新。
///
/// 字段全部来自官方 quote 报文（见 README 的报文表），没有自造字段：
/// `s` 代码、`ld` 最新价、`o` 今开、`h` 最高、`l` 最低、`p` 昨收、
/// `v` 成交量、`tu` 成交额、`ch` 涨跌额、`chp` 涨跌幅、`t` 时间、`ts` 交易状态。
class Quote {
  const Quote({
    required this.code,
    required this.price,
    this.region = '',
    required this.change,
    required this.changePercent,
    this.previousClose = 0,
    this.open = 0,
    this.high = 0,
    this.low = 0,
    this.volume = 0,
    this.turnover = 0,
    this.tradingStatus = TradingStatus.normal,
    this.timestamp,
    this.type = 'quote',
    this.source = QuoteSource.socket,
  });

  /// 无行情占位（首帧、未订阅成功时使用）
  factory Quote.empty(String code, {String region = ''}) => Quote(
    code: code,
    region: region,
    price: 0,
    change: 0,
    changePercent: 0,
    tradingStatus: TradingStatus.unknown,
  );

  /// 纯数字代码，如 000001
  final String code;

  /// 市场 SH / SZ（可能为空：老报文没带 `r` 时）。
  ///
  /// 为什么必须有它：`000001` 在深市是平安银行、在沪市是上证指数，
  /// 只按代码路由行情会把两个完全不同标的的数据混在一张卡上。
  final String region;

  /// 最新价，0 表示暂无数据
  final double price;

  /// 涨跌额
  final double change;

  /// 涨跌幅，单位是「百分数」，-1.17 表示 -1.17%
  final double changePercent;

  /// 昨收（用于推算涨跌额/涨跌幅，可能为 0）
  final double previousClose;

  /// 今开
  final double open;

  /// 当日最高
  final double high;

  /// 当日最低
  final double low;

  /// 当日成交量（单位以服务端为准，A 股习惯为股）
  final double volume;

  /// 当日成交额（金额）
  final double turnover;

  /// 交易状态（`ts`）
  final TradingStatus tradingStatus;

  /// 行情时间（服务端时间戳，可能为 null）
  final DateTime? timestamp;

  /// 推送类型：quote / tick
  final String type;

  /// 这条行情从哪来（实时推送 / 收盘快照）
  final QuoteSource source;

  /// 是否已拿到有效行情
  bool get hasData => price > 0;

  /// 当日振幅（%）：(高-低)/昨收，昨收为 0 时返回 0
  double get amplitude {
    if (previousClose <= 0 || high <= 0 || low <= 0) {
      return 0;
    }
    return (high - low) / previousClose * 100;
  }

  QuoteTrend get trend {
    if (!hasData) {
      return QuoteTrend.flat;
    }
    final double v = change != 0 ? change : changePercent;
    if (v > 0) {
      return QuoteTrend.up;
    }
    if (v < 0) {
      return QuoteTrend.down;
    }
    return QuoteTrend.flat;
  }

  /// 复制一份并标记为「快照」。
  ///
  /// 解析器只负责字段映射、不关心来源，来源由调用方（REST 客户端）标注，
  /// 这样同一个 QuoteParser 既能解析 WS 推送也能解析 REST 响应。
  Quote asSnapshot() => Quote(
    code: code,
    region: region,
    price: price,
    change: change,
    changePercent: changePercent,
    previousClose: previousClose,
    open: open,
    high: high,
    low: low,
    volume: volume,
    turnover: turnover,
    tradingStatus: tradingStatus,
    timestamp: timestamp,
    type: type,
    source: QuoteSource.snapshot,
  );

  /// 内容相等判定。
  ///
  /// 有了它，`ValueNotifier` 在「价格/时间都没变」的重放报文下不会触发重建，
  /// 也就不会白白重绘玻璃层（BackdropFilter 的模糊是有成本的）。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Quote &&
          other.code == code &&
          other.region == region &&
          other.price == price &&
          other.change == change &&
          other.changePercent == changePercent &&
          other.previousClose == previousClose &&
          other.open == open &&
          other.high == high &&
          other.low == low &&
          other.volume == volume &&
          other.turnover == turnover &&
          other.tradingStatus == tradingStatus &&
          other.timestamp == timestamp &&
          other.type == type &&
          other.source == source;

  @override
  int get hashCode => Object.hash(
    code,
    region,
    price,
    change,
    changePercent,
    previousClose,
    open,
    high,
    low,
    volume,
    turnover,
    tradingStatus,
    timestamp,
    type,
    source,
  );

  @override
  String toString() =>
      'Quote($code\$$region, price=$price, chg=$change, chp=$changePercent, '
      'o=$open h=$high l=$low v=$volume tu=$turnover '
      'status=${tradingStatus.name}, t=$timestamp, src=${source.name})';
}

/// 是否应该用 [incoming] 覆盖 [current]。
///
/// 这是「收盘快照」和「实时推送」并存时唯一的冲突点：
/// REST 快照是**异步**回来的，可能比 WS 推送还晚到，如果无条件覆盖，
/// 就会出现「实时价 11.56 被你刚拉的 15:00 收盘价 11.54 盖回去」这种倒退。
/// 规则：谁的时间戳更新谁生效；同一时刻实时推送优先。
bool shouldApplyQuote(Quote current, Quote incoming) {
  if (!incoming.hasData || !incoming.price.isFinite) {
    // 空数据永远不覆盖已有行情；非有限价格同样不行——hasData 对
    // Infinity 是 true（∞ > 0），漏过去会让 formatPrice 的
    // toStringAsFixed 在 build 里抛 UnsupportedError（R-05）
    return false;
  }
  if (!current.hasData) {
    return true; // 首屏填充：当前没数据，直接接受
  }
  final DateTime? mine = current.timestamp;
  final DateTime? theirs = incoming.timestamp;
  if (theirs == null) {
    return mine == null && incoming.source == QuoteSource.socket;
  }
  if (mine == null) {
    return true;
  }
  if (theirs.isAfter(mine)) {
    return true;
  }
  if (theirs.isAtSameMomentAs(mine)) {
    // 同一时刻：实时推送比快照可信
    return incoming.source == QuoteSource.socket &&
        current.source == QuoteSource.snapshot;
  }
  return false;
}
