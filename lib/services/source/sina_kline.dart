import 'dart:convert';

import '../../config/app_config.dart';
import '../../models/kline.dart';
import 'kline_source.dart';
import 'sina_source.dart';

/// 新浪走势数据（主力）。
///
/// ## 为什么用 `quotes.sina.cn` 而不是 `money.finance.sina.com.cn`
///
/// 同一个 K 线数据在微博系有两个入口，**行为不一样**，实测（2026-11-03）：
///
/// | 入口 | scale=240 | scale=1 | 返回形状 |
/// | --- | --- | --- | --- |
/// | `money.finance.../json_v2.php/CN_MarketData.getKLineData` | ✓ | **`null`** | 裸数组 |
/// | `quotes.sina.cn/cn/api/openapi.php/CN_MarketDataService.getKLineData` | ✓ | ✓ | `{"result":{"data":[…]}}` |
///
/// 只有后者支持 1 分钟，所以统一走后者——**一个地址、一种信封、一个解析器**。
/// 顺手纠正一条流传很广的说法：开源项目 Ashare 的注释写「1m 只有腾讯接口」，
/// 在 2026-11 已经不成立（它测的是 `money.finance` 那个入口）。接口会变，
/// 结论要重测。
///
/// ## 三个必须知道的事实
///
/// 1. **日线不含当日**：`scale=240` 最后一根是上一个交易日（实测 11-03 盘中
///    拿到的最新一根是 11-02）。当日那根要由 UI 用实时报价拼——否则图上
///    "今天"这一根永远缺席，而头部数字却在跳，看起来像图卡住了；
/// 2. **分时数据跨日**：`scale=1&datalen=250` 返回的是「最近 250 分钟」，
///    上午 10:45 拉到的是「昨天 10:34 到今天 10:45」。**必须按日期切**，
///    否则左半张图是昨天的走势，还会把昨收基准线画在错误的位置；
/// 3. 这个接口**不需要 `Referer`**（与 `hq.sinajs.cn` 相反，那个少了就 403），
///    带 UA 即可。
class SinaKline implements KlineSource {
  const SinaKline();

  @override
  String get id => 'sina';

  @override
  String get displayName => '新浪财经';

  /// `scale` 就是周期（分钟数）：1 / 5 / 15 / 30 / 60 / 240（日）。
  static const int _dayScale = 240;

  /// 分时取 250 根：一个交易日 240 分钟，多取 10 根保证「刚开盘就能读到
  /// 昨天的尾部」，再按日期切掉。取 240 整会在 09:31 只拿到 1 个点。
  static const int _intradayLength = 250;

  static Uri _uri(StockConfig stock, int scale, int length) => Uri.https(
    'quotes.sina.cn',
    '/cn/api/openapi.php/CN_MarketDataService.getKLineData',
    <String, String>{
      'symbol': SinaSource.wireSymbol(stock),
      'scale': '$scale',
      'datalen': '$length',
    },
  );

  @override
  Uri dailyUri(StockConfig stock, int count) => _uri(stock, _dayScale, count);

  @override
  Uri intradayUri(StockConfig stock) => _uri(stock, 1, _intradayLength);

  /// 这个接口不校验 Referer（实测），UA 是礼貌。
  @override
  Map<String, String> get headers => const <String, String>{
    'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36',
  };

  /// 新浪的 K 线接口**只覆盖沪深**：`symbol=hk00700` 实测返回
  /// `{"result":{"data":null}}`（2026-11-03），港股直接跳过本源，
  /// 不浪费一次注定为空的外网请求。
  @override
  bool supports(StockConfig stock) => stock.region != 'HK';

  /// `{"result":{"status":{"code":0},"status"…,"data":[{"day":"2026-11-02",
  ///   "open":"1410.000","high":"1447.000","low":"1395.020","close":"1439.100",
  ///   "volume":"8269122","ma_price5":1374.36,…}]}}`
  ///
  /// 注意三点：数值是**字符串**（但 `ma_*` 是数字）、成交量单位**股**、
  /// 字段随 `scale` 变化（日线没有 `amount`，分钟线有）。
  @override
  @override
  List<Kline> parseDaily(List<int> bytes, StockConfig stock) {
    final List<Map<String, Object?>> rows = _rows(bytes);
    final List<Kline> out = <Kline>[];
    for (final Map<String, Object?> row in rows) {
      final DateTime? t = _parseDate(row['day']);
      if (t == null) {
        continue;
      }
      final Kline? k = _toKline(
        time: t,
        open: row['open'],
        high: row['high'],
        low: row['low'],
        close: row['close'],
        volume: row['volume'],
      );
      if (k != null) {
        out.add(k);
      }
    }
    out.sort((Kline a, Kline b) => a.time.compareTo(b.time));
    return out;
  }

  @override
  @override
  List<IntradayPoint> parseIntraday(List<int> bytes, StockConfig stock) {
    final List<Map<String, Object?>> rows = _rows(bytes);

    // 先全解析出来，再决定"哪天"——不能边解析边丢：
    // 拉到的可能是「昨天尾盘 + 今天早盘」，得先知道最新日期是哪天。
    final List<_RawPoint> raw = <_RawPoint>[];
    for (final Map<String, Object?> row in rows) {
      final DateTime? t = _parseDate(row['day']);
      if (t == null || t.hour == 0 && t.minute == 0) {
        continue;
      }
      final double? price = _num(row['close']);
      if (price == null || price <= 0) {
        continue;
      }
      raw.add(
        _RawPoint(
          time: t,
          price: price,
          // 1 分钟线的 volume 是**该分钟增量**（股），amount 是该分钟成交额（元）
          volume: _num(row['volume']) ?? 0,
          amount: _num(row['amount']) ?? 0,
        ),
      );
    }
    if (raw.isEmpty) {
      return const <IntradayPoint>[];
    }

    // 切出最新那一天
    DateTime latest = raw.first.time;
    for (final _RawPoint p in raw) {
      if (p.time.isAfter(latest)) {
        latest = p.time;
      }
    }
    final List<_RawPoint> today =
        raw
            .where(
              (_RawPoint p) =>
                  p.time.year == latest.year &&
                  p.time.month == latest.month &&
                  p.time.day == latest.day,
            )
            .toList()
          ..sort((_RawPoint a, _RawPoint b) => a.time.compareTo(b.time));

    // 均价 = 当日累计成交额 ÷ 当日累计成交量。
    // 累计和必须在这里算完（模型只暴露增量），否则 UI 得自己维护累加器，
    // 换个数据源就会算错。
    double cumVolume = 0;
    double cumAmount = 0;
    final List<IntradayPoint> out = <IntradayPoint>[];
    for (final _RawPoint p in today) {
      cumVolume += p.volume;
      cumAmount += p.amount;
      out.add(
        IntradayPoint(
          time: p.time,
          price: p.price,
          avgPrice: cumVolume > 0 ? cumAmount / cumVolume : 0,
          volume: p.volume,
        ),
      );
    }
    return out;
  }

  Kline? _toKline({
    required DateTime time,
    required Object? open,
    required Object? high,
    required Object? low,
    required Object? close,
    required Object? volume,
  }) {
    final double? o = _num(open);
    final double? h = _num(high);
    final double? l = _num(low);
    final double? c = _num(close);
    if (o == null || h == null || l == null || c == null) {
      return null;
    }
    final Kline k = Kline(
      time: time,
      open: o,
      high: h,
      low: l,
      close: c,
      volume: _num(volume) ?? 0, // 股
    );
    return k.isValid ? k : null;
  }

  /// 把信封拆成 `result.data` 那一段。
  ///
  /// 从原始字节解而不是收 `String`：字符集是协议的一部分，让传输层猜
  /// 就等于把最容易出错的东西交给了不懂协议的那一层（同 `PollingSource`）。
  List<Map<String, Object?>> _rows(List<int> bytes) {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } on FormatException {
      return const <Map<String, Object?>>[];
    }
    if (decoded is! Map<String, Object?>) {
      return const <Map<String, Object?>>[];
    }
    final Object? result = decoded['result'];
    if (result is! Map<String, Object?>) {
      return const <Map<String, Object?>>[];
    }
    final Object? data = result['data'];
    if (data is! List<Object?>) {
      return const <Map<String, Object?>>[];
    }
    return <Map<String, Object?>>[
      for (final Object? row in data)
        if (row is Map<String, Object?>) row,
    ];
  }

  /// `"2026-11-02"` 与 `"2026-11-03 10:40:00"` 两种格式。
  ///
  /// 用 `DateTime.parse` 而不是按分隔符切：它两种都吃，也不会因为将来
  /// 多带个时区后缀就崩。
  static DateTime? _parseDate(Object? raw) {
    if (raw is! String || raw.isEmpty) {
      return null;
    }
    return DateTime.tryParse(raw.trim());
  }

  static double? _num(Object? raw) {
    if (raw is num) {
      return raw.toDouble();
    }
    if (raw is! String || raw.isEmpty) {
      return null;
    }
    final double? v = double.tryParse(raw);
    if (v == null || v.isNaN || v.isInfinite) {
      return null;
    }
    return v;
  }
}

class _RawPoint {
  const _RawPoint({
    required this.time,
    required this.price,
    required this.volume,
    required this.amount,
  });

  final DateTime time;
  final double price;
  final double volume;
  final double amount;
}
