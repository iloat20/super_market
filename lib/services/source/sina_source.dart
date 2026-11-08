import 'dart:convert';
import 'dart:math' as math;

import '../../config/app_config.dart';
import '../../models/quote.dart';
import '../rest_client.dart';
import '../../utils/app_log.dart';
import 'polling_source.dart';
import 'symbol_catalog.dart';

/// 新浪财经行情源（公开接口，**不需要任何 Key**）。
///
/// 协议全部事实都在这个文件里，`lib/` 其它地方不应再出现：
/// `hq.sinajs.cn`、`list=`、`Referer`、`var hq_str_`、字段下标 0..32、
/// `Market_Center.getHQNodeData`、`node=hs_a`。
///
/// ## 为什么选它作主力
///
/// 实测（2026-11，3 只标的，连续 10 分钟）：
/// - 一次请求拿全部标的（`list=` 逗号分隔），不像 iTick 要每只一发；
/// - 20 连发全部 200，没有限流；RTT 中位 103ms；
/// - 时间戳到**秒**，配合 3s 轮询，p90 陈旧 5.2s（iTick 推送是 1.7s）。
///
/// 也就是说：它比 iTick 慢一点、旧一点，但**不需要 Key、不怕断连**。
/// 这是「自用、随时能看」和「尽可能新」之间的取舍，选前者。
///
/// ## 六个必须挡住的坑（都实测过）
///
/// 1. **必须带 `Referer: https://finance.sina.com.cn`**，否则 403；
/// 2. 响应是 **GBK**，用 utf8 解会直接抛。但数值字段全是 ASCII —— 用
///    `latin1` 逐字节保留即可，本源的 [Quote] 不含名称，不需要 GBK 表；
/// 3. 字段数**不固定**：沪市 34、深市 33，所以日期/时间只能按下标
///    `[30]` / `[31]` 取，不能用「倒数第 3 个」；
/// 4. 单位是**股 / 元**（腾讯是手 / 万元，差 100 倍，切换源时最容易错）；
/// 5. 代码不存在时返回 `var hq_str_xx="";`，HTTP 仍是 200 —— 空串必须跳过；
/// 6. 退市股 `price=0`，若当成真价会覆盖掉卡上已有的价 —— 直接丢弃。
class SinaSource implements PollingSource {
  const SinaSource();

  @override
  String get id => 'sina';

  @override
  String get displayName => '新浪财经';

  @override
  List<String> get markets => const <String>['SZ', 'SH', 'HK', 'US'];

  // ==================== 批量报价 ====================

  /// A 股：`sz000001` / `sh600519`——小写市场前缀 + 代码。
  /// 港股：`rt_hk00700`——**前缀是 `rt_hk`**（realtime-hk），不是 `hk`。
  /// 美股：`gb_aapl`——前缀 `gb_` + **小写**字母代码（2026-11-05 实测，
  /// 不带交易所后缀；`gb_brk_b` 这类带下划线的多类股返回空串，见 README）。
  ///
  /// 与内部身份键 `000001@SZ` 不同：那个是给 notifier / 判重用的，
  /// 换源不该跟着变；这个只是协议写法。
  static String wireSymbol(StockConfig stock) => switch (stock.region) {
    'HK' => 'rt_hk${stock.code}',
    'US' => 'gb_${stock.code.toLowerCase()}',
    _ => '${stock.region.toLowerCase()}${stock.code}',
  };

  /// `https://hq.sinajs.cn/list=sz000001,sh600519,sz000858`
  ///
  /// 一次能带多少只？实测 3 只正常，网上常见做法是几十只。数量上限没有再
  /// 往上试——本 App 的订阅列表是个位数，够用就好。
  @override
  Uri batchQuoteUri(List<StockConfig> stocks) =>
      Uri.https('hq.sinajs.cn', '/list=${stocks.map(wireSymbol).join(',')}');

  /// 请求头：`Referer` 是硬要求，`User-Agent` 是礼貌。
  @override
  Map<String, String> requestHeaders() => const <String, String>{
    'Referer': 'https://finance.sina.com.cn',
    'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36',
  };

  /// 解析批量报价。
  ///
  /// 响应长这样（GBK，一行一只）：
  /// ```
  /// var hq_str_sz000001="平安银行,11.560,11.540,11.490,11.700,11.420,
  ///   11.470,11.480,65173875,752536297.040,...,2026-11-03,10:04:54,00";
  /// ```
  ///
  /// 字段下标（沪 34 个 / 深 33 个，前面 10 个含义固定）：
  /// `0` 名称 · `1` 今开 · `2` 昨收 · `3` 现价 · `4` 最高 · `5` 最低 ·
  /// `6` 买一 · `7` 卖一 · `8` 成交量(股) · `9` 成交额(元) ·
  /// `10..29` 五档盘口 · `30` 日期 · `31` 时间 · `32` 状态
  ///
  /// [stocks] 只用来兜底「这条是谁」：解析结果按响应里出现的 key 顺序返回，
  /// 不保证与入参顺序一致。
  @override
  List<Quote> parseBatchQuotes(
    List<int> bytes, {
    required List<StockConfig> stocks,
  }) {
    // GBK 里含 0x7F 以上字节，utf8 解会抛 FormatException；
    // latin1 是「一字节一字符」，数值字段原样保留。
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
      final int keyAt = line.indexOf('hq_str_');
      if (keyAt < 0 || keyAt + 7 >= eq) {
        continue;
      }
      final int end = line.lastIndexOf('";');
      if (end <= eq + 2) {
        continue; // 代码不存在或最后一行不完整
      }
      final String body = line.substring(eq + 2, end);
      if (body.isEmpty) {
        continue; // 代码不存在：HTTP 200 + 空串
      }
      final String symbol = line.substring(keyAt + 7, eq);
      final List<String> f = body.split(',');
      // 字段数不固定：沪 34 / 深 33，低于 32 说明不是个股报文（指数只有 28 个）；
      // 港股报文（rt_hk）只有 19 个有效字段，走它自己的解析分支（见 _toHkQuote）；
      // 美股报文（gb_）要读到 [30] 成交额，低于 31 整行跳过
      if (symbol.startsWith('rt_hk')) {
        if (f.length < 19) {
          continue;
        }
      } else if (symbol.startsWith('gb_')) {
        if (f.length < 31) {
          continue;
        }
      } else if (f.length < 33) {
        // 33 而不是 32：_status(f) 要读 f[32]（状态码）。守卫写成 32 的话，
        // 恰好 32 字段的变体报文会在这里 RangeError——parseBatchQuotes 没有
        // try-catch，一轮解析炸掉整批行情，3s 轮询每轮都失败。
        continue;
      }

      final StockConfig? stock =
          bySymbol[symbol] ?? _matchBySymbol(symbol, stocks);
      if (stock == null) {
        continue;
      }

      final Quote? quote = symbol.startsWith('rt_hk')
          ? _toHkQuote(f, stock)
          : symbol.startsWith('gb_')
          ? _toUsQuote(f, stock)
          : _toQuote(f, stock);
      if (quote != null && quote.hasFiniteNumbers) {
        out.add(quote);
      }
    }
    return out;
  }

  /// 按协议写法在订阅列表里找标的。
  ///
  /// 「响应里出现没订阅的代码」理论上不该发生，但真发生了只能丢——
  /// `StockConfig` 还需要名称，凭空造一个不如不给。
  static StockConfig? _matchBySymbol(
    String symbol,
    List<StockConfig> candidates,
  ) {
    for (final StockConfig s in candidates) {
      if (wireSymbol(s) == symbol) {
        return s;
      }
    }
    return null;
  }

  Quote? _toQuote(List<String> f, StockConfig stock) {
    final double? price = _num(f[3]);
    final double? prevClose = _num(f[2]);
    if (price == null || price <= 0) {
      return null; // 退市 / 停牌 / 无成交：0 价绝不能覆盖已有行情
    }

    final DateTime? ts = DateTime.tryParse('${f[30]} ${f[31]}');
    if (ts == null) {
      return null; // 没有时间就无法参与 shouldApplyQuote 的新旧比较
    }

    final double change = prevClose == null || prevClose <= 0
        ? 0
        : price - prevClose;
    final double changePercent = prevClose == null || prevClose <= 0
        ? 0
        : change / prevClose * 100;

    return Quote(
      code: stock.code,
      region: stock.region,
      price: price,
      change: change,
      changePercent: changePercent,
      previousClose: prevClose ?? 0,
      open: _num(f[1]) ?? 0,
      high: _num(f[4]) ?? 0,
      low: _num(f[5]) ?? 0,
      volume: _num(f[8]) ?? 0, // 股
      turnover: _num(f[9]) ?? 0, // 元
      tradingStatus: _status(f),
      timestamp: ts,
      type: 'quote',
      // 轮询拿到的就是「此刻的最新报价」，对 UI 而言与推送等价
      source: QuoteSource.socket,
    );
  }

  /// `f[32]` 是两位状态码，实测 `00` = 正常。
  ///
  /// 不知道的取值一律 [TradingStatus.unknown]，**不猜**——猜错会把正常交易
  /// 标成「停牌」，比不标更糟。
  TradingStatus _status(List<String> f) {
    switch (f[32]) {
      case '00':
        return TradingStatus.normal;
      case '01': // 临时停牌（经验值，未逐条验证）
        return TradingStatus.suspended;
      case '02':
        return TradingStatus.delisted;
      default:
        return TradingStatus.unknown;
    }
  }

  /// 港股报文（`rt_hk` 前缀）解析。与 A 股是**两套完全不同的字段表**：
  ///
  /// ```text
  /// TENCENT,腾讯控股,393.200,392.200,402.600,391.800,396.000,3.800,0.969,
  ///   396.000,396.200,5610467382.400,14089693,…,2026/11/03,13:58:18,…
  /// ```
  ///
  /// 下标：`0` 英文名 · `1` 中文名 · `2` 今开 · `3` 昨收 · `4` 最高 ·
  /// `5` 最低 · `6` 现价 · `7` 涨跌 · `8` 涨跌幅% · `9/10` 买一/卖一 ·
  /// `11` 成交额(HKD) · `12` 成交量(**股**) · `17` 日期 · `18` 时间
  ///
  /// 与 A 股最大的不同：涨跌额/涨跌幅是**现成的字段**（7/8），不用自己算；
  /// 日期是 `2026/11/03` 斜杠格式。单位自洽：额 ÷ 量 ≈ 398 ≈ 现价 ✓。
  /// 实测（2026-11-03，腾讯控股 13:58）与腾讯源同价同秒。
  Quote? _toHkQuote(List<String> f, StockConfig stock) {
    final double? price = _num(f[6]);
    if (price == null || price <= 0) {
      return null;
    }
    final DateTime? ts = _parseHkDateTime(f[17], f[18]);
    if (ts == null) {
      return null;
    }
    final double? prevClose = _num(f[3]);
    final double change =
        _num(f[7]) ??
        (prevClose == null || prevClose <= 0 ? 0 : price - prevClose);

    return Quote(
      code: stock.code,
      region: stock.region,
      price: price,
      change: change,
      // 涨跌幅直接用报文字段；缺了再用涨跌额回算
      changePercent:
          _num(f[8]) ??
          (prevClose == null || prevClose <= 0 || change == 0
              ? 0
              : change / prevClose * 100),
      previousClose: prevClose ?? 0,
      open: _num(f[2]) ?? 0,
      high: _num(f[4]) ?? 0,
      low: _num(f[5]) ?? 0,
      volume: _num(f[12]) ?? 0, // 股，不换算
      turnover: _num(f[11]) ?? 0, // HKD 元，不换算
      tradingStatus: TradingStatus.unknown,
      timestamp: ts,
      type: 'quote',
      source: QuoteSource.socket,
    );
  }

  /// 美股报文（`gb_` 前缀）解析。与 A 股 / 港股又是**一套独立的字段表**
  /// （2026-11-05 实测 `gb_aapl` / `gb_baba` / `gb_pdd` / `gb_nio`）：
  ///
  /// ```text
  /// 苹果,349.5100,5.31,2026-11-05 18:16:10,17.6100,341.5650,354.5000,
  ///   340.9900,351.7300,242.8900,89637676,…,2026,31441204724.8845,…
  /// ```
  ///
  /// 下标：`0` 名称 · `1` 现价 · `2` 涨跌幅% · `3` 时间（**北京时间**）·
  /// `4` 涨跌额 · `5` 今开 · `6` 最高 · `7` 最低 · `8/9` 52 周高/低 ·
  /// `10` 成交量（**股**） · `12` 总市值 · `21..23` 盘前价/幅/额 ·
  /// `24/25` 盘前/收盘时间（美东） · `26` **昨收** · `30` 成交额（USD）。
  ///
  /// 三个最容易踩的坑：
  /// 1. **昨收在 [26] 不在 [5]**——[5] 是今开（A 股报文里 [2] 才是昨收）；
  ///    交叉验证：349.51 − 17.61 = 331.90 = f[26] ✓，且与腾讯 K 线 qt 同值；
  /// 2. 涨跌额/幅是**现成的字段**（4/2），与港股一样不用回算；
  /// 3. 单位自洽：额 ÷ 量 ≈ 现价（3144 亿 ÷ 8964 万 ≈ 350）✓。
  ///
  /// 盘前价（[21]）第一版不展示：它只在盘前时段有意义，且官方收盘价
  /// 才是卡片主价（与新浪网页口径一致）。时间戳 [3] 在盘前也会跳
  /// （盘前价在动），但主价停在昨收——这是源的事实，不是解析错误。
  Quote? _toUsQuote(List<String> f, StockConfig stock) {
    final double? price = _num(f[1]);
    if (price == null || price <= 0) {
      return null; // 退市 / 无成交：0 价绝不能覆盖已有行情
    }
    final DateTime? ts = DateTime.tryParse(f[3].trim());
    if (ts == null) {
      return null; // 没有时间就无法参与 shouldApplyQuote 的新旧比较
    }

    return Quote(
      code: stock.code,
      region: stock.region,
      price: price,
      change: _num(f[4]) ?? 0,
      changePercent: _num(f[2]) ?? 0,
      previousClose: _num(f[26]) ?? 0,
      open: _num(f[5]) ?? 0,
      high: _num(f[6]) ?? 0,
      low: _num(f[7]) ?? 0,
      volume: _num(f[10]) ?? 0, // 股，不换算
      turnover: _num(f[30]) ?? 0, // USD 元，不换算
      tradingStatus: TradingStatus.unknown,
      timestamp: ts,
      type: 'quote',
      source: QuoteSource.socket,
    );
  }

  /// 港股日期 `2026/11/03` + 时间 `13:58:18` → DateTime。
  ///
  /// Dart 的 `DateTime.tryParse` 不保证接受 `/` 分隔，手动拆更稳。
  static DateTime? _parseHkDateTime(String date, String clock) {
    final List<String> d = date.trim().split('/');
    final List<String> t = clock.trim().split(':');
    if (d.length != 3 || t.length < 3) {
      return null;
    }
    final int? y = int.tryParse(d[0]);
    final int? mo = int.tryParse(d[1]);
    final int? day = int.tryParse(d[2]);
    final int? h = int.tryParse(t[0]);
    final int? mi = int.tryParse(t[1]);
    final int? s = int.tryParse(t[2]);
    if (y == null ||
        mo == null ||
        day == null ||
        h == null ||
        mi == null ||
        s == null) {
      return null;
    }
    // 年份/字段范围必须钉死：DateTime 构造对超界值不抛（实测 999999999999
    // 年会被静默接受成无意义时间戳），脏行必须在这里判死。对齐腾讯侧的
    // 固定 4 位年（tencent_source.dart 用 `^(\d{4})` 正则）。
    if (y < 2000 ||
        y > 2100 ||
        mo < 1 ||
        mo > 12 ||
        day < 1 ||
        day > 31 ||
        h < 0 ||
        h > 23 ||
        mi < 0 ||
        mi > 59 ||
        s < 0 ||
        s > 59) {
      return null;
    }
    return DateTime(y, mo, day, h, mi, s);
  }

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

  /// 每页条数。
  ///
  /// **100 是这个接口的硬上限**：传 500 / 1000 / 3000 都只返回 100 条，
  /// HTTP 200、不报错、不带任何提示。所以别指望「把 num 调大就能少翻几页」，
  /// 5577 条至少 56 页——真要快只能并发（见 [AppConfig.catalogConcurrency]）。
  ///
  /// 原来用 80，纯粹是因为当初随手写的；改成 100 直接省掉 14 页。
  static const int pageSize = 100;

  /// 目录总数（实测 190ms 返回 `"5577"` —— 注意是**带引号的 JSON 字符串**）。
  ///
  /// 为什么需要它：并发抓页必须**先知道一共多少页**。原来的「翻到空页为止」
  /// 只适合串行——并发时没人知道该发几个请求。
  ///
  /// 拿不到它也不致命：会退化回串行扫到底（慢，但不会漏票）。
  static Uri countUri() => Uri.https(
    'vip.stock.finance.sina.com.cn',
    '/quotes_service/api/json_v2.php/Market_Center.getHQNodeStockCount',
    <String, String>{'node': 'hs_a'},
  );

  /// 单页地址（纯函数，便于测试）。
  ///
  /// `node=hs_a` 是「沪深 A 股」。注意它**还包含北交所**（返回的 symbol 里
  /// 有 `bj920000`），所以要按前缀过滤掉——把北交所混进来会让搜索里出现
  /// 一堆用户根本没打算订阅的票，而且我们并不支持它的行情。
  static Uri pageUri(int page) => Uri.https(
    'vip.stock.finance.sina.com.cn',
    '/quotes_service/api/json_v2.php/Market_Center.getHQNodeData',
    <String, String>{
      'page': '$page',
      'num': '$pageSize',
      'sort': 'symbol',
      'asc': '1',
      'node': 'hs_a',
      'symbol': '',
      '_s_r_a': 'page',
    },
  );

  /// 目录接口**不需要 Referer**（实测），但需要 UA。
  static const Map<String, String> _catalogHeaders = <String, String>{
    'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36',
  };

  @override
  Future<List<StockConfig>> fetchSymbols({required HttpGetJson httpGet}) async {
    final Map<String, StockConfig> seen = <String, StockConfig>{};
    final int total = await _fetchTotal(httpGet);
    if (total > 0) {
      final int pages = ((total + pageSize - 1) ~/ pageSize).clamp(
        1,
        AppConfig.catalogMaxPages,
      );
      AppLog.i(
        '目录共 $total 条 → $pages 页，'
        '${AppConfig.catalogConcurrency} 路并发',
      );
      await _collectConcurrent(httpGet, pages, seen);
    } else {
      // 总数接口挂了（或返回了看不懂的东西）。
      // 退化回串行扫到底：慢，但**不会漏票**——目录少一半比慢严重得多，
      // 用户会搜不到自己持有的股票，而界面上只显示「没找到」。
      AppLog.w('目录总数不可用，退化为串行翻页');
      await _collectSerial(httpGet, seen);
    }

    final List<StockConfig> all = seen.values.toList()
      ..sort((StockConfig a, StockConfig b) => a.code.compareTo(b.code));
    return all;
  }

  /// 总数接口。
  ///
  /// 返回 `"5577"`（带引号的 JSON 字符串，不是数字）。解析失败一律返回 0，
  /// 由调用方决定退化成串行——这里不抛异常，因为「拿不到总数」不是错误，
  /// 只是少了一条快路径。
  Future<int> _fetchTotal(HttpGetJson httpGet) async {
    try {
      final HttpJsonResponse res = await httpGet(countUri(), _catalogHeaders);
      if (!res.isOk) {
        return 0;
      }
      final Object? decoded = jsonDecode(res.body);
      if (decoded is num) {
        // 1e999 → Infinity，Infinity.toInt() 抛 UnsupportedError（Error），
        // 下面的 on Exception 拦不住；非有限值按「总数未知」处理（返回 0，
        // 由调用方退化成串行兜底）。
        return decoded.isFinite ? decoded.toInt() : 0;
      }
      if (decoded is String) {
        return int.tryParse(decoded.trim()) ?? 0;
      }
    } on Exception catch (e) {
      AppLog.w('目录总数请求失败: $e');
    }
    return 0;
  }

  /// 并发抓完所有页。
  ///
  /// 分批而不是一次全扔出去：56 个请求同时打过去，免费接口很可能直接
  /// 429，而且手机端的并发连接数也有上限。每批 [AppConfig.catalogConcurrency]
  /// 个，批与批之间**不留间隔**——实测 6 路连续跑完全部 56 页，0 失败。
  Future<void> _collectConcurrent(
    HttpGetJson httpGet,
    int pages,
    Map<String, StockConfig> seen,
  ) async {
    int next = 1;
    while (next <= pages) {
      final int end = math.min(next + AppConfig.catalogConcurrency - 1, pages);
      final List<int> batch = <int>[for (int p = next; p <= end; p++) p];
      final List<CatalogPage> got = await _fetchBatch(httpGet, batch);
      _merge(got, seen);
      next = end + 1;
    }
    if (seen.isEmpty) {
      throw const SymbolFetchException('目录为空');
    }
  }

  /// 一批并发请求；**任一页失败就整批退避后串行重试**。
  ///
  /// 为什么不直接让这一批整体失败：并发比串行更容易撞上 429 或网关抖动，
  /// 而目录下载失败会让「换股票」彻底不可用。退一步串行重试是便宜的保险。
  /// 串行还失败就真的抛——残缺的目录比没有目录更糟（它会被缓存 30 天，
  /// 用户搜不到股票却看不出原因）。
  Future<List<CatalogPage>> _fetchBatch(
    HttpGetJson httpGet,
    List<int> batch,
  ) async {
    try {
      return await Future.wait(batch.map((int p) => _fetchPage(httpGet, p)));
    } on SymbolFetchException catch (e) {
      AppLog.w(
        '目录第 ${batch.first}–${batch.last} 页并发失败（$e），'
        '退避后串行重试',
      );
      await Future<void>.delayed(AppConfig.catalogRequestGap);
      final List<CatalogPage> out = <CatalogPage>[];
      for (final int p in batch) {
        out.add(await _fetchPage(httpGet, p));
      }
      return out;
    }
  }

  /// 串行扫到底（总数不可用时的兜底路径）。
  Future<void> _collectSerial(
    HttpGetJson httpGet,
    Map<String, StockConfig> seen,
  ) async {
    for (int page = 1; ; page++) {
      if (page > 1) {
        await Future<void>.delayed(AppConfig.catalogRequestGap);
      }
      final CatalogPage one = await _fetchPage(httpGet, page);
      _merge(<CatalogPage>[one], seen);
      if (one.isEnd) {
        return; // 服务端真的没有更多了
      }
      if (page >= AppConfig.catalogMaxPages) {
        return; // 防御：万一接口开始返回重复数据，别无限翻下去
      }
    }
  }

  void _merge(List<CatalogPage> pages, Map<String, StockConfig> seen) {
    for (final CatalogPage one in pages) {
      for (final StockConfig item in one.items) {
        // 分页是按 symbol 排序的，期间若有新股上市/退市，页边界会移动，
        // 同一条可能出现在两页里。这里按身份键去重，避免搜索出两个一样的结果。
        seen.putIfAbsent(item.key, () => item);
      }
    }
  }

  /// 取一页，**失败会重试**。
  ///
  /// 实测（2026-11）：连续翻 70 页时，第 7 页偶发 HTTP 502。这不是翻到头，
  /// 也不是参数错——新浪的网关在密集请求下会抖。目录 30 天才拉一次，
  /// 为一次抖动就让「换股票」整个不可用显然不划算，所以重试两次。
  ///
  /// 但 **4xx 和 429 不重试**：那是参数错或限流，重试只会更糟。
  Future<CatalogPage> _fetchPage(HttpGetJson httpGet, int page) async {
    SymbolFetchException? last;
    for (int attempt = 0; attempt < AppConfig.catalogRetries; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(AppConfig.catalogRequestGap * attempt);
      }
      final HttpJsonResponse res = await httpGet(
        pageUri(page),
        _catalogHeaders,
      );
      if (res.isRateLimited) {
        throw const SymbolFetchException(
          '目录下载被限流（全市场约 70 页），稍后重试',
          rateLimited: true,
        );
      }
      if (!res.isOk) {
        if (res.statusCode < 500) {
          throw SymbolFetchException('第 $page 页：HTTP ${res.statusCode}');
        }
        last = SymbolFetchException('第 $page 页：HTTP ${res.statusCode}');
        AppLog.w('目录第 $page 页失败（HTTP ${res.statusCode}），重试');
        continue;
      }
      final CatalogPage parsed = parseCatalogPage(res.body);
      if (parsed.valid) {
        return parsed;
      }
      // HTTP 200 但内容不是数组：网关偶尔返回 HTML / null。
      // 这**不能**当成"没有更多了"，否则目录会在这里被截断。
      last = SymbolFetchException('第 $page 页：响应不是有效目录（${res.body.length} 字节）');
      AppLog.w('目录第 $page 页内容非法，重试');
    }
    throw last ?? SymbolFetchException('第 $page 页：多次重试仍失败');
  }

  /// 解析一页目录（**UTF-8 JSON**，与行情那路 GBK 不同）。
  ///
  /// ```json
  /// [{"symbol":"sh600519","code":"600519","name":"贵州茅台","trade":"1450.000",...}]
  /// ```
  ///
  /// `symbol` 带市场前缀，是我们唯一可靠的市场来源；`code` 是纯 6 位数字。
  /// 只保留 `sh` / `sz`，丢掉北交所（`bj`）和别的品种。
  ///
  /// 注意返回的是 [CatalogPage]：过滤掉北交所后**整页可能为空**（前 3 页就是），
  /// 那不代表翻到头，所以要把原始条数一起带出去。
  CatalogPage parseCatalogPage(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return const CatalogPage.invalid();
    }
    if (decoded is! List<Object?>) {
      return const CatalogPage.invalid();
    }
    final List<StockConfig> out = <StockConfig>[];
    for (final Object? row in decoded) {
      if (row is! Map<String, Object?>) {
        continue;
      }
      final String symbol = '${row['symbol'] ?? ''}'.toLowerCase();
      final String code = '${row['code'] ?? ''}'.trim();
      final String name = '${row['name'] ?? ''}'.trim();
      if (code.length != 6 || int.tryParse(code) == null || name.isEmpty) {
        continue;
      }
      final String region;
      if (symbol.startsWith('sh')) {
        region = 'SH';
      } else if (symbol.startsWith('sz')) {
        region = 'SZ';
      } else {
        continue; // bj920000 之类：不支持
      }
      if (symbol.substring(2) != code) {
        continue; // 前缀与代码对不上，说明这不是我们要的条目
      }
      out.add(StockConfig(code: code, name: name, region: region));
    }
    return CatalogPage(items: out, raw: decoded.length);
  }
}
