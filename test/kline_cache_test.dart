import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:super_market/config/app_config.dart';
import 'package:super_market/services/kline_loader.dart';
import 'package:super_market/services/rest_client.dart';

/// 走势缓存必须有上限。
///
/// key 里带 `count`（80/160/240/320/400/480 六档），满配额 30 只 × 7 种 =
/// 210 个 key，每份 240~480 根 K 线。无上限的话，一个"来回翻历史、逐只切"
/// 的用户能把缓存堆到几 MB —— 而 README 里承认"长时内存增长"恰恰没测过。
///
/// 断言方式刻意不读内部字段：**用请求次数说话**。被淘汰的 key 再取一次必然
/// 重新发请求，命中缓存的则一次都不发。这比 `cache.length` 更难作假。

const String _dailyBody = '''
{"result":{"status":{"code":0},"data":[
 {"day":"2026-10-30","open":"1363.000","high":"1393.370","low":"1352.980","close":"1392.050","volume":"5992729"},
 {"day":"2026-11-02","open":"1410.000","high":"1447.000","low":"1395.020","close":"1439.100","volume":"8269122"}]}}''';

StockConfig _stock(int i) => StockConfig(
  code: '${600000 + i}',
  name: '测试$i',
  region: 'SH',
);

void main() {
  test('缓存有上限：超过上限后，最久未用的那个必须被挤掉', () async {
    final List<String> asked = <String>[];
    final KlineLoader loader = KlineLoader(
      httpGet: (Uri uri, Map<String, String> headers) async {
        asked.add(uri.toString());
        return HttpRawResponse(statusCode: 200, body: utf8.encode(_dailyBody));
      },
    );

    for (int i = 0; i < 13; i++) {
      final result = await loader.loadDaily(_stock(i), count: 80);
      expect(result.items, isNotEmpty, reason: '假源必须解析得出数据，否则测的是失败路径');
    }
    expect(asked.length, 13, reason: '13 个不同标的 = 13 次请求');

    // 最近用过的那个必须还命中缓存
    await loader.loadDaily(_stock(12), count: 80);
    expect(asked.length, 13, reason: '第 13 个刚用过，不该重新请求');

    // 最久没用的那个已被淘汰 → 必须重新请求
    await loader.loadDaily(_stock(0), count: 80);
    expect(
      asked.length,
      14,
      reason: '缓存无上限时这里仍是 13——正是本用例要挡住的行为',
    );
  });

  test('同一标的换 count 是不同 key，互不覆盖', () async {
    final List<String> asked = <String>[];
    final KlineLoader loader = KlineLoader(
      httpGet: (Uri uri, Map<String, String> headers) async {
        asked.add(uri.toString());
        return HttpRawResponse(statusCode: 200, body: utf8.encode(_dailyBody));
      },
    );

    await loader.loadDaily(_stock(0), count: 80);
    await loader.loadDaily(_stock(0), count: 160);
    await loader.loadDaily(_stock(0), count: 80); // 命中第一条
    expect(asked.length, 2);
  });
}
