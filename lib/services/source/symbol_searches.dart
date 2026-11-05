import 'eastmoney_suggest.dart';
import 'symbol_search.dart';

/// 搜索建议的**当前实现**。
///
/// 与 [PollingSources] 分开：报价有主备两条链（新浪 ↔ 腾讯自动切换），
/// 搜索只有一条——它的请求只有 200ms、失败时本地目录还能兜住，
/// 再做一套切换逻辑收益很小。
///
/// 为什么主力是东财而不是本项目行情用的新浪（见 [EastmoneySuggest] 的类注释）：
/// 新浪搜索是 GBK；腾讯搜索只给 10 条且宽泛词被 ETF 霸榜（搜「银行」0 只 A 股）。
/// 三家实测下来只有东财的「输入即搜」在**宽泛词**上能给出可用结果。
abstract final class SymbolSearches {
  static const SymbolSearch current = EastmoneySuggest();
}
