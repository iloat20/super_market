import 'dart:convert';

import '../../config/app_config.dart';
import '../../models/kline.dart';
import 'kline_source.dart';
import 'tencent_source.dart';

/// 腾讯走势数据（备用）。
///
/// 主备两个内核用在走势图上，理由和报价一样：新浪挂了图不能白屏。
/// 但它的形状跟新浪差得远，**三处不一致每一处都会静默出错**：
///
/// | 项 | 新浪 | 腾讯 |
/// | --- | --- | --- |
/// | 日线字段顺序 | `open/high/low/close` 有名字 | 数组 `[日期, 开, **收**, **高**, **低**, 量]` |
/// | 成交量 | 股 | **手（×100）** |
/// | 当日 bar | **不含** | **含**（且实时更新） |
///
/// 第二条错了量柱小两个数量级；第一条错了**开收对调**——蜡烛会变成
/// 上一根的反向颜色，而且完全不报错。这是本文件最需要注意的地方。
class TencentKline implements KlineSource {
  const TencentKline();

  @override
  String get id => 'tencent';

  @override
  String get displayName => '腾讯财经';

  // 接口是 `implements`：抽象接口类的**具体成员也会被要求重写**，
  // 所以这里显式声明"全市场支持"，别依赖继承。
  @override
  bool supports(StockConfig stock) => true;

  /// `https://web.ifzq.gtimg.cn/appstock/app/fqkline/get
  ///   ?param=sh600519,day,,,120,qfq`
  ///
  /// 参数是**位置式**的（逗号分隔，空段不能省）：`代码,周期,起,止,根数,复权`。
  /// `qfq` = 前复权。空的那两段是开始/结束日期，留给服务端默认。
  ///
  /// 美股（2026-11-05 实测）：`param=usAAPL.OQ,day,,,80,qfq` 照常返回，
  /// 交易所后缀必须有（NASDAQ=`.OQ`、NYSE=`.N`，见 [TencentSource.wireSymbol]）；
  /// 美股没有 A 股的复权概念，返回的 key 是 `day`（与指数同形状），
  /// 下面的解析本来就两个键都试，不用分支。
  @override
  Uri dailyUri(StockConfig stock, int count) => Uri.https(
    'web.ifzq.gtimg.cn',
    '/appstock/app/fqkline/get',
    <String, String>{
      'param': '${TencentSource.wireSymbol(stock)},day,,,$count,qfq',
    },
  );

  /// `https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=sh600519`
  ///
  /// 这个接口比分钟 K 线更适合画分时：它直接给「时间 价格 累计量 累计额」，
  /// 累计额能算出均价线（分钟 K 线要自己按 amount 累加，精度差一点）。
  @override
  Uri intradayUri(StockConfig stock) => Uri.https(
    'web.ifzq.gtimg.cn',
    '/appstock/app/minute/query',
    <String, String>{'code': TencentSource.wireSymbol(stock)},
  );

  @override
  Map<String, String> get headers => const <String, String>{
    'Referer': 'https://gu.qq.com',
    'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36',
  };

  /// ```json
  /// {"code":0,"msg":"","data":{"sh600519":{
  ///   "qfqday":[["2026-11-03","1450.00","1451.01","1458.00","1435.10","25327"],
  ///             …],
  ///   "qt":{…},"prec":"1439.10","version":"…"}}}
  /// ```
  ///
  /// **指数返回的 key 是 `day` 不是 `qfqday`**（个股才有复权概念）。取错
  /// 直接拿不到数据，所以两个都试——这不是"兼容写法"，是协议事实。
  @override
  @override
  List<Kline> parseDaily(List<int> bytes, StockConfig stock) {
    final Map<String, Object?>? node = _stockNode(bytes);
    if (node == null) {
      return const <Kline>[];
    }
    final Object? rows = node['qfqday'] ?? node['day'];
    if (rows is! List<Object?>) {
      return const <Kline>[];
    }

    final List<Kline> out = <Kline>[];
    for (final Object? row in rows) {
      // 数组顺序是 [日期, 开, 收, 高, 低, 量(手), …]，**不是 OHLC**
      if (row is! List<Object?> || row.length < 6) {
        continue;
      }
      final DateTime? t = _parseDay(row[0]);
      if (t == null) {
        continue;
      }
      final double? o = _num(row[1]);
      final double? c = _num(row[2]);
      final double? h = _num(row[3]);
      final double? l = _num(row[4]);
      if (o == null || c == null || h == null || l == null) {
        continue;
      }
      final Kline k = Kline(
        time: t,
        open: o,
        high: h,
        low: l,
        close: c,
        // ⚠️ A 股的量是手（×100）；港股的量本来就是股（实测 00700 日线，
        // 额 ÷ 量 ≈ 均价可验证）。与 `TencentSource.parseBatchQuotes`
        // 同一套换算纪律：换算错了不报错，量级静默差 100 倍。
        volume: _volumeOf(_num(row[5]) ?? 0, stock),
      );
      if (k.isValid) {
        out.add(k);
      }
    }
    out.sort((Kline a, Kline b) => a.time.compareTo(b.time));
    return out;
  }

  /// ```json
  /// {"code":0,"data":{"sh600519":{"data":{"data":["0930 1450.00 1650 239250000.00",…],
  ///   "date":"20261103"},"qt":{…}}}}
  /// ```
  ///
  /// 每一条是 `HHmm 价格 累计量(手) 累计额(元)`，空格分隔。
  /// **量和额都是当日累计**：直接拿去画量柱会得到一条单调上升的斜线，
  /// 必须差分。差分在解析层做完，模型只暴露增量。
  @override
  @override
  List<IntradayPoint> parseIntraday(List<int> bytes, StockConfig stock) {
    final Map<String, Object?>? node = _stockNode(bytes);
    if (node == null) {
      return const <IntradayPoint>[];
    }
    final Object? inner = node['data'];
    if (inner is! Map<String, Object?>) {
      return const <IntradayPoint>[];
    }
    final Object? rows = inner['data'];
    if (rows is! List<Object?>) {
      return const <IntradayPoint>[];
    }
    final Object? rawDay = inner['date'];
    final DateTime? day = rawDay == null ? null : _parseDayNumber(rawDay);
    // 完全没有 date 时仍按「今天 + 时分」退化（历史行为）；但 date 存在
    // 却是脏值时整批丢弃——用一个被归一化过的日子画全天分时，比没有图更糟。
    if (rawDay != null && day == null) {
      return const <IntradayPoint>[];
    }

    final List<IntradayPoint> out = <IntradayPoint>[];
    double prevVolume = 0;
    for (final Object? row in rows) {
      if (row is! String) {
        continue;
      }
      final List<String> f = row.split(' ');
      if (f.length < 4) {
        continue;
      }
      final DateTime? t = _parseClock(day, f[0]);
      final double? price = _num(f[1]);
      final double? cumHands = _num(f[2]);
      final double? cumAmount = _num(f[3]);
      if (t == null || price == null || price <= 0) {
        continue;
      }
      // ⚠️ A 股的累计量是手（×100）；港股是股（不动）。
      final double cumVolume = _volumeOf(cumHands ?? 0, stock);
      // 差分：这一分钟的增量。累计值偶尔会回退（服务端补数据），
      // 夹到 0 而不是让量柱变成负数。
      final double step = cumVolume - prevVolume;
      prevVolume = cumVolume;
      out.add(
        IntradayPoint(
          time: t,
          price: price,
          avgPrice: cumVolume > 0 && cumAmount != null
              ? cumAmount / cumVolume
              : 0,
          volume: step > 0 ? step : 0,
        ),
      );
    }
    return out;
  }

  /// 取 `data.<symbol>` 这一层。symbol 从请求里带不出来（解析函数只收字节），
  /// 所以"只取第一个"——一次请求只查一只，不存在歧义。
  Map<String, Object?>? _stockNode(List<int> bytes) {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) {
      return null;
    }
    // `code` 非 0 也可能是错的（与报价接口同一套信封习惯），直接当失败
    final Object? code = decoded['code'];
    if (code is num && code != 0) {
      return null;
    }
    final Object? data = decoded['data'];
    if (data is! Map<String, Object?>) {
      return null;
    }
    for (final Object? value in data.values) {
      if (value is Map<String, Object?>) {
        return value;
      }
    }
    return null;
  }

  /// `"2026-11-03"` → DateTime（日线）
  static DateTime? _parseDay(Object? raw) {
    if (raw is! String || raw.isEmpty) {
      return null;
    }
    return DateTime.tryParse(raw.trim());
  }

  /// `"20261103"` → DateTime（分时的 date 字段，没有分隔符）
  static DateTime? _parseDayNumber(Object? raw) {
    if (raw is! String || raw.length != 8) {
      return null;
    }
    final int? y = int.tryParse(raw.substring(0, 4));
    final int? m = int.tryParse(raw.substring(4, 6));
    final int? d = int.tryParse(raw.substring(6, 8));
    if (y == null || m == null || d == null) {
      return null;
    }
    // `DateTime(y, m, d)` 对越界值不抛、只静默归一化（13 月 45 日 →
    // 次年 2 月），脏字段会被洗成一个看似合法的日历日。逐字段比对把
    // 这类输入判死，与新浪 / 腾讯报价侧的 plausibility 闸同口径。
    if (y < 2000 || y > 2100 || m < 1 || m > 12 || d < 1 || d > 31) {
      return null;
    }
    final DateTime parsed = DateTime(y, m, d);
    if (parsed.year != y || parsed.month != m || parsed.day != d) {
      return null;
    }
    return parsed;
  }

  /// `"0930"` + 当日 → DateTime。缺 date 时退化成"今天 + 时分"，
  /// 至少时间轴不会全挤在 1970 年。
  static DateTime? _parseClock(DateTime? day, String hhmm) {
    if (hhmm.length != 4) {
      return null;
    }
    final int? h = int.tryParse(hhmm.substring(0, 2));
    final int? m = int.tryParse(hhmm.substring(2));
    if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) {
      return null;
    }
    final DateTime base = day ?? DateTime.now();
    return DateTime(base.year, base.month, base.day, h, m);
  }

  /// 成交量按市场换算：A 股手 → 股（×100）；港股、美股本来就是股。
  ///
  /// 美股实测（2026-11-05 usAAPL.OQ）：末根量 89637749 ≈ 新浪报价量
  /// 89637676（同一成交量级），且 转手率口径一致——不 ×100。
  static double _volumeOf(double raw, StockConfig stock) =>
      stock.region == 'HK' || stock.region == 'US' ? raw : raw * 100;

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
