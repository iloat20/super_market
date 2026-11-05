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
      final String classify = '${row['Classify'] ?? ''}';
      final String region = classify == 'UsStock'
          ? 'US'
          : _regionOf('${row['MarketType'] ?? ''}');
      if (region.isEmpty) {
        continue; // 北交所（_TB）、德股/期货/板块 …
      }
      final String code = '${row['Code'] ?? ''}'.trim();
      final String name = '${row['Name'] ?? ''}'.trim();
      if (name.isEmpty) {
        continue;
      }
      final StockConfig? stock = switch (region) {
        'HK' => _hkOrNull(code, name),
        'US' => _usOrNull(row, code, name),
        _ => _aShareOrNull(region, code, name),
      };
      if (stock == null) {
        continue;
      }
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

  /// A 股行的组装：市场字段 + 号段双闸。
  static StockConfig? _aShareOrNull(String region, String code, String name) {
    if (!_isAShareCode(region, code)) {
      return null;
    }
    return StockConfig(code: code, name: name, region: region);
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

  static StockConfig? _hkOrNull(String code, String name) {
    if (!_isHkStock(code, name)) {
      return null;
    }
    return StockConfig(code: code, name: name, region: 'HK');
  }

  /// 是否属于「能看的美股」，以及它的交易所。
  ///
  /// `Classify=UsStock` 里混着七类（2026-11-05 实测，搜「AAPL / 特斯拉 /
  /// 苹果 / 阿里巴巴 / 拼多多 / brk」）：
  ///
  /// | 例 | TypeUS | 收不收 |
  /// | --- | --- | --- |
  /// | `AAPL 苹果` / `TSLA 特斯拉` | `1` 正股 | ✓ |
  /// | `BABA 阿里巴巴` / `PDD 拼多多` / `NIO 蔚来` | `3` **ADR（中概股全在这）** | ✓ |
  /// | `BRKRP` 优先股 | `2` | ✗ 行情未验证 |
  /// | `AAPB 二倍做多苹果ETF` 等杠杆/收益 ETF | `5` | ✗ |
  /// | `AAPL29 Apple Notes 2029` 债票据 | `6` | ✗ |
  /// | `BRKHW` 权证 / `BRKHU` 单位 | `8` / `9` | ✗ |
  ///
  /// 另两道闸（都实测过）：
  /// 1. **交易所只放 NASDAQ / NYSE**（`JYS` 字段）：腾讯写法要带后缀
  ///    （NASDAQ=`.OQ`、NYSE=`.N`），AMEX 的后缀没验证过——宁可搜不到，
  ///   也别搜到之后三个 `--`；
  /// 2. **代码形状 `^[A-Z]{1,5}$`**：`BRK_B`（伯克希尔-B）这类带下划线的
  ///    多类股，新浪 `gb_brk_b` 实测返回**空串**——放进来就是永远无数据的卡。
  static StockConfig? _usOrNull(Map<String, Object?> row, String code, String name) {
    final String typeUs = '${row['TypeUS'] ?? ''}';
    if (typeUs != '1' && typeUs != '3') {
      return null;
    }
    final String jys = '${row['JYS'] ?? ''}';
    if (jys != 'NASDAQ' && jys != 'NYSE') {
      return null;
    }
    if (!_usCodePattern.hasMatch(code)) {
      return null;
    }
    return StockConfig(code: code, name: name, region: 'US', exchange: jys);
  }

  /// 美股代码：1–5 位大写字母（NYSE/NASDAQ 正股的常见上限是 5 位；
  /// 带点/下划线的多类股单独被这道闸挡住）。
  static final RegExp _usCodePattern = RegExp(r'^[A-Z]{1,5}$');

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
