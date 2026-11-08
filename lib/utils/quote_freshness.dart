/// 报价新鲜度判定（纯函数，无 I/O，便于单测）。
///
/// ## 为什么需要它
///
/// 界面原来用 `Quote.source` 决定「收盘快照 / 实时推送」，但
/// `QuoteSource.snapshot` 只有 `Quote.asSnapshot()` 会产，而它在整个仓库里
/// **零调用** —— 所有真实报价都从解析器出来、写死 `socket`。结果页脚永远说
/// 「实时推送」，卡片的「快照」角标永不出现：2026-11-05 09:01 真机截图，
/// 显示的是「未开盘 + 更新时间 15:35:45 + 实时推送 · 新浪财经」，
/// 也就是**上一个交易日**的收盘价被标成了实时价。
///
/// 判定只能依赖「这条数据有多旧」，不能依赖交易时段：时段只说明
/// 「现在该不该动」，说不清「这条数据是不是现在的」。盘前 09:01、
/// 周末、午休后打开，都需要同一个词交代同一件事——这不是实时价。
library;

import '../models/quote.dart';

/// 报价「已停止更新」的判决线。
///
/// 3 秒轮询下，5 分钟 = 100 个周期没有任何新数据，不可能是正在跳动的实时价。
/// 上限也安全：A 股最短的自然静止窗口是午间休市 90 分钟，远大于 5 分钟，
/// 休市一定会被判为快照，不会被误认成「还在实时」。
/// 阈值取在两者之间，对两边都不敏感。
const Duration kQuoteStaleAfter = Duration(minutes: 5);

/// 这条报价是否已停止更新（即：现在看到的不是实时价）。
///
/// - 没有行情（`hasData == false`）：返回 false。首屏占位既不是实时也不是
///   快照，界面对它另有「—」的呈现，不该多贴一个「快照」标签。
/// - 有行情但没有时间戳：返回 true。说不清是什么时候的价，就不能叫实时。
/// - 服务端时间戳略超前（分钟级时钟偏差）：返回 false，不因此误标快照；
///   但超前超过一个判决线周期说明本地时钟被调回，此时按**陈旧**处理，
///   否则上一交易日的收盘价会被一直说成实时价。
/// - 时间戳来自报文，是**服务端**的写入时间；本地时区与之相同（A 股/港股
///   报文都是北京时间且不带时区后缀），`difference` 按绝对时刻算，不受
///   夏令时影响。
bool isStale(Quote quote, DateTime now) {
  if (!quote.hasData) {
    return false;
  }
  final DateTime? stamp = quote.timestamp;
  if (stamp == null) {
    return true;
  }
  final Duration age = now.difference(stamp);
  if (age.isNegative) {
    // 小幅超前按设备时钟偏差放过；回拨超过一个判决线周期时，
    // 「不误标偏差」不能再压过「别说旧价是实时价」。
    return age.abs() > kQuoteStaleAfter;
  }
  return age > kQuoteStaleAfter;
}

/// 距离这条报价变成快照还有多久（供 UI 挂一次性定时器用）。
///
/// - 返回 null：**不会再变**。没有行情、没有时间戳（恒陈旧）、或已经陈旧。
///   调用方据此决定「不用挂定时器」。
/// - 返回 [Duration.zero]：正好卡在判决线上。[isStale] 是开区间，此刻仍算
///   实时，下一秒才翻转——调用方要自己补一点余量。
/// - 服务端时间超前时剩余时间会被放大，这里钳到 [kQuoteStaleAfter]：
///   保证最多一个判决线周期就复查一次，不会挂出近 24 小时的定时器。
Duration? staleIn(Quote quote, DateTime now) {
  if (!quote.hasData) {
    return null;
  }
  final DateTime? stamp = quote.timestamp;
  if (stamp == null) {
    return null;
  }
  if (isStale(quote, now)) {
    return null;
  }
  final Duration remaining = kQuoteStaleAfter - now.difference(stamp);
  if (remaining.isNegative) {
    return null;
  }
  return remaining > kQuoteStaleAfter ? kQuoteStaleAfter : remaining;
}
