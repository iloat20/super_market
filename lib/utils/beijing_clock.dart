/// 「北京挂钟」——本项目所有行情时间戳所在的**时间域**。
///
/// ## 为什么需要它
///
/// 三个数据源的报文时间都是**北京时间且不带时区后缀**
/// （新浪 `2026-11-03 10:04:54`、腾讯 `20261103100451` / `2026/11/03 13:43:12`），
/// 解析器用 `DateTime(y, m, d, ...)` 构造出来的对象，字段是北京钟点，
/// 但它的「绝对时刻」被解释成了**设备本地时区**。
///
/// 于是所有「拿现在跟报价时间戳比」的地方
/// （[isStale]、页头时段角标、太极转不转、卡片「快照」角标）都在隐式假设
/// 「设备本地时区 == UTC+8」：
///
/// | 设备时区 | 后果 |
/// | --- | --- |
/// | UTC+9 | 每条报价凭空老 1 小时 → [kQuoteStaleAfter] 恒被突破，永远显示「快照」；北京 14:00（A 股盘中）被判成「已收盘」 |
/// | UTC+0 | 报价凭空「年轻」8 小时 → 永不陈旧；北京 09:20 的集合竞价被判成「未开盘」 |
///
/// 修法不是把时间戳改成 UTC（那要动三个解析器、所有测试 fixture 和 K 线日期，
/// 收益为零），而是把**「现在的北京挂钟」**也算对：[beijingNow] 返回的对象，
/// 字段是北京钟点、与解析器产物同域，两者相减就是真实流逝时间。
///
/// 在 UTC+8 设备上 [beijingNow] 与 `DateTime.now()` **完全相等**（偏移量为 0），
/// 所以这是一次零行为变更的加固。
library;

/// 北京时区相对 UTC 的固定偏移（中国不实行夏令时）。
const Duration kBeijingOffset = Duration(hours: 8);

/// 此刻的**北京挂钟**。
///
/// 返回的 `DateTime` 带本地标记（`isUtc == false`），字段是北京时间。
/// 与解析器产出的时间戳同域，可直接 `difference`：
///
/// ```dart
/// final Duration age = beijingNow().difference(quote.timestamp!); // 真实年龄
/// ```
///
/// 为什么不用 `DateTime.now().toUtc().add(8h)`：那个结果的 `isUtc == true`，
/// 与本地标记的时间戳相减会按绝对时刻算，差的正是本地时区偏移——等于没修。
DateTime beijingNow() {
  final DateTime now = DateTime.now();
  // now.timeZoneOffset 是「本地比 UTC 快多少」。把它换掉、换成 +8，
  // 就得到「同样是本地标记、但字段为北京钟点」的同一时刻。
  return now.add(kBeijingOffset - now.timeZoneOffset);
}

/// 把任意「北京时间字符串解析出来的本地 DateTime」折算成对应的北京挂钟。
///
/// 目前解析器已经是这个域，此函数用于**跨域**场景（例如把测试注入的
/// UTC 时刻转成北京挂钟）。同域输入应原样返回，不要重复调用。
DateTime toBeijingWallClock(DateTime local) =>
    local.add(kBeijingOffset - local.timeZoneOffset);
