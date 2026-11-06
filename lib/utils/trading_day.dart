/// 「某市场的交易日」——把**一个瞬间**折算成**一个日期键**的唯一实现。
///
/// 为什么需要它：本项目里有两种时间，长得像但语义不同，混用不会报错，只会
/// 让图上的最后一根悄悄画错：
///
/// | 来源 | 值 | 语义 |
/// | --- | --- | --- |
/// | `Kline.time` | `DateTime(2026, 11, 3)` | **交易日标签**（腾讯日线的日期串） |
/// | `Quote.timestamp` | `DateTime(2026, 11, 4, 3, 0)` | **北京挂钟的一个瞬间** |
///
/// 直接拿后者的 `.year/.month/.day` 当交易日用，对 A 股 / 港股恰好对（同一个
/// 时区、同一个日历日），对美股**恒定错一天**：北京 11-04 03:00 是美东
/// 11-03 14:00，还在盘中；美股收盘 16:00 ET 已经是北京次日 04:00（夏令时）
/// 或 05:00（冬令时）。所以美股的交易日必须先折算成**美东挂钟**再取日历日。
///
/// 折算规则本身（`-12h` 夏令时 / `-13h` 冬令时、3 月第二个周日起、11 月第一个
/// 周日止）只有这一份。它同时被 `MarketSession.ofUs`（判时段）和日 K 补丁
/// （判交易日）消费——两处各写一遍就是下一个「各自正确、合起来错」。
library;

/// 北京挂钟 → 美东挂钟（返回的 `DateTime` 只有字段有意义，时区仍是本地）。
///
/// 先按夏令时（`-12h`）折算，看折算结果的日期是否落在夏令时窗口内：在就用
/// 它，不在回退到冬令时（`-13h`）。窗口按 2007 年起的美国规则：
/// 3 月第二个周日 02:00 起、11 月第一个周日 02:00 止（美东当地挂钟）。
///
/// 换制日（02:00–03:00）折算有 ±1h 歧义，但那远离 09:30/16:00 的时段边界，
/// 对「时段判定」没有影响；对「交易日」也只在北京 12:00–13:00 这一小时里
/// 才可能跨日（见 [tradingDayOf] 的测试）。
DateTime easternWallClock(DateTime beijing) {
  final DateTime edt = beijing.subtract(const Duration(hours: 12));
  return _inUsDst(edt) ? edt : beijing.subtract(const Duration(hours: 13));
}

/// 某个瞬间在 [region] 市场所处的**交易日**（零点；只有年月日有意义）。
///
/// `US` 走美东挂钟的日历日；`SH` / `SZ` / `HK` 以及**空的或未知的**
/// region（老报文没有 `r` 字段）都按北京挂钟同日——与 `Kline.time` 的
/// 标签口径一致，不引入第二个假设。
DateTime tradingDayOf(DateTime beijing, String region) {
  final DateTime wall = region == 'US' ? easternWallClock(beijing) : beijing;
  return DateTime(wall.year, wall.month, wall.day);
}

/// 美东挂钟是否处于夏令时（判定输入本身必须是美东挂钟）。
bool _inUsDst(DateTime et) {
  if (et.month > 3 && et.month < 11) {
    return true;
  }
  // 3 月：第二个周日（第一个周日 + 7）当天起
  if (et.month == 3) {
    return et.day >= _firstSundayOf(et.year, 3) + 7;
  }
  // 11 月：第一个周日当天 02:00 止，整天按冬令时算（02:00 前的歧义无关痛痒）
  if (et.month == 11) {
    return et.day < _firstSundayOf(et.year, 11);
  }
  return false; // 12/1/2 月恒为冬令时
}

/// 某月第一个周日的「日」（Dart `weekday`：周一=1 … 周日=7）。
int _firstSundayOf(int year, int month) {
  final int weekdayOf1st = DateTime(year, month, 1).weekday;
  return 1 + (7 - weekdayOf1st) % 7;
}
