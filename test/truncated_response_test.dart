import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/kline.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/services/kline_loader.dart';
import 'package:super_market/services/local_store.dart';
import 'package:super_market/services/polling_quote_feed.dart';
import 'package:super_market/services/quote_feed.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/services/source/kline_source.dart';
import 'package:super_market/services/source/polling_source.dart';
import 'package:super_market/services/source/sina_kline.dart';
import 'package:super_market/services/source/sina_source.dart';
import 'package:super_market/services/symbol_directory.dart';

/// A12：`HttpRawResponse.truncated` 原本无人消费。
///
/// 传输层把 >512KB 的响应削到 512KB 并打上 [HttpRawResponse.truncated]，
/// 但三个消费点只看 `isOk`（= HTTP 2xx），于是 HTTP 200 的残缺报文被当成
/// 成功。最危险的是轮询：新浪报文逐行独立，前半段照样能解析出报价，
/// 于是部分股票价格静止、失败计数清零、界面还显示「已连接」。
///
/// 这里刻意给截断响应塞**合法可解析**的 body —— 把「解析会不会抛」这个
/// 变量排除掉，单独钉住「消费方是否尊重 truncated 标记」。

const StockConfig _kStock = StockConfig(
  code: '000001',
  name: '平安银行',
  region: 'SZ',
);

String _sinaLine(String code, String region) {
  final List<String> f = <String>[
    'NAME', '11.560', '11.540', '11.49', '11.700', '11.420', '11.470',
    '11.480', '65173875', '752536297.040',
    ...List<String>.filled(20, '0'),
    '2026-11-03', '10:04:54', '00',
  ];
  return 'var hq_str_${region.toLowerCase()}$code="${f.join(',')}";';
}

/// 新浪报价（GBK 名称，数值字段全 ASCII）：完整一行 + 一行被削断的尾巴。
HttpRawResponse _truncatedQuotes() => HttpRawResponse.truncated(
      statusCode: 200,
      body: '${_sinaLine('000001', 'SZ')}\n'
              'var hq_str_sh600519="11.49,11.50,11.48'
          .codeUnits,
    );

const String _kSuggest =
    '{"QuotationCodeTable":{"Data":[{"Code":"600519","Name":"贵州茅台",'
    '"MarketType":"1"}],"Status":0}}';

/// `connect()` 里是零延迟 Timer，不带时长的 pump 不会推进它。
Future<void> _start(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 1));
  await tester.pump();
}

Future<void> _advance(WidgetTester tester) async {
  await tester.pump(AppConfig.pollInterval);
  await tester.pump();
  await tester.pump();
}

void main() {
  test('传输层：截断响应不可交付解析层', () {
    const HttpRawResponse res = HttpRawResponse.truncated(
      statusCode: 200,
      body: <int>[1, 2, 3],
    );
    expect(res.statusCode, 200);
    expect(res.truncated, isTrue);
    expect(res.isOk, isFalse,
        reason: 'HTTP 200 但 body 残缺，不能算成功');
    expect(res.failureLabel, contains('截断'));
  });

  testWidgets('轮询：截断响应不得下发部分报价，也不得显示已连接',
      (WidgetTester tester) async {
    final List<Quote> got = <Quote>[];
    final HttpRawResponse res = _truncatedQuotes();
    final PollingQuoteFeed feed = PollingQuoteFeed(
      onQuotes: got.addAll,
      chain: const <PollingSource>[SinaSource()],
      stocks: const <StockConfig>[_kStock],
      httpGet: (Uri uri, Map<String, String> headers) async => res,
    );

    feed.connect();
    await _start(tester);

    expect(got, isEmpty,
        reason: '截断报文前半段能解析出 1 条报价，绝不能当成功下发');
    expect(feed.status.value, isNot(FeedStatus.connected),
        reason: '残缺数据不该让状态变成已连接');

    // 单内核连续 3 次失败才进退避并写 lastError；文案必须能解释原因。
    await _advance(tester);
    await _advance(tester);
    expect(feed.lastError.value, contains('截断'),
        reason: '进退避后用户看到的错误要指向截断，而不是误导性的 HTTP 200');

    feed.dispose();
  });

  test('搜索：截断响应按失败返回 null，不返回残缺结果', () async {
    final HttpRawResponse res = HttpRawResponse.truncated(
      statusCode: 200,
      body: utf8.encode(_kSuggest),
    );
    final SymbolDirectory dir = SymbolDirectory(
      store: MemoryKeyValueStore(),
      httpGet: (Uri uri, Map<String, String> headers) async =>
          const HttpJsonResponse(statusCode: 200, body: '[]'),
      httpGetBytes: (Uri uri, Map<String, String> headers) async => res,
    );

    final List<StockConfig>? result = await dir.searchRemote('茅台');
    expect(result, isNull,
        reason: '截断响应即使恰好能解析出结果，也必须判失败（null）');
  });

  test('走势：截断响应判失败且原因可读，不把残缺图上屏', () async {
    // 合法日线 JSON + truncated 标记：单独钉住「消费方是否尊重标记」，
    // 排除「解析会不会抛」这个变量。
    const String daily = '''
{"result":{"status":{"code":0},"data":[
 {"day":"2026-11-02","open":"1410.000","high":"1447.000","low":"1395.020","close":"1439.100","volume":"8269122"},
 {"day":"2026-10-30","open":"1363.000","high":"1393.370","low":"1352.980","close":"1392.050","volume":"5992729"}]}}''';
    final HttpRawResponse res = HttpRawResponse.truncated(
      statusCode: 200,
      body: utf8.encode(daily),
    );
    final KlineLoader loader = KlineLoader(
      chain: const <KlineSource>[SinaKline()],
      httpGet: (Uri uri, Map<String, String> headers) async => res,
    );

    final KlineResult<Kline> result = await loader.loadDaily(_kStock);
    expect(result.items, isEmpty,
        reason: '截断响应即使能解析出 K 线，也必须判失败');
    expect(result.error, contains('截断'),
        reason: '错误原因要指向截断，而不是误导性的 HTTP 200');
  });
}
