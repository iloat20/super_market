import '../../config/app_config.dart';
import '../../models/quote.dart';
import 'symbol_catalog.dart';

/// 轮询型数据源：没有长连接，客户端按节奏去问。
///
/// 与 `MarketDataSource`（推送型）的区别，是**没有**这些东西：
/// 地址、握手 Header、登录帧、订阅帧、心跳帧、收帧分类。
/// 因为轮询根本不存在「连上之后说什么话」——每次请求都是独立、无状态的。
///
/// 保留的只有三件事：
/// 1. **问哪里**：[batchQuoteUri]，一次带上全部标的；
/// 2. **怎么问**：[requestHeaders]（新浪的 `Referer` 少了就 403）；
/// 3. **怎么读**：[parseBatchQuotes]，原始字节进、`Quote` 出。
///
/// 为什么 [parseBatchQuotes] 收 `List<int>` 而不是 `String`：响应的字符集是
/// 协议事实（新浪/腾讯都是 GBK），交给源自己解码，调用方不需要知道
/// 「该用 utf8 还是 latin1」。把它留在传输层，就等于把最容易出错的细节
/// 交给了不懂协议的那一层。
abstract interface class PollingSource implements SymbolCatalog {
  /// 批量报价地址（一次请求拿全部订阅标的）
  Uri batchQuoteUri(List<StockConfig> stocks);

  /// 请求头（新浪的 `Referer` 少了就 403）。
  /// 公开源不需要凭证，这里与 Token 彻底无关。
  Map<String, String> requestHeaders();

  /// 解析批量报价。
  ///
  /// 解析不出来就返回空列表，**不要抛**——单只票的脏数据不该让整轮轮询失败。
  /// [stocks] 用于把响应里的协议写法映射回内部标的（`Quote` 需要名称所属的
  /// `StockConfig` 才能确定市场和代码）。
  List<Quote> parseBatchQuotes(
    List<int> bytes, {
    required List<StockConfig> stocks,
  });
}
