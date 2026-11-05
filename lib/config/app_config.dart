// 全局配置：订阅股票、轮询与目录抓取参数。
//
// 这里只放「跟数据源无关」的策略参数。协议相关的（地址、帧格式、字段名）
// 全在 lib/services/source/ 里，按 PollingSource 接口实现。
//
// 数据源只有新浪 / 腾讯公开接口：**零凭证**，没有 API Key 概念。

/// 单只股票的静态配置（代码、名称、市场）。
class StockConfig {
  const StockConfig({
    required this.code,
    required this.name,
    required this.region,
  });

  /// 纯数字代码，如 000001（A 股代码有前导零，不要转 int）
  final String code;

  /// 展示用名称
  final String name;

  /// 市场代码：SH = 沪市，SZ = 深市。
  ///
  /// 这个取值同时是"标的身份"的一部分：`000001` 在深市是平安银行、
  /// 在沪市是上证指数，所以任何按键索行情的地方都必须带上它。
  final String region;

  /// 标的在**本 App 内部**的身份键。
  ///
  /// 刻意不用协议格式（iTick 的 `000001$SZ`）：notifier 的键、判重、
  /// 存档比对都属于内部语义，不该因为换了个数据源就全变一遍。
  /// 协议格式由 `QuoteSource.formatSymbol` 单独负责。
  String get key => '$code@$region';

  /// 按代码 + 市场拼身份键（行情回调里只有这两个字段，没有 [StockConfig]）
  static String keyOf(String code, String region) => '$code@$region';

  /// 值相等：订阅列表要判重、要和本地存档比对，必须按内容比较。
  ///
  /// 注意 region 也参与比较：`000001` 在 SZ 是平安银行、在 SH 是上证指数，
  /// 只比 code 会把两个完全不同的标的当成同一只。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StockConfig &&
          other.code == code &&
          other.region == region &&
          other.name == name;

  @override
  int get hashCode => Object.hash(code, region, name);

  @override
  String toString() => 'StockConfig($name $code@$region)';
}

abstract final class AppConfig {
  // ============ 股票列表（公开源配额内随意加减）============

  /// **首次安装**（或存档丢失）时的默认订阅。
  ///
  /// 只影响"没有存档"这一条路：用户改过一次订阅之后，一切以磁盘存档为准
  /// （`WatchlistRepository.load`）。所以改这里不会动到已有用户的列表——
  /// 反过来说，想在老设备上换股票，得在界面里改，不是改代码。
  ///
  /// 2026-11-05 按用户的实际自选换成这四只（原为平安银行/贵州茅台/五粮液）。
  /// 长鑫科技 688825 是 2026-07-27 上市的科创板 DRAM 厂，代码别写成 688xxx 以外。
  static const List<StockConfig> stocks = <StockConfig>[
    StockConfig(code: '000651', name: '格力电器', region: 'SZ'),
    StockConfig(code: '688825', name: '长鑫科技', region: 'SH'),
    StockConfig(code: '000933', name: '神火股份', region: 'SZ'),
    StockConfig(code: '01378', name: '中国宏桥', region: 'HK'),
  ];

  /// 公开源（新浪 / 腾讯）的订阅上限。
  ///
  /// 30 是**实测过的**：一次 `list=` 带上 30 只，全部返回、没有截断
  /// （响应 7.7KB）。再往上没试过，所以不承诺更多——这个数字的作用是
  /// 防止列表无限长，而不是系统真的只能到 30。
  static const int publicSourceMaxStocks = 30;

  // ============ REST 的超时参数 ============

  /// REST 请求超时
  static const Duration restTimeout = Duration(seconds: 10);

  /// 股票目录缓存有效期（成分股/简称变动不频繁，一个月足够了）
  static const Duration symbolCacheTtl = Duration(days: 30);

  // ============ 轮询（公开免费源：新浪 / 腾讯）============
  //
  // 这里的数字全部来自实测，不是猜的。改之前先看 `tool/` 下的探针。

  /// 轮询间隔。
  ///
  /// 为什么是 3 秒而不是 300ms：实测「轮询越快越旧」——新浪 / 腾讯都在服务端
  /// 做了缓存，设定 300ms 时有效刷新率反而只有 7 次/分钟（多个请求命中同一份
  /// 缓存，并且会触发限流），设定 3000ms 时是 17.9 次/分钟、p90 陈旧 5.2s。
  /// 也就是说**在安全间隔以下，加快只会让数据更旧**。
  ///
  /// 3s 是实测里「有效刷新率最高 + 不被限流」的拐点。
  /// 2026-11-04 试过收紧到 2s 并真网验证：新浪服务端快照本身就是**固定 3s
  /// 更新**（报价时间戳 36→39→42→45 严格等差），2s 轮询每两发就有一次拿回
  /// 同一份缓存——有效刷新率不变，请求量却多 50%。维持 3s。
  static const Duration pollInterval = Duration(seconds: 3);

  /// 连续失败多少次换下一个内核。
  ///
  /// 取 3 而不是 1：偶发的一次超时不该让整个界面切源（会让状态胶囊闪一下、
  /// 日志也多一行噪音）。连续 3 次（约 9s）才认定这个源真的不行。
  static const int pollFailoverAfter = 3;

  /// 全部内核都失败时，轮询退避的上限（不会无限拉长）
  static const Duration pollBackoffMax = Duration(seconds: 30);

  /// 拉股票目录时，**串行兜底路径**两页之间的间隔。
  ///
  /// 正常路径已经不走这里了（并发抓取，见 [catalogConcurrency]）。
  /// 保留它是因为「拿不到总数接口」时会退化成串行扫到底——那时候
  /// 慢一点无所谓，别把免费接口敲死才重要。
  static const Duration catalogRequestGap = Duration(milliseconds: 400);

  /// 单页失败重试次数（实测新浪网关在密集翻页时会偶发 502）
  static const int catalogRetries = 3;

  /// 目录翻页的硬上限（防御：接口异常返回重复数据时不要无限翻）
  ///
  /// 新浪实测 70 页、腾讯约 28 页（5577 / 200），留一倍余量。
  static const int catalogMaxPages = 200;

  /// 目录抓取失败后的重试冷却。
  ///
  /// 没有它的话：缓存损坏/为空 + 源持续不可用时，每次打开添加面板都会
  /// 重新触发 6 并发 × 200 页上限的全量抓取（R-11）。冷却期内保持现状
  /// （旧缓存或上次的错误提示），过了冷却再试一次。
  static const Duration symbolRetryCooldown = Duration(minutes: 10);

  /// 并发拉目录的页数。
  ///
  /// 实测（2026-11-03 盘中，56 页 / 5577 条，全部 0 失败）：
  ///
  /// | 并发 | 耗时 |
  /// | --- | --- |
  /// | 1（原串行 + 400ms 间隔） | 68.6s |
  /// | 4 | 6.8s |
  /// | 6 | 4.8s |
  /// | 8 | 3.8s |
  ///
  /// 取 6 不取 8：8 路只快 1s，但对一个免费接口来说并发已经偏高，
  /// 而目录是后台预热的，用户感觉不到这 1s。多留一点余量给「今天网络不好」。
  ///
  /// ⚠️ 每页条数的硬上限是 **100**（传 1000 也只会返回 100 条，HTTP 200、
  /// 不报错）。所以页数下限是 `总数 / 100`，调大这个参数不会更少页。
  static const int catalogConcurrency = 6;

  /// 搜索输入防抖。
  ///
  /// 250ms：中文输入法打一个词的过程中会连续触发 `onChanged`，
  /// 不防抖的话「贵州茅台」四个字要发 4 次请求。而实测一次搜索只要
  /// 170–380ms，250ms 的等待在体感上几乎不存在，比「每敲一个字闪一下」
  /// 好得多。
  static const Duration searchDebounce = Duration(milliseconds: 250);

  // ============ 走势图（日 K / 分时）============

  /// 走势数据的缓存有效期。
  ///
  /// 30 秒的由来：分时线在交易时段每分钟才多一根，日线一天才多一根，
  /// 30 秒完全够"详情页里两个 tab 来回切"这种操作不去重复打外网。
  /// 再长就出现「图上最后一根和头部价格差得远」的观感问题——虽然我们
  /// 会用实时报价补最后一根，但补的是**价格**，补不了成交量的缺。
  static const Duration klineCacheTtl = Duration(seconds: 30);
}
