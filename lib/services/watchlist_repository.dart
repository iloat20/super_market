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
  WatchlistRepository(this._store);

  /// 存档键。带版本号，将来结构变了可以换 key 而不是去猜旧格式。
  static const String storageKey = 'watchlist.v1';

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
    } on Object catch (e) {
      // 读盘失败（权限/磁盘/平台通道异常）不该让首页起不来：
      // 退回默认三只，用户下一次修改会重新写盘。
      AppLog.e('订阅存档读取失败，使用默认列表: $e');
    }
    return AppConfig.stocks;
  }

  Future<void> save(List<StockConfig> stocks) async {
    try {
      await _save(stocks);
    } on Object catch (e) {
      // 存盘失败只影响「下次启动还原」，不该打断当前这次改动
      AppLog.e('订阅存档写入失败: $e');
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

  static String encode(List<StockConfig> stocks) => jsonEncode(
    stocks
        .map(
          (StockConfig s) => <String, String>{
            'c': s.code,
            'n': s.name,
            'r': s.region,
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
      // 市场白名单来自**轮询内核链**（真正供报价的那条链）：
      // 换源之后，旧存档里它不覆盖的市场就该被丢掉，而不是留给订阅去撞墙。
      // 注意不能用 `MarketDataSources.current`——那是推送源（已退役），
      // 它的 markets 停在沪深两市，会让港股存档被误丢。
      //
      // 代码形状必须与市场一致：港股 5 位、沪深 6 位。不做这道校验的话，
      // `12345@SH` 这种残缺条目会被当成 A 股放进去，行情接口返回空、
      // 界面上是一张永远 `--` 的卡。
      final bool shapeOk = region == 'HK' ? code.length == 5 : code.length == 6;
      if (!isValidCode(code) ||
          !shapeOk ||
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

  /// A 股代码：6 位纯数字（必须保留前导零，不能转 int）；
  /// 港股代码：5 位纯数字（同样保留前导零，`00700` 不是 `700`）。
  static bool isValidCode(String code) =>
      (code.length == 6 || code.length == 5) && int.tryParse(code) != null;

  /// 按代码前缀推断市场。
  ///
  /// 只在「股票目录不可用、用户直接输代码」时兜底用；目录可用时以目录为准
  /// （目录里 000001 在沪市是上证指数、在深市是平安银行，前缀规则分辨不了这种同号）。
  ///
  /// 4/8 开头是北交所，iTick 的 region 取值未经验证，这里返回 null 表示不支持
  /// —— 猜一个 `BJ` 上去只会换来一句看不懂的服务端错误。
  static String? regionForCode(String code) {
    if (code.length == 5 && int.tryParse(code) != null) {
      return 'HK'; // 港股：5 位数字是它最可靠的特征
    }
    if (!isValidCode(code)) {
      return null;
    }
    switch (code[0]) {
      case '0':
      case '1':
      case '2':
      case '3':
        return 'SZ';
      case '5':
      case '6':
      case '9':
        return 'SH';
      default:
        return null;
    }
  }
}
