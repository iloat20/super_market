/// A 股 / 港股交易时段判断（纯函数，无 I/O，便于单测）。
///
/// 为什么需要它：iTick 只在有成交时推送，收盘后价格就不再变化。
/// 如果界面只显示「已连接」，用户会以为卡住了；显示「已收盘 / 午间休市」
/// 才是对数据静止的正确解释。
///
/// 沪深两市交易时间（北京时间，无夏令时）：
///   09:15–09:25 开盘集合竞价（09:20–09:25 不可撤单，对看盘无差别，这里不细分）
///   09:25–09:30 竞价撮合，暂停申报
///   09:30–11:30 上午连续竞价
///   11:30–13:00 午间休市
///   13:00–15:00 下午连续竞价（14:57–15:00 收盘集合竞价，同上不细分）
///   15:00 之后  已收盘
///
/// 港股（[ofHk]，同样北京时间，无夏令时）：
///   09:00–09:30 开市前时段（竞价，这里并入「未开盘」，对看报价无差别）
///   09:30–12:00 上午连续竞价
///   12:00–13:00 午间休市
///   13:00–16:00 下午连续竞价（16:00–16:10 收市竞价，并入交易中）
///   16:10 之后  已收盘
///
/// 只判断「工作日 + 时段」，不处理法定节假日（需要交易日历，超出 MVP 范围）。
/// 节假日会显示成「交易中」，这是已知限制，已写进 README。
library;

enum MarketSession {
  /// 工作日、开盘前
  preOpen('未开盘'),

  /// 09:15–09:30 开盘集合竞价
  callAuction('集合竞价'),

  /// 09:30–11:30 或 13:00–15:00
  trading('交易中'),

  /// 11:30–13:00
  lunchBreak('午间休市'),

  /// 15:00 之后
  closed('已收盘'),

  /// 周六、周日
  weekend('休市');

  const MarketSession(this.label);

  final String label;

  /// 是否处于「价格会跳动」的时段（集合竞价也算，因为 09:25 会出开盘价）
  bool get isLive =>
      this == MarketSession.trading || this == MarketSession.callAuction;

  /// 根据本地时间判断**沪深 A 股**当前时段
  static MarketSession of(DateTime time) {
    // 周六 = 6，周日 = 7
    if (time.weekday == DateTime.saturday || time.weekday == DateTime.sunday) {
      return MarketSession.weekend;
    }
    final int m = time.hour * 60 + time.minute;
    if (m < _callAuctionStart) {
      return MarketSession.preOpen;
    }
    if (m < _continuousStart) {
      return MarketSession.callAuction;
    }
    if (m < _morningEnd) {
      return MarketSession.trading;
    }
    if (m < _afternoonStart) {
      return MarketSession.lunchBreak;
    }
    if (m < _close) {
      return MarketSession.trading;
    }
    return MarketSession.closed;
  }

  /// 根据本地时间判断**港股**当前时段。
  ///
  /// 与 A 股共用同一组枚举：对界面来说需要的只有「会不会动」和
  /// 「不动该怎么解释」，两地市场的时段形状足够相似，没必要再开一套类型。
  /// 港股的开市前竞价（09:00–09:30）并入「未开盘」——它不出连续价，
  /// 跟盘前没有可见区别。
  static MarketSession ofHk(DateTime time) {
    if (time.weekday == DateTime.saturday || time.weekday == DateTime.sunday) {
      return MarketSession.weekend;
    }
    final int m = time.hour * 60 + time.minute;
    if (m < _hkMorningOpen) {
      return MarketSession.preOpen;
    }
    if (m < _hkLunchStart) {
      return MarketSession.trading;
    }
    if (m < _hkAfternoonStart) {
      return MarketSession.lunchBreak;
    }
    // 16:00–16:10 收市竞价：价格仍可能跳动，算交易中
    if (m < _hkClose) {
      return MarketSession.trading;
    }
    return MarketSession.closed;
  }

  /// 按**订阅市场并集**判断当前时段：只要有一个订阅市场在交易，整页就算
  /// 「交易中」。页头角标与太极共用这个口径，避免出现「角标说已收盘、
  /// 港股还在跳、太极还在转」的自相矛盾。
  ///
  /// [regions] 里 `HK` 走 [ofHk]，其余（SH/SZ）走 [of]；空集合退回 A 股
  /// 口径，保证没传订阅信息的调用方行为不变。
  ///
  /// 合并优先级：交易中 > 集合竞价 > 午间休市 > 未开盘 > 已收盘。
  /// 「休市」只有全部订阅市场都休市时才成立。
  static MarketSession ofRegions(DateTime time, Iterable<String> regions) {
    final Set<MarketSession> sessions = <MarketSession>{
      for (final String region in regions)
        region == 'HK' ? ofHk(time) : of(time),
    };
    if (sessions.isEmpty) {
      return of(time);
    }
    if (sessions.contains(MarketSession.trading)) {
      return MarketSession.trading;
    }
    if (sessions.contains(MarketSession.callAuction)) {
      return MarketSession.callAuction;
    }
    if (sessions.every((MarketSession s) => s == MarketSession.weekend)) {
      return MarketSession.weekend;
    }
    if (sessions.contains(MarketSession.lunchBreak)) {
      return MarketSession.lunchBreak;
    }
    if (sessions.contains(MarketSession.preOpen)) {
      return MarketSession.preOpen;
    }
    return MarketSession.closed;
  }

  static const int _callAuctionStart = 9 * 60 + 15; // 09:15
  static const int _continuousStart = 9 * 60 + 30; // 09:30
  static const int _morningEnd = 11 * 60 + 30; // 11:30
  static const int _afternoonStart = 13 * 60; // 13:00
  static const int _close = 15 * 60; // 15:00

  static const int _hkMorningOpen = 9 * 60 + 30; // 09:30
  static const int _hkLunchStart = 12 * 60; // 12:00
  static const int _hkAfternoonStart = 13 * 60; // 13:00
  static const int _hkClose = 16 * 60 + 10; // 16:10（含收市竞价）
}
