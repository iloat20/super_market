import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/services/source/sina_source.dart';
import 'package:super_market/services/source/eastmoney_suggest.dart';

/// 真网探针：确认「这两个接口现在还长这样」。
///
/// 单测证明「解析逻辑对」，探针证明「服务端没变」。两者的失效方式不同：
/// 前者改代码会红，后者只有真网能发现（上一轮那三个静默 bug 全是探针抓的）。
///
/// ```bash
/// flutter test tool/search_live_probe_test.dart
///
/// # 全量目录（约 5s、56 个请求，默认不跑）
/// PROBE_CATALOG=1 flutter test tool/search_live_probe_test.dart
/// ```
void main() {
  const EastmoneySuggest suggest = EastmoneySuggest();

  Future<List<int>?> fetch(String query) async {
    final HttpRawResponse res = await defaultHttpGetBytes(
      suggest.suggestUri(query),
      suggest.requestHeaders,
    );
    if (!res.isOk) {
      return null;
    }
    return res.body;
  }

  test('搜索：名称 / 代码 / 拼音 三条路都能命中', () async {
    for (final String q in <String>['茅台', '600519', 'gzmt']) {
      final List<int>? bytes = await fetch(q);
      expect(bytes, isNotNull, reason: '「$q」请求失败');
      final List<StockConfig> items = suggest.parse(bytes!);
      expect(items, isNotEmpty, reason: '「$q」没搜到');
      final StockConfig first = items.first;
      // ignore: avoid_print
      print('  搜「$q」→ ${items.length} 条，首条 '
          '${first.name}(${first.region}${first.code})');
      expect(first.code, '600519');
      expect(first.name, '贵州茅台');
    }
  });

  test('搜索：宽泛词的结果里没有 ETF / 指数 / 美股', () async {
    final List<int>? bytes = await fetch('银行');
    expect(bytes, isNotNull);
    final List<StockConfig> items = suggest.parse(bytes!);
    expect(items, isNotEmpty);
    // ignore: avoid_print
    print('  搜「银行」→ ${items.length} 条：'
        '${items.take(5).map((StockConfig s) => s.name).join('、')}');
    for (final StockConfig s in items) {
      expect(<String>['SH', 'SZ'], contains(s.region));
      expect(s.code.length, 6);
      final bool shOk = s.region == 'SH' && s.code.startsWith('6');
      final bool szOk = s.region == 'SZ' &&
          (s.code.startsWith('0') || s.code.startsWith('3'));
      expect(shOk || szOk, isTrue, reason: '${s.name} 的号段不属于 A 股');
    }
  });

  test('搜索：无结果长什么样（Data 为 null）', () async {
    final List<int>? bytes = await fetch('zzzzzz');
    expect(bytes, isNotNull);
    // ignore: avoid_print
    print('  搜「zzzzzz」→ ${String.fromCharCodes(bytes!).substring(0, 80)}');
    expect(suggest.parse(bytes), isEmpty);
  });

  test('搜索：北交所不收录（我们的行情也不支持）', () async {
    final List<int>? bytes = await fetch('920047');
    expect(bytes, isNotNull);
    expect(suggest.parse(bytes!), isEmpty);
  });

  test('目录：总数接口 + 6 路并发（PROBE_CATALOG=1 才跑）', () async {
    if (Platform.environment['PROBE_CATALOG'] != '1') {
      // ignore: avoid_print
      print('  跳过（设 PROBE_CATALOG=1 开启）');
      return;
    }

    final Stopwatch sw = Stopwatch()..start();
    final List<StockConfig> all = await const SinaSource().fetchSymbols(
      httpGet: defaultHttpGet,
    );
    sw.stop();

    final int sh = all.where((StockConfig s) => s.region == 'SH').length;
    final int sz = all.where((StockConfig s) => s.region == 'SZ').length;
    // ignore: avoid_print
    print('  目录 ${all.length} 条（SH $sh / SZ $sz），'
        '耗时 ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');

    expect(all.length, greaterThan(5000), reason: '目录被截断过（曾经少过 1800 只）');
    // 实测 6.5–9.5s（连续探测时服务端会临时降速，偶发到 20s+）。
    // 串行兜底是 56 页 × (请求 + 400ms 间隔) ≈ 70s，所以 30s 这条线
    // 既不会被抖动误伤，又能抓住「并发没生效」。
    expect(
      sw.elapsedMilliseconds,
      lessThan(30000),
      reason: '超过 30s 说明退化成串行了（并发没生效）',
    );
    expect(
      all.firstWhere((StockConfig s) => s.code == '600519').region,
      'SH',
    );
    expect(AppConfig.catalogConcurrency, 6);
  });
}
