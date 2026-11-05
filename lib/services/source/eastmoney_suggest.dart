import 'dart:convert';

import '../../config/app_config.dart';
import '../../utils/app_log.dart';
import 'symbol_search.dart';

/// 东方财富的搜索建议（公开接口，不需要 Key）。
///
/// ```
/// GET https://searchapi.eastmoney.com/api/suggest/get
///     ?input=银行&type=14&token=<公开固定值>&count=20
/// {"QuotationCodeTable":{"Data":[
///   {"Code":"600000","Name":"浦发银行","MarketType":"1","SecurityTypeName":"沪A"},
///   ...]}}
/// ```
///
/// ## 为什么是它（而不是新浪或腾讯的搜索建议）
///
/// 三家都能「输入即搜」，但只有这家的**联想质量能用**：
///
/// | 源 | 搜「银行」 | 搜「科技」 | 编码 | 条数 |
/// | --- | --- | --- | --- | --- |
/// | 东方财富 | **19 只 A 股** ✓ | **20 只 A 股** ✓ | UTF-8 JSON | 可指定 |
/// | 腾讯 smartbox | 0 只（10 条全是银行 ETF） ✗ | 0 只（9 ETF + 1 指数） ✗ | ASCII 转义 | **固定 10 条** |
/// | 新浪 suggest | 42 条 ✓ | 50 条 ✓ | **GBK** | 50 条 |
///
/// 腾讯那关是硬伤：`t=gp` 参数实测无效（与 `t=all` 返回一样），
/// 每次只给 10 条，而宽泛词的前 10 条会被 ETF / 指数占满——搜「银行」
/// 拿不到工商银行，这不是「排序不理想」，是「搜不到」。
///
/// 新浪质量够，但响应是 GBK，Dart 标准库没有 GBK 编解码，为一个搜索功能
/// 引一张两万字的映射表不划算。东财返回 UTF-8 JSON，`jsonDecode` 直接吃。
///
/// ## 两个必须挡住的点（均实测）
///
/// 1. **`MarketType` 才是市场判据**：`1` = 沪（含科创板 688）、`2` = 深、
///    `_TB` = 北交所。不能靠 `Classify`——科创板的 `Classify` 是 `23`
///    而不是 `AStock`，按 `AStock` 过滤会把中芯国际这类票漏掉。
/// 2. **B 股会混进来**：`200011 深物业B` 的 `MarketType` 也是 `2`，
///    光看市场字段会当成长股。所以还要按号段校验（沪 6 开头、深 0/3 开头）。
class EastmoneySuggest implements SymbolSearch {
  const EastmoneySuggest();

  @override
  String get id => 'eastmoney-suggest';

  @override
  String get displayName => '东方财富';

  /// 一次取多少条。
  ///
  /// 实测 `count` 可以取到 100 都照给。取 20 是因为界面只展示 12 条，
  /// 多出来的用于和本地目录合并去重，再多就只是白传流量。
  static const int maxResults = 20;

  /// 东财网页版用的公开固定 token。
  ///
  /// 实测**不带 token 也能正常返回**（同样 200 + 完整 JSON），带上是照抄
  /// 它的调用约定，避免哪天服务端开始校验。它不是密钥——浏览器地址栏
  /// 里就能看到，所有第三方都在用同一个值。
  static const String _publicToken = 'D43BF722C8E33BDC906FB84D85E326E8';

  @override
  Uri suggestUri(String query) =>
      Uri.https('searchapi.eastmoney.com', '/api/suggest/get', <String, String>{
        'input': query,
        'type': '14', // 全品种，靠下面的字段自己筛
        'token': _publicToken,
        'count': '$maxResults',
      });

  @override
  Map<String, String> get requestHeaders => const <String, String>{
    'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36',
    'Referer': 'https://quote.eastmoney.com/',
  };

  @override
  List<StockConfig> parse(List<int> bytes) {
    if (bytes.isEmpty) {
      return const <StockConfig>[];
    }
    Object? decoded;
    try {
      // allowMalformed：宁可有个别乱码字符，也不要整条搜索失败
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } on FormatException catch (e) {
      AppLog.w('搜索响应不是 JSON: $e');
      return const <StockConfig>[];
    }
    if (decoded is! Map<String, Object?>) {
      return const <StockConfig>[];
    }
    final Object? table = decoded['QuotationCodeTable'];
    if (table is! Map<String, Object?>) {
      return const <StockConfig>[];
    }
    final Object? data = table['Data'];
    if (data is! List<Object?>) {
      // 无结果时 Data 是 null
      return const <StockConfig>[];
    }

    final List<StockConfig> out = <StockConfig>[];
    final Set<String> seen = <String>{};
    for (final Object? row in data) {
      if (out.length >= maxResults) {
        break;
      }
      if (row is! Map<String, Object?>) {
        continue;
      }
      final String region = _regionOf('${row['MarketType'] ?? ''}');
      if (region.isEmpty) {
        continue; // 北交所（_TB）、美股、板块 …
      }
      final String code = '${row['Code'] ?? ''}'.trim();
      final String name = '${row['Name'] ?? ''}'.trim();
      if (name.isEmpty ||
          (region == 'HK'
              ? !_isHkStock(code, name)
              : !_isAShareCode(region, code))) {
        continue;
      }
      final StockConfig stock = StockConfig(
        code: code,
        name: name,
        region: region,
      );
      if (seen.add(stock.key)) {
        out.add(stock);
      }
    }
    return out;
  }

  static String _regionOf(String marketType) {
    switch (marketType) {
      case '1':
        return 'SH';
      case '2':
        return 'SZ';
      case '5':
        return 'HK'; // 港股（实测 00700 / 09988 / 03690 都是 5）
      default:
        return ''; // _TB = 北交所；不支持
    }
  }

  /// 代码是否属于沪深 A 股。
  ///
  /// 这道校验专门挡 B 股：`200011` / `900901` 的 `MarketType` 同样落在
  /// 沪深两市，只看市场字段会把它们当股票加进订阅，然后行情接口对它们
  /// 返回空，界面上是三个 `--` 且不报错。
  static bool _isAShareCode(String region, String code) {
    if (code.length != 6 || int.tryParse(code) == null) {
      return false;
    }
    if (region == 'SH') {
      return code.startsWith('6'); // 600/601/603/605/688/689
    }
    return code.startsWith('0') ||
        code.startsWith('3'); // 000/001/002/003/300/301
  }

  /// 是否属于「能看的港股」。
  ///
  /// `MarketType=5` 里混着四类（全部实测，搜「腾讯 / 阿里巴巴 / 美团」）：
  ///
  /// | 例 | 判据 | 收不收 |
  /// | --- | --- | --- |
  /// | `00700 腾讯控股` / `03690 美团-W` | 正股 | ✓ |
  /// | `09988 阿里巴巴-W`（二次上市） | 正股，代码 9 开头 | ✓ |
  /// | `80700 腾讯控股-R`（人民币柜台） | **代码 8 开头** | ✗ 行情源未验证 |
  /// | `13005 腾讯法兴七三购A`（轮证/牛熊证） | **名称含 购/沽/牛/熊** | ✗ 是衍生品，不是股票 |
  ///
  /// 挡掉 8 开头 + 名称带衍生词，剩下的就是可交易正股。
  /// 轮证/牛熊证的名称特征（购/沽/牛/熊）。提升为 static：
  /// parse 对每行结果都要过一遍，不该每次新建 RegExp
  static final RegExp _hkDerivativePattern = RegExp(r'[购沽牛熊]');

  static bool _isHkStock(String code, String name) {
    if (code.length != 5 || int.tryParse(code) == null) {
      return false; // 港股代码固定 5 位数字
    }
    if (code.startsWith('8')) {
      return false; // 人民币柜台（-R）
    }
    return !name.contains(_hkDerivativePattern);
  }
}
