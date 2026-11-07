import '../models/quote.dart';
import 'polling_quote_feed.dart';
import 'quote_feed.dart';
import 'source/polling_sources.dart';

/// **当前生效的行情通道**：3s 一次 HTTP 轮询（新浪主 + 腾讯备 + 美股补位），
/// 零凭证。
///
/// 为什么不做「自动降级」的复合 feed：状态语义不一样（一条长连接 vs 每 3s
/// 一次请求），复合起来会让「已连接」到底指什么变得说不清。真要双通道，
/// 正确的做法是在协议层做（同一份数据两个来源比新旧），而不是在连接层做。
abstract final class QuoteFeeds {
  /// 界面上显示的来源名
  static String get label => PollingSources.defaultChain.first.displayName;

  /// 当前源的标识（用于本地缓存文件名：换源不要读到上一个源格式的存档）
  static String get id => PollingSources.defaultChain.first.id;

  /// 构造当前通道
  ///
  /// 显式传补位源：主链（新浪/腾讯）都只管 A/H，美股靠东财补。别把这件事
  /// 交给「构造函数默认值」——生产装配点只有这一处，写出来才看得见。
  static QuoteFeed create({
    required void Function(List<Quote> quotes) onQuotes,
  }) => PollingQuoteFeed(
    onQuotes: onQuotes,
    regionBackup: PollingSources.regionBackup,
  );
}
