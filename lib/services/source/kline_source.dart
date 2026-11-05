import '../../config/app_config.dart';
import '../../models/kline.dart';

/// 走势图数据源。
///
/// 与 `PollingSource` 分开而不是合并：报价是**高频、必须极稳**的一条路
/// （3s 一轮，错了整块列表就是错的），K 线是**低频、可以失败**的装饰性数据
/// （打开详情页才拉一次）。把两者塞进同一个接口，只会让报价层背上一堆
/// 它根本用不到的成员——这正是上一轮把 `MarketDataSource` 反向拆成
/// `SymbolCatalog` 时学到的：**接口按"谁需要"切，不按"谁像"切。**
///
/// 只有 4 + 2 个成员。日线和分时各自一个地址、一个解析函数，没有"帧构造"
/// 这类推送专属概念——K 线全是无状态 GET。
abstract interface class KlineSource {
  String get id;

  String get displayName;

  /// 日线地址。[count] 是想要的根数，服务端通常有上限。
  Uri dailyUri(StockConfig stock, int count);

  /// 当日分时地址（1 分钟粒度）。
  Uri intradayUri(StockConfig stock);

  /// 请求头。两个源对 Referer 的要求不同（新浪行情必须带、K 线不必），
  /// 由各自的实现决定。
  Map<String, String> get headers;

  /// 解析日线。
  ///
  /// **解析不出来返回空列表，不要抛**：主备切换靠"空了就换下一个"驱动，
  /// 抛异常会把这条链变成 try/catch 套娃，而且丢不出"哪一段坏了"的信息。
  ///
  /// [stock] 必须带：成交量单位是市场事实（A 股手、港股股），解析层
  /// 没有它就没法换算。地址怎么拼和字节怎么读必须共享同一个市场口径。
  List<Kline> parseDaily(List<int> bytes, StockConfig stock);

  /// 解析当日分时。返回的点必须已按时间升序、且 `volume` 是**增量**。
  List<IntradayPoint> parseIntraday(List<int> bytes, StockConfig stock);

  /// 这个源是否支持该标的。不支持（如新浪没有港股 K 线）的源会被
  /// loader 直接跳过，**不发请求**——省一次注定为空的外网往返。
  bool supports(StockConfig stock) => true;

  /// 一页多少根日线——数据层 `count` 参数的语义单位。
  ///
  /// 80 根 ≈ 四个月。
  ///
  /// 为什么不是 120：手机竖屏的绘图区只有 350px 左右，120 根时每根只分到
  /// 2.9px，蜡烛会被压成一根根竖针，红绿交错看起来像一条渐变带；80 根时
  /// 每根 4.4px，实体和影线终于分得开。
  static const int dailyPageStep = 80;

  /// 打开详情页时默认要多少根日线 = 一页。
  static const int defaultDailyCount = dailyPageStep;

  /// 日线最多取多少根 = 三页 ≈ 一年。
  ///
  /// **不是接口上限**：实测新浪 `datalen=500` 照样返回 500 根。这是可读性
  /// 上限——绘图区约 350px，240 根时每根只剩 1.46px，蜡烛退化成一条色带，
  /// 只能看出趋势、看不出单根。`KlineLoader` 把调用方传进来的 `count`
  /// 夹在这个值以内，UI 不再提供翻页入口，默认固定取 [defaultDailyCount]。
  static const int maxDailyCount = 240;
}
