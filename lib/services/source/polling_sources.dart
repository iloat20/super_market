import 'eastmoney_us_source.dart';
import 'polling_source.dart';
import 'sina_source.dart';
import 'tencent_source.dart';

/// 轮询内核的**主备顺序表**。
///
/// 这是「换主备」唯一要改的地方：
///
/// ```dart
/// static const List<PollingSource> defaultChain = <PollingSource>[
///   TencentSource(),   // 想拿腾讯当主力就调换这两行
///   SinaSource(),
/// ];
/// ```
///
/// 顺序有意义：第一个是主力，连续失败 [AppConfig.pollFailoverAfter] 次才切下一个，
/// 切到底后回到第一个并放慢节奏。**不按延迟排序**——实测两家 RTT 只差 40ms，
/// 但新浪一次能带更多标的、时间戳更细，作为主力更稳。
abstract final class PollingSources {
  static const List<PollingSource> defaultChain = <PollingSource>[
    SinaSource(),
    TencentSource(),
  ];

  /// **区域补位源**：主链覆盖不到的市场由它兜住，目前只有美股。
  ///
  /// 为什么需要：新浪覆盖 A/H/US，腾讯只有 A/H。没有补位源时，只要订阅里
  /// 有一只美股，`_nextViableIndex` 就永远找不到「覆盖全部」的备源——
  /// 结果不是「美股降级」，而是**整个主备切换都失效**，新浪挂了原地退避。
  /// 有了它，切到腾讯只意味着 A/H 换源，美股继续由东财供数。
  ///
  /// 正常路径**不产生任何额外请求**：只有主链不覆盖美股、或主链这一轮漏了
  /// 美股，才会补一次。
  static const PollingSource regionBackup = EastmoneyUsSource();
}
