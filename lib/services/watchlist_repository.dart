import 'dart:convert';

import '../config/app_config.dart';
import '../utils/app_log.dart';
import 'local_store.dart';
import 'source/polling_source.dart';
import 'source/polling_sources.dart';

/// 订阅列表的读写。
///
/// 之前订阅列表是 `AppConfig.stocks`（编译期常量），想换股票只能改代码重新打包。
/// 现在改成「本地存档优先，没有存档才用默认三只」：
/// - 首次安装：显示 `AppConfig.stocks`；
/// - 改过之后：以存档为准，换手机/清数据才回到默认。
class WatchlistRepository {
  WatchlistRepository(this._store, {KeyValueStore? legacyStore})
    : // 命名参数不能用私有名（`this._legacyStore` 不是合法形参），
      // 与 local_store / symbol_directory 同款处理
      // ignore: prefer_initializing_formals
      _legacyStore = legacyStore;

  /// 存档键。带版本号，将来结构变了可以换 key 而不是去猜旧格式。
  static const String storageKey = 'watchlist.v1';

  /// 旧版存档所在的那个 store（文件名带数据源 id）。
  ///
  /// 订阅列表是**用户数据**，格式与数据源无关；把它和数据源 id 绑在一起
  /// 意味着「按文档调换主备两行」＝静默回到默认列表（见 local_store 的
  /// `fileName` 注释）。现在用户数据写到与源无关的文件，这里只负责
  /// 一次性把旧文件读出来搬过去。
  final KeyValueStore? _legacyStore;

  /// 全部轮询内核都覆盖的市场并集。
  ///
  /// 港股接入后是 {SZ, SH, HK}。解码存档时用它当白名单：
  /// 哪天某个内核不再支持某市场，并集自动收窄，旧条目跟着失效。
  static final Set<String> _supportedRegions = <String>{
    for (final PollingSource source in PollingSources.defaultChain)
      ...source.markets,
  };

  final KeyValueStore _store;

  /// 读取订阅列表；没有存档或存档损坏时返回默认值。
  ///
  /// 任何异常都吞掉：存档坏了就退回默认三只，不能让 App 起不来。
  Future<List<StockConfig>> load() async {
    try {
      final String? raw = await _store.read(storageKey);
      if (raw != null) {
        final List<StockConfig> parsed = decode(raw);
        if (parsed.isNotEmpty) {
          return parsed;
        }
      }
      // 新文件里没有（全新安装 / 首次升级到「用户数据与源解耦」这一版）：
      // 去旧文件名里找一次，找到就搬过来。不搬的话，用户在升级后会看到
      // 自选凭空回到默认列表——修「换源丢自选」的动作本身又丢一次自选。
      final String? legacy = await _readLegacyRaw();
      if (legacy != null) {
        final List<StockConfig> parsed = decode(legacy);
        if (parsed.isNotEmpty) {
          await _adoptLegacy(legacy);
          return parsed;
        }
      }
    } on Object catch (e) {
      // 读盘失败（权限/磁盘/平台通道异常）不该让首页起不来：
      // 退回默认三只，用户下一次修改会重新写盘。
      AppLog.e('订阅存档读取失败，使用默认列表: $e');
    }
    return AppConfig.stocks;
  }

  Future<String?> _readLegacyRaw() async {
    final KeyValueStore? legacy = _legacyStore;
    if (legacy == null) {
      return null;
    }
    try {
      return await legacy.read(storageKey);
    } on Object catch (e) {
      AppLog.w('旧订阅存档读取失败（忽略）: $e');
      return null;
    }
  }

  Future<void> _adoptLegacy(String raw) async {
    try {
      await _store.write(storageKey, raw);
      AppLog.i('订阅存档已迁移到与数据源无关的文件');
    } on Object catch (e) {
      // 迁移失败不影响本次使用：数据还在旧文件里，下次启动会再试一次
      AppLog.w('订阅存档迁移失败（本次仍用旧数据）: $e');
    }
  }

  /// 存盘；返回**是否真的写成功**。
  ///
  /// 原来返回 void 并在这里吞掉异常，调用方（页面）`await` 之后即当已提交，
  /// 于是「磁盘满 / 目录不可写」这种失败对用户完全不可见，直到重启才发现
  /// 自选回退。返回值把「写成功」这件事变成一个有类型的答案。
  Future<bool> save(List<StockConfig> stocks) async {
    try {
      await _save(stocks);
      return true;
    } on Object catch (e) {
      // 存盘失败只影响「下次启动还原」，不打断当前这次改动；
      // 但**必须把失败告诉调用方**，由它决定怎么提示用户。
      AppLog.e('订阅存档写入失败: $e');
      return false;
    }
  }

  Future<void> _save(List<StockConfig> stocks) async {
    if (stocks.isEmpty) {
      // 空列表等于「没有订阅」，语义上和没配过一样，直接清掉存档
      await _store.remove(storageKey);
      return;
    }
    await _store.write(storageKey, encode(stocks));
  }

  // ==================== 序列化（纯函数，可单测）====================

  /// `e` = 交易所（只有美股非空）。旧存档没有这个键也能读回（见 [decode]）。
  static String encode(List<StockConfig> stocks) => jsonEncode(
    stocks
        .map(
          (StockConfig s) => <String, String>{
            'c': s.code,
            'n': s.name,
            'r': s.region,
            if (s.exchange.isNotEmpty) 'e': s.exchange,
          },
        )
        .toList(),
  );

  /// 宽容解析：单条坏数据只丢那一条，不让整份存档作废。
  static List<StockConfig> decode(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      AppLog.e('订阅存档不是合法 JSON，使用默认列表');
      return const <StockConfig>[];
    }
    if (decoded is! List<Object?>) {
      return const <StockConfig>[];
    }

    final List<StockConfig> result = <StockConfig>[];
    final Set<String> seen = <String>{};
    for (final Object? item in decoded) {
      if (item is! Map<String, Object?>) {
        continue;
      }
      final String code = '${item['c'] ?? ''}'.trim();
      final String region = '${item['r'] ?? ''}'.trim().toUpperCase();
      final String name = '${item['n'] ?? ''}'.trim();
      final String exchange = '${item['e'] ?? ''}'.trim();
      // 市场白名单来自**轮询内核链**（真正供报价的那条链）：
      // 换源之后，旧存档里它不覆盖的市场就该被丢掉，而不是留给订阅去撞墙。
      // 注意不能用 `MarketDataSources.current`——那是推送源（已退役），
      // 它的 markets 停在沪深两市，会让港股存档被误丢。
      //
      // 代码形状必须与市场一致：港股 5 位、美股 1–5 位大写字母、沪深 6 位。
      // 不做这道校验的话，`12345@SH` 这种残缺条目会被当成 A 股放进去，
      // 行情接口返回空、界面上是一张永远 `--` 的卡。
      final bool shapeOk = switch (region) {
        'HK' => code.length == 5,
        'US' => _usCodePattern.hasMatch(code),
        _ => code.length == 6,
      };
      // 美股还必须带**已验证的交易所**：腾讯写法要按交易所拼后缀
      // （NASDAQ→.OQ、NYSE→.N），没有或没验证过（AMEX）的条目去了也是
      // 永远无数据的卡，宁可丢弃重建。
      final bool exchangeOk = region != 'US' || exchange == 'NASDAQ' ||
          exchange == 'NYSE';
      if (!isValidCode(code) ||
          !shapeOk ||
          !exchangeOk ||
          !_supportedRegions.contains(region)) {
        AppLog.w('订阅存档里有无效条目，已跳过: $item');
        continue;
      }
      // 同一市场同一代码只能出现一次；不同市场可以同代码（000001 沪=上证指数、深=平安银行）
      if (!seen.add(StockConfig.keyOf(code, region))) {
        continue;
      }
      result.add(
        StockConfig(
          code: code,
          name: name.isEmpty ? code : name,
          region: region,
          exchange: exchange,
        ),
      );
      // 上限用公开源的 30 只，而不是免费档的 3 只：
      // UI 在添加时已经按当前源把过关（_openWatchlist 传 quota），decode 的
      // 职责是「过滤坏数据」而不是「二次执行配额」。曾经在这里按 3 截断，
      // 公开源用户订了 10 只 → 重启只还 3 只，再一存盘剩下 7 只永久丢失。
      if (result.length >= AppConfig.publicSourceMaxStocks) {
        break; // 防御性上限（正常不会触达）
      }
    }
    return result;
  }

  /// 美股代码：1–5 位大写字母。
  static final RegExp _usCodePattern = RegExp(r'^[A-Z]{1,5}$');

  /// A 股代码：6 位纯数字（必须保留前导零，不能转 int）；
  /// 港股代码：5 位纯数字（同样保留前导零，`00700` 不是 `700`）；
  /// 美股代码：1–5 位大写字母（`AAPL`，带点/下划线的多类股不支持）。
  static bool isValidCode(String code) {
    if (_usCodePattern.hasMatch(code)) {
      return true;
    }
    return (code.length == 6 || code.length == 5) && int.tryParse(code) != null;
  }

  /// 按代码前缀推断市场。
  ///
  /// 只在「股票目录不可用、用户直接输代码」时兜底用；目录可用时以目录为准
  /// （目录里 000001 在沪市是上证指数、在深市是平安银行，前缀规则分辨不了这种同号）。
  ///
  /// 4/8 开头是北交所，iTick 的 region 取值未经验证，这里返回 null 表示不支持
  /// —— 猜一个 `BJ` 上去只会换来一句看不懂的服务端错误。
  /// 字母代码（美股）同样返回 null：交易所**无法**从代码推断（同一串字母
  /// 可能在 NASDAQ 也可能在 NYSE），美股只能走搜索添加。
  ///
  /// 2 开头（深市 B 股 200xxx）与 9 开头（沪市 B 股 900xxx、北交所 920xxx）
  /// 一律返回 null：这些号段两个轮询源要么根本不供、要么供的是**外币计价**
  /// 的另一类标的，放进来就是一张永远 `--` 的卡（或一只被当成 A 股显示的
  /// B 股）。搜索侧早就把这两段挡掉了（见 `eastmoney_suggest._isAShareCode`），
  /// 手输兜底必须与它同口径——否则「搜不到」和「能手输」自相矛盾。
  static String? regionForCode(String code) {
    if (_usCodePattern.hasMatch(code)) {
      return null;
    }
    if (code.length == 5 && int.tryParse(code) != null) {
      return 'HK'; // 港股：5 位数字是它最可靠的特征
    }
    if (!isValidCode(code)) {
      return null;
    }
    switch (code[0]) {
      case '0':
      case '1':
      case '3':
        return 'SZ';
      case '5':
      case '6':
        return 'SH';
      case '2':
      case '9':
        // 深 B（200xxx）/ 沪 B（900xxx）/ 北交所（920xxx）：不支持
        return null;
      default:
        return null;
    }
  }
}
