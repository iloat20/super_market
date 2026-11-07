/// 东方财富美股报价（公开接口，不需要 Key）。
///
/// ## 为什么要有它
///
/// 美股报价原来只有新浪一家（腾讯 `qt.gtimg.cn` 对美股返回
/// `v_pv_none_match`）。新浪挂掉时，A/H 还能切腾讯，美股卡只能停在最后
/// 一张快照上——用户分不清是「美股本来就不动」还是「源挂了」。这个源就是
/// 那条补位：只在主链拿不到美股时出手，正常路径一个请求都不多花。
///
/// ## 协议事实（2026-11-07 实测）
///
/// ```text
/// GET https://push2.eastmoney.com/api/qt/ulist.np/get
///     ?secids=105.AAPL,106.BABA
///     &fields=f2,f3,f4,f5,f6,f12,f13,f15,f16,f17,f18,f124
///     &fltt=2&invt=2
/// {"rc":0,"data":{"total":2,"diff":[
///   {"f2":342.37,"f3":-0.52,"f4":-1.8,"f5":44703806,"f6":15323860736.0,
///    "f12":"AAPL","f13":105,"f15":345.79,"f16":338.3,"f17":338.73,
///    "f18":344.17,"f124":1793998800}, ...]}}
/// ```
///
/// 字段：`f2` 现价 · `f3` 涨跌幅% · `f4` 涨跌额 · `f5` 成交量(股) ·
/// `f6` 成交额(USD) · `f12` 代码 · `f13` 市场 · `f15` 最高 · `f16` 最低 ·
/// `f17` 今开 · `f18` 昨收 · `f124` **最后成交时刻**（epoch 秒）。
///
/// `secid` 前缀：**105 = NASDAQ、106 = NYSE**（实测这两条就够用——存档层
/// 已经把 AMEX / 优先股 / 多类股挡掉，见 `WatchlistRepository.decode`）。
///
/// ## 三个必须钉住的点（都不是猜的）
///
/// 1. **必须带 `fltt=2&invt=2`**。不带时价格是整数（AAPL = 342370），
///    「除 100 还是除 1000」只能靠猜；带了服务端直接给小数。少一个参数就
///    多一类缩放 bug，不值得。
/// 2. **不存在的代码会被静默丢掉**：一次问 5 个 secid，`total` 可能只有 3，
///    `diff` 里没有的那两只既不报错也不占位。所以解析只认 `f12` 对得上的行，
///    绝不按数组下标映射回订阅列表。
/// 3. **停牌 / 无数据的行给 `"-"` 而不是 0**：数值解析失败就整行跳过——
///    `0` 价覆盖旧价是比「不更新」严重得多的事故。
///
/// ## 与新浪对价（同一天、同一时刻）
///
/// AAPL：东财 342.37 / 昨收 344.17 / -0.52% / 量 44 703 806 /
/// 额 15 323 860 736，新浪 `gb_aapl` 逐字段相同（成交额差 0.0002%）。
/// 时间戳口径不同：新浪 `[3]` 是**页面刷新时刻**（收盘后仍往前走），
/// 东财 `f124` 是**最后成交时刻**（11-06 16:00 ET）。后者更诚实，但也意味着
/// 切源瞬间它可能被 feed 的「防倒退棘轮」判成更旧——等下一次成交自然恢复，
/// 这比让价格倒退安全。
library;

import 'dart:convert';

import '../../config/app_config.dart';
import '../../models/quote.dart';
import '../rest_client.dart';
import 'polling_source.dart';

class EastmoneyUsSource implements PollingSource {
  const EastmoneyUsSource();

  @override
  String get id => 'eastmoney-us';

  @override
  String get displayName => '东方财富';

  /// 只声明美股：主链的 A/H 不受它影响，也不该被它顶替。
  @override
  List<String> get markets => const <String>['US'];

  static const String host = 'push2.eastmoney.com';
  static const String path = '/api/qt/ulist.np/get';

  /// 只取用得到的字段。`f14`（名称）不取：`Quote` 不带名称，传了是白流量。
  static const String _fields = 'f2,f3,f4,f5,f6,f12,f13,f15,f16,f17,f18,f124';

  /// 订阅标的 → 东财 secid（`105.AAPL`）。
  static String secidOf(StockConfig stock) =>
      '${_marketOf(stock.exchange)}.${stock.code.toUpperCase()}';

  /// NYSE 与 NASDAQ 之外**不猜**：AMEX / 优先股 / 多类股在存档层就被挡掉了
  /// （`WatchlistRepository.decode`），真出现未知交易所时按 NASDAQ 试一次——
  /// 与腾讯 `.OQ` 的默认口径一致。
  static int _marketOf(String exchange) => exchange == 'NYSE' ? 106 : 105;

  @override
  Uri batchQuoteUri(List<StockConfig> stocks) =>
      Uri.https(host, path, <String, String>{
        'secids': stocks.map(secidOf).join(','),
        'fields': _fields,
        // 这两个参数只做一件事：让价格以小数返回。见文件头第 1 条。
        'fltt': '2',
        'invt': '2',
      });

  /// 实测不需要 Referer；UA 只是礼貌。
  @override
  Map<String, String> requestHeaders() => const <String, String>{
    'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36',
  };

  @override
  List<Quote> parseBatchQuotes(
    List<int> bytes, {
    required List<StockConfig> stocks,
  }) {
    Object? decoded;
    try {
      // 东财是 UTF-8 JSON（与新浪/腾讯的 GBK 报文不同）
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } on FormatException {
      return const <Quote>[];
    }
    if (decoded is! Map<String, Object?>) {
      return const <Quote>[];
    }
    final Object? data = decoded['data'];
    if (data is! Map<String, Object?>) {
      return const <Quote>[]; // data:null = 一个都没匹配上
    }
    final Object? diff = data['diff'];
    // 批量时是数组；个别端点/单只时给过对象，两种都吃
    final List<Object?> rows = switch (diff) {
      List<Object?> list => list,
      Map<String, Object?> map => map.values.toList(growable: false),
      _ => const <Object?>[],
    };

    final Map<String, StockConfig> byCode = <String, StockConfig>{
      for (final StockConfig s in stocks) s.code.toUpperCase(): s,
    };

    final List<Quote> out = <Quote>[];
    for (final Object? row in rows) {
      if (row is! Map<String, Object?>) {
        continue;
      }
      final StockConfig? stock =
          byCode['${row['f12'] ?? ''}'.trim().toUpperCase()];
      if (stock == null) {
        continue; // 没订阅的代码（服务端不该给，给了也只丢）
      }
      final Quote? quote = _toQuote(row, stock);
      if (quote != null) {
        out.add(quote);
      }
    }
    return out;
  }

  static Quote? _toQuote(Map<String, Object?> row, StockConfig stock) {
    final double? price = _num(row['f2']);
    if (price == null || price <= 0) {
      return null; // "-"（停牌/无数据）或 0 价：绝不能覆盖已有行情
    }
    final DateTime? ts = _timeOf(row['f124']);
    if (ts == null) {
      return null; // 没有时间就无法参与 shouldApplyQuote 的新旧比较
    }
    final double? prev = _num(row['f18']);
    final double change =
        _num(row['f4']) ?? (prev == null || prev <= 0 ? 0 : price - prev);
    final double changePercent =
        _num(row['f3']) ??
        (prev == null || prev <= 0 || change == 0 ? 0 : change / prev * 100);

    return Quote(
      code: stock.code,
      region: stock.region,
      price: price,
      change: change,
      changePercent: changePercent,
      previousClose: prev ?? 0,
      open: _num(row['f17']) ?? 0,
      high: _num(row['f15']) ?? 0,
      low: _num(row['f16']) ?? 0,
      volume: _num(row['f5']) ?? 0, // 股，不换算
      turnover: _num(row['f6']) ?? 0, // USD 元，不换算
      tradingStatus: TradingStatus.normal,
      timestamp: ts,
      type: 'quote',
      source: QuoteSource.socket, // 轮询拿到的就是此刻的最新报价
    );
  }

  /// epoch **秒** → DateTime（本地挂钟）。
  ///
  /// 年份必须钉死：脏值（0、毫秒当秒、越界）会让 `isStale` 得出荒谬结论，
  /// 不如整行丢掉。对齐新浪侧的 2000–2100 校验。
  static DateTime? _timeOf(Object? raw) {
    final double? seconds = _num(raw);
    if (seconds == null || seconds <= 0) {
      return null;
    }
    final int ms = (seconds * 1000).round();
    final DateTime t = DateTime.fromMillisecondsSinceEpoch(ms);
    if (t.year < 2000 || t.year > 2100) {
      return null;
    }
    return t;
  }

  /// 数值字段可能是 num，也可能是字符串（`"342.37"` / `"-"`）。
  static double? _num(Object? raw) {
    final double? v = raw is num
        ? raw.toDouble()
        : raw is String
        ? double.tryParse(raw.trim())
        : null;
    if (v == null || v.isNaN || v.isInfinite) {
      return null;
    }
    return v;
  }

  /// 这个源不提供代码目录（美股只能搜，目录只做 A 股）。
  ///
  /// 返回空而不是抛：`SymbolDirectory` 只拿主源拉目录，这里被误调时
  /// 「没有目录」是事实，不是错误。
  @override
  Future<List<StockConfig>> fetchSymbols({
    required HttpGetJson httpGet,
  }) async => const <StockConfig>[];
}
