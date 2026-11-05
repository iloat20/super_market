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
}
