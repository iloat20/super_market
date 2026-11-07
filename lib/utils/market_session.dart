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
/// 美股（[ofUs]，输入是本地（北京）挂钟，内部折算成美东挂钟再判）：
///   09:30–16:00 连续竞价（无集合竞价、无午休）
///   周末按**美东**日历判——北京周六凌晨美股周五还在交易，这是两地
///   时差自然形成的「错位周末」，必须先折算再判星期。
///   夏令时（3 月第二个周日 ~ 11 月第一个周日）：北京 = ET + 12；
///   冬令时：北京 = ET + 13。折算只影响时段判定（09:30/16:00 边界
///   都离换制时刻 02:00 很远），±1h 的边界歧义对结果无影响。
///
/// 交易日历（法定节假日、半日市）见 [MarketHolidays]：三个入口都是**先查表
/// 再判时段**——春节、国庆这类「工作日但交易所休市」的日子返回
/// [MarketSession.holiday]，不会再说「交易中」。周末优先于节假日（周末本来
/// 就不开市，也不需要查表）；半日市只改收盘时刻，不改时段形状。
///
/// 美股的时间折算（北京挂钟 → 美东挂钟）不在这里实现：它与日 K 补丁的
/// 「交易日」是同一个规则，统一放在 `trading_day.dart`，避免两处各写一遍。
library;

import '../config/market_holidays.dart';
import 'trading_day.dart';

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
  weekend('休市'),

  /// 法定节假日 / 交易所休市日（可能落在工作日）
  ///
  /// 与 [weekend] 共用「休市」文案：对本 App 的用户来说两者是同一件事——
  /// 今天没有行情可看。分成两个枚举值只为让并集逻辑与测试能区分，
  /// 界面上不必分辨（也不必为多出来的三个字改布局）。
  holiday('休市');

  const MarketSession(this.label);

  final String label;

  /// 是否处于「价格会跳动」的时段（集合竞价也算，因为 09:25 会出开盘价）
  bool get isLive =>
      this == MarketSession.trading || this == MarketSession.callAuction;

  /// 是否整日没有行情（周末或法定节假日）
  bool get isRestDay =>
      this == MarketSession.weekend || this == MarketSession.holiday;

  /// 根据本地时间判断**沪深 A 股**当前时段
  static MarketSession of(DateTime time) {
    if (_isWeekend(time)) {
      return MarketSession.weekend;
    }
    // 沪深同表（MarketHolidays 里的 'A' 分组）
    if (MarketHolidays.isClosedOn(time, 'A')) {
      return MarketSession.holiday;
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
    if (_isWeekend(time)) {
      return MarketSession.weekend;
    }
    if (MarketHolidays.isClosedOn(time, 'HK')) {
      return MarketSession.holiday;
    }
    final int m = time.hour * 60 + time.minute;
    // 半日市（农历除夕 / 圣诞前夕 / 新年前夕）：早市 09:30 起，
    // 12:00–12:10 收市竞价后直接收盘，没有午休也没有午后。
    if (MarketHolidays.isHalfDayOn(time, 'HK')) {
      if (m < _hkMorningOpen) {
        return MarketSession.preOpen;
      }
      return m < _hkHalfDayClose ? MarketSession.trading : MarketSession.closed;
    }
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

  /// 根据**本地（北京）挂钟**判断**美股**当前时段。
  ///
  /// 与 A 股共用同一组枚举（同 [ofHk] 的理由）：美股没有集合竞价和午休，
  /// 这两个状态在美股口径下不会出现。
  ///
  /// 为什么不能直接拿北京的星期判周末：北京周六 03:00 是美东周五 14:00
  /// （盘中）——必须先折算成美东挂钟，再判星期与时段。
  static MarketSession ofUs(DateTime time) {
    final DateTime et = easternWallClock(time);
    if (_isWeekend(et)) {
      return MarketSession.weekend;
    }
    // 节假日按**美东日历日**查表：北京 11/27 凌晨还是美东 11/26（感恩节）
    if (MarketHolidays.isClosedOn(et, 'US')) {
      return MarketSession.holiday;
    }
    // 半日市（感恩节次日 / 平安夜）：13:00 ET 收盘
    final int close = MarketHolidays.isHalfDayOn(et, 'US')
        ? _usHalfDayClose
        : _usClose;
    final int m = et.hour * 60 + et.minute;
    if (m < _usOpen) {
      return MarketSession.preOpen;
    }
    if (m < close) {
      return MarketSession.trading;
    }
    return MarketSession.closed;
  }

  /// 按**订阅市场并集**判断当前时段：只要有一个订阅市场在交易，整页就算
  /// 「交易中」。页头角标与太极共用这个口径，避免出现「角标说已收盘、
  /// 港股还在跳、太极还在转」的自相矛盾。
  ///
  /// [regions] 里 `HK` 走 [ofHk]、`US` 走 [ofUs]，其余（SH/SZ）走 [of]；
  /// 空集合退回 A 股口径，保证没传订阅信息的调用方行为不变。
  ///
  /// 合并优先级：交易中 > 集合竞价 > 全部休市 > 午间休市 > 未开盘 > 已收盘。
  ///
  /// 「全部休市」要求**每个**订阅市场都是周末或节假日：只要有一个市场今天
  /// 开过市（哪怕是已收盘），说「休市」就不准确。全部是休息日时，只要有一处
  /// 是法定节假日就报 [MarketSession.holiday]——周末不写进表，所以「命中
  /// holiday」只可能来自节假日。
  static MarketSession ofRegions(DateTime time, Iterable<String> regions) {
    final Set<MarketSession> sessions = <MarketSession>{
      for (final String region in regions)
        region == 'HK'
            ? ofHk(time)
            : region == 'US'
            ? ofUs(time)
            : of(time),
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
    if (sessions.every((MarketSession s) => s.isRestDay)) {
      return sessions.contains(MarketSession.holiday)
          ? MarketSession.holiday
          : MarketSession.weekend;
    }
    if (sessions.contains(MarketSession.lunchBreak)) {
      return MarketSession.lunchBreak;
    }
    if (sessions.contains(MarketSession.preOpen)) {
      return MarketSession.preOpen;
    }
    return MarketSession.closed;
  }

  static bool _isWeekend(DateTime t) =>
      t.weekday == DateTime.saturday || t.weekday == DateTime.sunday;

  static const int _callAuctionStart = 9 * 60 + 15; // 09:15
  static const int _continuousStart = 9 * 60 + 30; // 09:30
  static const int _morningEnd = 11 * 60 + 30; // 11:30
  static const int _afternoonStart = 13 * 60; // 13:00
  static const int _close = 15 * 60; // 15:00

  static const int _hkMorningOpen = 9 * 60 + 30; // 09:30
  static const int _hkLunchStart = 12 * 60; // 12:00
  static const int _hkAfternoonStart = 13 * 60; // 13:00
  static const int _hkClose = 16 * 60 + 10; // 16:10（含收市竞价）

  // 半日市收盘（12:00 起收市竞价，随机到 12:08–12:10，这里取上限）
  static const int _hkHalfDayClose = 12 * 60 + 10; // 12:10

  // 美股（美东挂钟，无午休）
  static const int _usOpen = 9 * 60 + 30; // 09:30
  static const int _usClose = 16 * 60; // 16:00
  static const int _usHalfDayClose = 13 * 60; // 13:00（感恩节次日 / 平安夜）
}
