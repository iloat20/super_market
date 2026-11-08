import 'dart:convert';

import '../../config/app_config.dart';
import '../../models/quote.dart';
import '../rest_client.dart';
import 'polling_source.dart';
import 'symbol_catalog.dart';

/// 腾讯财经行情源（备份内核，**不需要 Key**）。
///
/// 为什么要有它：主备两个内核是这类免费源能"稳定运行数年"的全部秘密
/// （开源项目 Ashare 就是这么干的）。新浪挂了、改协议了、被墙了，还有一条路。
/// 这一层加起来的成本只有一个文件。
///
/// ## 与新浪的四处不一致（切换时最容易踩的就是这四个）
///
/// | 项 | 新浪 | 腾讯 |
/// | --- | --- | --- |
/// | 地址 | `hq.sinajs.cn/list=` | `qt.gtimg.cn/q=` |
/// | 分隔符 | `,` | `~` |
/// | 成交量 | 股 | **手（×100）** |
/// | 成交额 | 元 | **万元（×1e4）** |
///
/// 前两项错了会直接解析失败，后两项错了**不会报错**——只会让界面上
/// 成交量少两个数量级，看起来"有数但不对"，比崩掉更难发现。所以单位换算
/// 集中在本文件的 [parseBatchQuotes] 一处，并用注释钉住。
///
/// 实测（2026-11，3 只标的 45s）：RTT 中位 145ms，陈旧中位 3.7-4.5s，
/// 比新浪略慢，作为备份完全够用。
class TencentSource implements PollingSource {
  const TencentSource();

  @override
  String get id => 'tencent';

  @override
  String get displayName => '腾讯财经';

  @override
  List<String> get markets => const <String>['SZ', 'SH', 'HK'];

  // ==================== 批量报价 ====================

  /// A 股：`sz000001` / `sh600519`（两市通用写法）。
  /// 港股：`hk00700`（**5 位代码**，前缀 hk）。
  /// 美股：`usAAPL.OQ` / `usBABA.N`——**交易所后缀必须有**（2026-11-05
  /// 实测 fqkline 接口：NASDAQ=`.OQ`、NYSE=`.N`；qt.gtimg.cn 报价端点
  /// 本身不支持美股，见 markets）。exchange 缺失按 NASDAQ 兜底——搜索侧
  /// 已保证 US 条目必带交易所，这里只是测试兜底。
  static String wireSymbol(StockConfig stock) => switch (stock.region) {
    'HK' => 'hk${stock.code}',
    'US' => 'us${stock.code.toUpperCase()}'
        '${_usSuffix(stock.exchange)}',
    _ => '${stock.region.toLowerCase()}${stock.code}',
  };

  /// 交易所后缀按大写规范化；NYSE / NASDAQ 之外**不猜**。
  ///
  /// 留空后缀会让服务端明确回 `v_pv_none_match`，而不是悄悄按 NASDAQ 试
  /// 一次——后者会把「交易所没验证过」伪装成「这只票没行情」。
  static String _usSuffix(String exchange) {
    final String e = exchange.trim().toUpperCase();
    if (e.isEmpty) {
      return '.OQ'; // 既有兜底：搜索侧保证 US 条目必带交易所
    }
    return switch (e) {
      'NYSE' => '.N',
      'NASDAQ' => '.OQ',
      _ => '',
    };
  }

  /// `https://qt.gtimg.cn/q=sz000001,sh600519`
  @override
  Uri batchQuoteUri(List<StockConfig> stocks) =>
      Uri.https('qt.gtimg.cn', '/q=${stocks.map(wireSymbol).join(',')}');

  /// 腾讯**不校验 Referer**（实测直接 GET 就返回数据），但带上更稳。
  @override
  Map<String, String> requestHeaders() => const <String, String>{
    'Referer': 'https://gu.qq.com',
    'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36',
  };

  /// 解析批量报价。
  ///
  /// 响应长这样（GBK，`~` 分隔，一行一只）：
  /// ```
  /// v_sz000001="51~平安银行~000001~11.48~11.54~11.56~651667~...~20261103100451
  ///   ~-0.06~-0.52~11.70~11.42~11.48/651667/752453594~651667~75245~...";
  /// ```
  ///
  /// 字段下标：
  /// `0` 市场 · `1` 名称 · `2` 代码 · `3` 现价 · `4` 昨收 · `5` 今开 ·
  /// `6` 成交量(手) · `7` 外盘 · `8` 内盘 · `9..28` 五档 ·
  /// `30` 时间 `yyyyMMddHHmmss` · `31` 涨跌额 · `32` 涨跌幅% ·
  /// `33` 最高 · `34` 最低 · `35` 价/量/额 · `36` 成交量(手) · `37` 成交额(万元)
  ///
  /// 注意 `29` 是空串——`~~` 连续两个分隔符，这是它格式里天然存在的空位，
  /// 不是解析错误。所以**下标必须硬编码**，不能"跳过空字段"。
  @override
  List<Quote> parseBatchQuotes(
    List<int> bytes, {
    required List<StockConfig> stocks,
  }) {
    // GBK 用 latin1 逐字节保留（数值字段全是 ASCII）。
    // 名称会变乱码——本类不使用名称，`StockConfig.name` 来自 UTF-8 的目录接口。
    final String text = latin1.decode(bytes, allowInvalid: true);
    final Map<String, StockConfig> bySymbol = <String, StockConfig>{
      for (final StockConfig s in stocks) wireSymbol(s): s,
    };

    final List<Quote> out = <Quote>[];
    for (final String line in text.split('\n')) {
      final int eq = line.indexOf('="');
      if (eq < 0) {
        continue;
      }
      final int keyAt = line.indexOf('v_');
      if (keyAt < 0 || keyAt + 2 >= eq) {
        continue;
      }
      final int end = line.lastIndexOf('";');
      if (end <= eq + 2) {
        continue;
      }
      final String body = line.substring(eq + 2, end);
      if (body.isEmpty) {
        continue; // 代码不存在
      }
      final List<String> f = body.split('~');
      // 至少要读到 38 号（成交额）；少了说明报文结构变了，宁可不要
      if (f.length < 38) {
        continue;
      }

      final String symbol = line.substring(keyAt + 2, eq);
      final StockConfig? stock = bySymbol[symbol];
      if (stock == null) {
        continue;
      }

      final Quote? quote = _toQuote(f, stock);
      if (quote != null && quote.hasFiniteNumbers) {
        out.add(quote);
      }
    }
    return out;
  }

  Quote? _toQuote(List<String> f, StockConfig stock) {
    final double? price = _num(f[3]);
    final double? prevClose = _num(f[4]);
    if (price == null || price <= 0) {
      return null; // 无成交 / 退市：0 价不覆盖已有行情
    }
    // A 股时间戳是 `20261103100451`，港股是 `2026/11/03 13:43:12`——
    // 两个市场连时间格式都不一样，必须各走各的解析
    final DateTime? ts = stock.region == 'HK'
        ? _parseHkTime(f[30])
        : _parseTime(f[30]);
    if (ts == null) {
      return null;
    }

    final double change = prevClose == null || prevClose <= 0
        ? 0
        : price - prevClose;
    final double changePercent = prevClose == null || prevClose <= 0
        ? 0
        : change / prevClose * 100;

    final double? volumeHands = _num(f[6]);
    final double? turnoverWan = _num(f[37]);

    // ⚠️ 港股的单位与 A 股**不同**（实测 2026-11-03 茅台/腾讯对照）：
    //   A 股：量 = 手（×100）、额 = 万元（×10000）
    //   港股：量 = 股（不动）、额 = HKD 元（不动）
    // 验证方法：额 ÷ 量 应该约等于现价。A 股 75245×10000/6516670≈11.5 ✓，
    // 港股 5353940287/13442881≈398≈腾讯现价 ✓。换算错了不会报错，
    // 只会让量级差 100/10000 倍。
    final bool hk = stock.region == 'HK';

    return Quote(
      code: stock.code,
      region: stock.region,
      price: price,
      change: change,
      changePercent: changePercent,
      previousClose: prevClose ?? 0,
      open: _num(f[5]) ?? 0,
      high: _num(f[33]) ?? 0,
      low: _num(f[34]) ?? 0,
      volume: volumeHands == null
          ? 0
          : hk
          ? volumeHands
          : volumeHands * 100,
      turnover: turnoverWan == null
          ? 0
          : hk
          ? turnoverWan
          : turnoverWan * 10000,
      tradingStatus: TradingStatus.unknown,
      timestamp: ts,
      type: 'quote',
      source: QuoteSource.socket,
    );
  }

  /// `20261103100451` → `DateTime(2026, 11, 3, 10, 4, 51)`
  ///
  /// 为什么用固定宽度正则而不是 `substring`：字段偶尔会变成空串（停牌），
  /// `substring` 会抛 RangeError，而这里只需要返回 null 让调用方跳过。
  static final RegExp _timePattern = RegExp(
    r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$',
  );

  static DateTime? _parseTime(String raw) {
    final RegExpMatch? m = _timePattern.firstMatch(raw.trim());
    if (m == null) {
      return null;
    }
    final List<int?> v = <int?>[
      for (int i = 1; i <= 6; i++) int.tryParse(m.group(i) ?? ''),
    ];
    if (v.contains(null)) {
      return null;
    }
    // 范围必须钉死：`DateTime` 构造对超界值**不抛**，会把 13 月归一化成
    // 下一年、把 25 点归一化成次日——脏行必须在这里判死。新浪侧早有这道
    // 校验（sina_source.dart 的 `_parseDateTime`），只有腾讯这条路漏了；
    // 而漏掉的后果不是「这一行解析失败」，是一个**未来时间戳**进入
    // `PollingQuoteFeed._lastQuoteMs` 那只只增不减的棘轮。
    if (!_isPlausible(v[0]!, v[1]!, v[2]!, v[3]!, v[4]!, v[5]!)) {
      return null;
    }
    return DateTime(v[0]!, v[1]!, v[2]!, v[3]!, v[4]!, v[5]!);
  }

  /// 港股时间戳 `2026/11/03 13:43:12` → DateTime。
  ///
  /// Dart 的 `DateTime.tryParse` 不保证接受 `/` 分隔，手动拆更稳。
  static final RegExp _hkTimePattern = RegExp(
    r'^(\d{4})/(\d{1,2})/(\d{1,2}) (\d{1,2}):(\d{2}):(\d{2})$',
  );

  static DateTime? _parseHkTime(String raw) {
    final RegExpMatch? m = _hkTimePattern.firstMatch(raw.trim());
    if (m == null) {
      return null;
    }
    final List<int?> v = <int?>[
      for (int i = 1; i <= 6; i++) int.tryParse(m.group(i) ?? ''),
    ];
    if (v.contains(null)) {
      return null;
    }
    if (!_isPlausible(v[0]!, v[1]!, v[2]!, v[3]!, v[4]!, v[5]!)) {
      return null;
    }
    return DateTime(v[0]!, v[1]!, v[2]!, v[3]!, v[4]!, v[5]!);
  }

  /// 年月日时分秒是否在合法范围内（与新浪侧同一组界）。
  static bool _isPlausible(
    int year,
    int month,
    int day,
    int hour,
    int minute,
    int second,
  ) =>
      year >= 2000 &&
      year <= 2100 &&
      month >= 1 &&
      month <= 12 &&
      day >= 1 &&
      day <= 31 &&
      hour >= 0 &&
      hour <= 23 &&
      minute >= 0 &&
      minute <= 59 &&
      second >= 0 &&
      second <= 59;

  static double? _num(String raw) {
    if (raw.isEmpty) {
      return null;
    }
    final double? v = double.tryParse(raw);
    if (v == null || v.isNaN || v.isInfinite) {
      return null;
    }
    return v;
  }

  // ==================== 代码目录 ====================

  /// 腾讯的目录接口：`getBoardRankList` 按 offset/count 翻页。
  ///
  /// 备用内核的目录也要能独立跑，否则新浪一挂、目录下不下来，
  /// 「换股票」这个功能就跟着废了——而那正是断网时唯一还能用的东西。
  ///
  /// 单页上限没往上试，`count=200` 是保守值；靠「返回空」判定翻到头。
  static const int pageSize = 200;

  static Uri pageUri(int page) => Uri.https(
    'proxy.finance.qq.com',
    '/cgi/cgi-bin/rank/hs/getBoardRankList',
    <String, String>{
      'board_code': 'aStock',
      'sort_type': 'price',
      'direct': 'down',
      'offset': '${page * pageSize}',
      'count': '$pageSize',
    },
  );

  static const Map<String, String> _catalogHeaders = <String, String>{
    'Referer': 'https://gu.qq.com',
    'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36',
  };

  @override
  Future<List<StockConfig>> fetchSymbols({required HttpGetJson httpGet}) async {
    final List<StockConfig> all = <StockConfig>[];
    for (int page = 0; ; page++) {
      if (page > 0) {
        await Future<void>.delayed(AppConfig.catalogRequestGap);
      }
      final HttpJsonResponse res = await httpGet(
        pageUri(page),
        _catalogHeaders,
      );
      if (res.isRateLimited) {
        throw const SymbolFetchException('目录下载被限流，稍后重试', rateLimited: true);
      }
      if (!res.isOk) {
        throw SymbolFetchException('第 ${page + 1} 页：HTTP ${res.statusCode}');
      }
      final CatalogPage one = parseCatalogPage(res.body);
      if (one.isEnd) {
        break;
      }
      all.addAll(one.items);
      if (page + 1 >= AppConfig.catalogMaxPages) {
        break;
      }
    }
    all.sort((StockConfig a, StockConfig b) => a.code.compareTo(b.code));
    return all;
  }

  /// 解析一页目录：`{"code":0,"data":{"rank_list":[{"code":"sh600519","name":"贵州茅台"}]}}`
  ///
  /// 与行情那路一样是「带前缀的代码」，所以市场直接从 `sh`/`sz` 前缀取。
  CatalogPage parseCatalogPage(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return const CatalogPage.empty();
    }
    if (decoded is! Map<String, Object?>) {
      return const CatalogPage.empty();
    }
    final Object? data = decoded['data'];
    if (data is! Map<String, Object?>) {
      return const CatalogPage.empty();
    }
    final Object? rows = data['rank_list'];
    if (rows is! List<Object?>) {
      return const CatalogPage.empty();
    }

    final List<StockConfig> out = <StockConfig>[];
    for (final Object? row in rows) {
      if (row is! Map<String, Object?>) {
        continue;
      }
      final String symbol = '${row['code'] ?? ''}'.toLowerCase();
      final String name = '${row['name'] ?? ''}'.trim();
      if (symbol.length != 8 || name.isEmpty) {
        continue;
      }
      final String code = symbol.substring(2);
      if (code.length != 6 || int.tryParse(code) == null) {
        continue;
      }
      final String region;
      if (symbol.startsWith('sh')) {
        region = 'SH';
      } else if (symbol.startsWith('sz')) {
        region = 'SZ';
      } else {
        continue;
      }
      out.add(StockConfig(code: code, name: name, region: region));
    }
    return CatalogPage(items: out, raw: rows.length);
  }
}
