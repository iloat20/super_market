import 'kline_source.dart';
import 'sina_kline.dart';
import 'tencent_kline.dart';

/// 走势数据的主备顺序：与报价一致，新浪主力、腾讯备用。
///
/// 顺序分开写而不是复用 `PollingSources.defaultChain`：两者的**能力**不一样
/// （报价源会批量取价，走势源要画线），将来很可能出现「报价只有 A 能行、
/// 走势只有 B 能行」的情况。共享一个列表会让它们互相牵制。
abstract final class KlineSources {
  static const List<KlineSource> chain = <KlineSource>[
    SinaKline(),
    TencentKline(),
  ];

  static KlineSource get primary => chain.first;
}
