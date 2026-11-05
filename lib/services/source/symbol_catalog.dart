import '../../config/app_config.dart';
import '../rest_client.dart';

/// 代码目录拉取失败。
///
/// 为什么要一个专门的异常类型：目录是**唯一**会连续发很多请求的地方
/// （新浪全市场 70 页、iTick 2 个市场），中间被限流和「参数写错」必须能区分。
/// 前者等一会儿再来，后者等多久都没用。用 `rateLimited` 表达，而不是让
/// 调用方去 `contains('限流')` 字符串匹配。
class SymbolFetchException implements Exception {
  const SymbolFetchException(this.message, {this.rateLimited = false});

  final String message;
  final bool rateLimited;

  @override
  String toString() => message;
}

/// 目录的一页。
///
/// 为什么需要 `raw`（过滤前的条数）：**「这一页被我过滤空了」和
/// 「服务端没有更多了」是两件完全不同的事**。
///
/// 新浪的 `node=hs_a` 除了沪深还包含北交所，而 `sort=symbol&asc=1` 是按
/// 字母序排的——`bj` 在 `sh` / `sz` 前面，所以**第 1~3 页全是北交所**
/// （实测 `bj920000…bj920526`）。如果按「过滤后为空」判定翻到底，目录会
/// 在第一页就结束，最终得到 0 条。
///
/// 这个 bug 单测抓不到（假数据里我随手就给了 sh/sz），是真网探针抓到的。
/// 所以判据必须用 `raw`：只有服务端真的给了 0 条，才算到头。
class CatalogPage {
  const CatalogPage({required this.items, required this.raw}) : valid = true;

  const CatalogPage.empty()
    : items = const <StockConfig>[],
      raw = 0,
      valid = true;

  /// 响应无法解析（网关返回了 HTML / `null` / 结构变了）。
  ///
  /// **和 [isEnd] 是两件事**：`valid == false` 说明"这一页没读到"，
  /// 应当重试；`isEnd` 说明"服务端说没有了"，应当收工。把两者混起来，
  /// 一次网关抖动就会被当成目录结束——实测就是这样少掉 2000 多只票。
  const CatalogPage.invalid()
    : items = const <StockConfig>[],
      raw = 0,
      valid = false;

  /// 过滤后的条目
  final List<StockConfig> items;

  /// 服务端这一页给的原始条数（过滤前）
  final int raw;

  /// 这一页是否读到了合法数据（见 [CatalogPage.invalid]）
  final bool valid;

  /// 服务端已经没有更多数据（而不是"这一页都被过滤了"或"这一页没读到"）
  bool get isEnd => valid && raw == 0;
}

/// 数据源的**身份 + 代码目录**能力（与传输方式无关）。
///
/// 目录接口只留一个方法 [fetchSymbols]，而不是「给个 URI + 自己解析」三件套：
/// 新浪要按页翻 70 次，**翻页是协议的一部分**，不该由调用方
/// （`SymbolDirectory`）知道。调用方只关心「最后一次给我全部」。
abstract interface class SymbolCatalog {
  /// 唯一标识，用于日志 tag 与本地缓存文件名。
  ///
  /// 为什么不写死文件名：换源后旧文件里可能是一份上一个源格式的目录，
  /// 混用比读不到更糟。
  String get id;

  /// 界面上的来源名
  String get displayName;

  /// 该源覆盖的市场（SH / SZ）
  List<String> get markets;

  /// 拉取全市场「代码 + 简称」。
  ///
  /// 失败抛 [SymbolFetchException]；成功返回全部条目（可能上万条）。
  /// [httpGet] 由调用方注入，源只决定「请求哪里、怎么翻页、字段怎么读」。
  Future<List<StockConfig>> fetchSymbols({required HttpGetJson httpGet});
}
