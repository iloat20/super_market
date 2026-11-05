/// 走势图用的数据模型。
///
/// 为什么不复用 [Quote]：`Quote` 是「此刻的一只股票」，字段是**标量现状**
/// （现价、今开、最高…）；K 线是**一串时间桶**，两者不是同一个东西。
/// 硬塞进 `Quote` 会让 `hasData`、`trend`、`amplitude` 这些语义全部发虚。
///
/// 单位约定（与 `Quote` 一致，换算全部在**解析层**完成）：
/// 价格元、成交量**股**。腾讯给的是手，必须在它的解析器里 ×100 掉，
/// 否则量柱会比真实值小两个数量级——不会报错，只是图难看。
library;

/// 一根 K 线。
class Kline {
  const Kline({
    required this.time,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });

  final DateTime time;
  final double open;
  final double high;
  final double low;
  final double close;

  /// 该周期内的成交量，单位**股**
  final double volume;

  /// 能不能画。
  ///
  /// 停牌、退市、接口返回占位 0 都会让价格变成 0，直接画会得到一根
  /// 贴在底边的蜡烛，看着像"跌到 0"。这类 bar 一律不进图。
  bool get isValid =>
      open > 0 &&
      high > 0 &&
      low > 0 &&
      close > 0 &&
      high >= low &&
      !time.isBefore(DateTime(1991));

  /// 相对前一根收是涨还是跌。没有前一根时算平（用开盘价比，
  /// 至少不会让首根蜡烛随机染色）。
  bool get isUp => close >= open;

  @override
  String toString() => 'Kline($time o=$open h=$high l=$low c=$close v=$volume)';
}

/// 分时图上的一个点（1 分钟粒度）。
class IntradayPoint {
  const IntradayPoint({
    required this.time,
    required this.price,
    required this.avgPrice,
    required this.volume,
  });

  final DateTime time;

  /// 该分钟的收盘价（分时图的"当前价"）
  final double price;

  /// 当日累计均价（成交额 ÷ 成交量），分时图的黄线。
  ///
  /// 0 表示这个源没给累计成交额，UI 就不画均价线——**不要**用 0 去画，
  /// 那会把黄线拉到横轴底部。
  final double avgPrice;

  /// **该分钟增量**成交量，单位股。不是当日累计。
  ///
  /// 两个源给的都是累计值，差分在解析层做完，UI 拿到的永远是增量；
  /// 否则量柱会画成一条从左到右单调升高的斜线。
  final double volume;

  bool get isValid => price > 0;

  @override
  String toString() => 'IntradayPoint($time p=$price avg=$avgPrice v=$volume)';
}

/// 一次请求的结果：数据 + 是谁给的 + 失败原因。
///
/// 为什么要带 `sourceId`：主备切换是静默的，图上得能看出「这条线是腾讯给的」，
/// 否则备源悄悄生效了也没人知道，图错了更难查。
///
/// 为什么不直接返回 `List`：空列表有两种含义——「今天还没开盘，没有数据」和
/// 「两个源都请求失败了」。UI 对这两种的文案完全不同，所以错误要带出来。
class KlineResult<T> {
  const KlineResult({required this.items, required this.sourceId, this.error});

  const KlineResult.failed(String this.error)
    : items = const <Never>[],
      sourceId = '';

  final List<T> items;

  /// 实际出数据的源（`sina` / `tencent`），全失败时为空串
  final String sourceId;

  /// 全部源都失败时的原因；拿到数据时为 null
  final String? error;

  bool get isEmpty => items.isEmpty;

  bool get hasError => error != null;
}
