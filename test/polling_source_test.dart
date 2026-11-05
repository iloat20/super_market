import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/services/source/sina_source.dart';
import 'package:super_market/services/source/symbol_catalog.dart';
import 'package:super_market/services/source/tencent_source.dart';

/// 两条真实报文（2026-11-03 10:04:54 实抓，不是编的）。
///
/// 保留原样的一个副作用：报文里含中文（GBK），所以喂给解析器时要先编码成字节。
/// 这正是想测的——**解析路径上不该假设字符集**。
const String _sinaShenzhen =
    'var hq_str_sz000001="平安银行,11.560,11.540,11.490,11.700,11.420,'
    '11.470,11.480,65173875,752536297.040,43400,11.470,140000,11.460,'
    '326300,11.450,528000,11.440,715100,11.430,200,11.480,142000,11.490,'
    '170200,11.500,27900,11.510,92900,11.520,2026-11-03,10:04:54,00";';

/// 沪市比深市**多一个字段**（末尾多一个逗号），实测 34 vs 33。
/// 这个差异是「时间戳必需按下标取，不能取倒数」的唯一理由。
const String _sinaShanghai =
    'var hq_str_sh600519="贵州茅台,1450.000,1439.100,1440.000,1450.000,'
    '1435.100,1439.970,1440.000,1399792,2018016935.000,100,1439.970,4900,'
    '1439.020,400,1439.000,100,1438.680,100,1438.670,200,1440.000,300,'
    '1440.550,100,1440.600,100,1440.700,100,1440.730,2026-11-03,10:04:50,00,";';

const String _tencentShenzhen =
    'v_sz000001="51~平安银行~000001~11.48~11.54~11.56~651667~307620~344014~'
    '11.47~342~11.46~1400~11.45~3293~11.44~5278~11.43~7171~11.48~23~'
    '11.49~1467~11.50~1713~11.51~269~11.52~929~~20261103100451~-0.06~-0.52~'
    '11.70~11.42~11.48/651667/752453594~651667~75245~0.34~5.12~~";';

const List<StockConfig> _stocks = <StockConfig>[
  StockConfig(code: '000001', name: '平安银行', region: 'SZ'),
  StockConfig(code: '600519', name: '贵州茅台', region: 'SH'),
];

/// 报文里的中文是 GBK。用 utf8 编码喂进去，汉字的字节会变成乱码字符，
/// 但**逗号与数字不受影响**——这正是 `latin1.decode` 方案成立的前提，
/// 也是这里刻意不复刻 GBK 表的原因（`Quote` 里没有名称字段）。
List<int> _bytes(String text) => utf8.encode(text);

/// 跑一次目录抓取：总数据接口给出页数，按页返回约定报文，最后比对结果。
Future<void> _assertCatalog({
  required String total,
  required Map<int, String> pages,
  required List<String> expectKeys,
  String? reason,
}) async {
  final List<StockConfig> all = await const SinaSource().fetchSymbols(
    httpGet: (Uri uri, Map<String, String> headers) async {
      if (uri.path.contains('getHQNodeStockCount')) {
        return HttpJsonResponse(statusCode: 200, body: '"$total"');
      }
      final int page = int.parse(uri.queryParameters['page'] ?? '0');
      return HttpJsonResponse(statusCode: 200, body: pages[page] ?? '[]');
    },
  );
  expect(
    all.map((StockConfig s) => s.key).toList(),
    expectKeys,
    reason: reason,
  );
}

void main() {
  group('新浪：字段映射', () {
    test('深市 33 字段：价格、量、额、时间都对', () {
      const SinaSource source = SinaSource();
      final List<Quote> quotes =
          source.parseBatchQuotes(_bytes(_sinaShenzhen), stocks: _stocks);

      expect(quotes, hasLength(1));
      final Quote q = quotes.single;
      expect(q.code, '000001');
      expect(q.region, 'SZ');
      expect(q.price, 11.490);
      expect(q.previousClose, 11.540);
      expect(q.open, 11.560);
      expect(q.high, 11.700);
      expect(q.low, 11.420);
      // 单位是**股**，不是手：新浪 65,173,875 股
      expect(q.volume, 65173875);
      // 单位是**元**
      expect(q.turnover, closeTo(752536297.040, 0.01));
      expect(q.timestamp, DateTime(2026, 11, 3, 10, 4, 54));
      // 涨跌按昨收算，不用服务端给的字段（新浪这版报文没有专门的涨跌列）
      expect(q.change, closeTo(-0.05, 1e-9));
      expect(q.changePercent, closeTo(-0.05 / 11.54 * 100, 1e-9));
    });

    test('沪市 34 字段（末尾多一个逗号）：时间戳仍按下标取到', () {
      const SinaSource source = SinaSource();
      final List<Quote> quotes =
          source.parseBatchQuotes(_bytes(_sinaShanghai), stocks: _stocks);

      expect(quotes, hasLength(1));
      final Quote q = quotes.single;
      expect(q.code, '600519');
      expect(q.region, 'SH');
      expect(q.price, 1440.0);
      expect(q.previousClose, 1439.1);
      expect(q.high, 1450.0);
      expect(q.low, 1435.1);
      expect(q.volume, 1399792);
      expect(q.timestamp, DateTime(2026, 11, 3, 10, 4, 50));
    });

    test('一次响应里多只：按 symbol 各自落位，不串行', () {
      const SinaSource source = SinaSource();
      final List<Quote> quotes = source.parseBatchQuotes(
        _bytes('$_sinaShenzhen\n$_sinaShanghai\n'),
        stocks: _stocks,
      );

      expect(quotes, hasLength(2));
      expect(
        quotes.map((Quote q) => '${q.code}@${q.region}').toSet(),
        <String>{'000001@SZ', '600519@SH'},
      );
    });

    test('代码不存在（空串）被跳过，而不是变成 0 价', () {
      const SinaSource source = SinaSource();
      final List<Quote> quotes = source.parseBatchQuotes(
        _bytes('var hq_str_sz999999="";\n$_sinaShenzhen\n'),
        stocks: _stocks,
      );
      expect(quotes, hasLength(1));
      expect(quotes.single.code, '000001');
    });

    test('退市 / 无成交的 0 价被丢弃（否则会覆盖卡上已有的价）', () {
      const SinaSource source = SinaSource();
      final String dead = _sinaShenzhen.replaceAll('11.490', '0.000');
      final List<Quote> quotes =
          source.parseBatchQuotes(_bytes(dead), stocks: _stocks);
      expect(quotes, isEmpty);
    });

    test('字段数不足（指数只有 28 个字段）被跳过，不抛异常', () {
      const SinaSource source = SinaSource();
      // 上证指数的真实形状：没有五档，字段数远少于 32
      const String index =
          'var hq_str_sh000001="上证指数,3602.7600,3638.0300,3602.7600,'
          '3624.5800,3582.1000,0,0,178600018,24924046,0,0,0,0,0,0,0,0,0,0,'
          '0,0,0,0,0,0,0,0,2026-11-03,10:04:54,00";';
      final List<Quote> quotes =
          source.parseBatchQuotes(_bytes(index), stocks: _stocks);
      expect(quotes, isEmpty);
    });

    test('真正的 GBK 字节也能解出正确数字（名称乱码无所谓）', () {
      const SinaSource source = SinaSource();
      // 「平安银行」的 GBK 编码：C6 BD B0 B2 D2 F8 D0 D0
      final List<int> head = <int>[0x76, 0x61, 0x72, 0x20]; // "var "
      final List<int> gbkName = <int>[0xC6, 0xBD, 0xB0, 0xB2, 0xD2, 0xF8, 0xD0, 0xD0];
      final List<int> rest = utf8.encode(
        // 名称之后是 1..9，再 10..29 是五档（这里填 20 个 0），30/31 才是日期时间
        ',11.560,11.540,11.490,11.700,11.420,11.470,11.480,65173875,'
        '752536297.040,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,'
        '2026-11-03,10:04:54,00',
      );
      final List<int> bytes = <int>[
        ...head,
        ...utf8.encode('hq_str_sz000001="'),
        ...gbkName,
        ...rest,
        ...utf8.encode('";'),
      ];

      final List<Quote> quotes = source.parseBatchQuotes(bytes, stocks: _stocks);
      expect(quotes, hasLength(1));
      expect(quotes.single.price, 11.490);
      expect(quotes.single.volume, 65173875);
    });
  });

  group('新浪：协议地址', () {
    test('批量地址带全部标的，小写市场前缀', () {
      const SinaSource source = SinaSource();
      final Uri uri = source.batchQuoteUri(_stocks);
      expect(uri.host, 'hq.sinajs.cn');
      expect(uri.path, '/list=sz000001,sh600519');
    });

    test('Referer 必须带（少了就是 403）', () {
      const SinaSource source = SinaSource();
      expect(source.requestHeaders(), containsPair('Referer', 'https://finance.sina.com.cn'));
    });

    test('目录翻页：按 symbol 前缀判市场，bj（北交所）丢掉', () {
      const SinaSource source = SinaSource();
      const String body = '['
          '{"symbol":"bj920000","code":"920000","name":"安徽凤凰"},'
          '{"symbol":"sh600519","code":"600519","name":"贵州茅台"},'
          '{"symbol":"sz000001","code":"000001","name":"平安银行"},'
          '{"symbol":"sh600519","code":"600519"}'
          ']';
      final CatalogPage page = source.parseCatalogPage(body);
      expect(
        page.items.map((StockConfig s) => s.key),
        <String>['600519@SH', '000001@SZ'],
      );
      expect(page.raw, 4, reason: 'raw 是过滤前的条数（含 bj 和残缺条目）');
      expect(page.isEnd, isFalse);
    });

    test('整页都是北交所时不算翻到头（真网踩过的坑）', () {
      // 实测：node=hs_a 里 bj 排在 sh/sz 前面，前 3 页清一色 bj。
      // 早期实现按「过滤后为空」判定结束，结果目录在第一步就断了、
      // 最终 0 条——「换股票」直接不可用。这个用例把判据钉在 raw 上。
      const SinaSource source = SinaSource();
      const String firstPage = '['
          '{"symbol":"bj920000","code":"920000","name":"安徽凤凰"},'
          '{"symbol":"bj920001","code":"920001","name":"纬达光电"}'
          ']';
      final CatalogPage page = source.parseCatalogPage(firstPage);
      expect(page.items, isEmpty, reason: '北交所不在支持范围内');
      expect(page.raw, 2);
      expect(page.isEnd, isFalse, reason: '这一页有数据，只是都被过滤了');

      // 真正翻到头：服务端给空数组
      expect(source.parseCatalogPage('[]').isEnd, isTrue);
    });

    test('响应不是数组（网关吐 HTML / null）判为 invalid，且不算翻到头', () {
      const SinaSource source = SinaSource();
      for (final String bad in <String>['null', '<html>502</html>', '']) {
        final CatalogPage page = source.parseCatalogPage(bad);
        expect(page.valid, isFalse, reason: '「$bad」不是合法目录页');
        expect(
          page.isEnd,
          isFalse,
          reason: '读不到 ≠ 没有了；当成结束会让目录少掉一大半',
        );
      }
    });

    test('翻页：中间某页全是北交所也继续翻（整页被过滤 ≠ 翻到头）', () async {
      // 走的是并发路径：先拿总数 4 条 → 1 页就够。
      // 这里故意报 4 页，模拟"总数含北交所"这种真实情况。
      await _assertCatalog(
        total: '350',
        pages: <int, String>{
          1: '[{"symbol":"sh600519","code":"600519","name":"贵州茅台"}]',
          2: '[{"symbol":"bj920000","code":"920000","name":"安徽凤凰"}]',
          3: '[{"symbol":"sz000001","code":"000001","name":"平安银行"}]',
          4: '[]',
        },
        expectKeys: <String>['000001@SZ', '600519@SH'],
        reason: '第 2 页被过滤空不该让目录提前结束',
      );
    });

    test('并发：先问总数，按页并发拉完，6 路封顶', () async {
      int inFlight = 0;
      int peak = 0;
      final List<int> pagesAsked = <int>[];

      final List<StockConfig> all = await const SinaSource().fetchSymbols(
        httpGet: (Uri uri, Map<String, String> headers) async {
          if (uri.path.contains('getHQNodeStockCount')) {
            return const HttpJsonResponse(statusCode: 200, body: '"250"');
          }
          inFlight++;
          if (inFlight > peak) {
            peak = inFlight;
          }
          pagesAsked.add(int.parse(uri.queryParameters['page']!));
          await Future<void>.delayed(Duration.zero);
          inFlight--;
          return const HttpJsonResponse(
            statusCode: 200,
            body: '[{"symbol":"sh600519","code":"600519","name":"贵州茅台"}]',
          );
        },
      );

      // 250 条 / 每页 100 → 3 页
      expect(pagesAsked, <int>[1, 2, 3]);
      expect(peak, 3, reason: '只有 3 页时不该超过页数');
      expect(all.length, 1, reason: '三页返回同一条，去重后只剩一只');
    });

    test('并发：页数超过 6 时分批，同时最多 6 个请求在飞', () async {
      int inFlight = 0;
      int peak = 0;

      await const SinaSource().fetchSymbols(
        httpGet: (Uri uri, Map<String, String> headers) async {
          if (uri.path.contains('getHQNodeStockCount')) {
            return const HttpJsonResponse(statusCode: 200, body: '"1500"');
          }
          inFlight++;
          if (inFlight > peak) {
            peak = inFlight;
          }
          final int page = int.parse(uri.queryParameters['page']!);
          await Future<void>.delayed(Duration.zero);
          inFlight--;
          // 每页给一条互不相同的票，避免被去重合并
          return HttpJsonResponse(
            statusCode: 200,
            body: '[{"symbol":"sh60000$page","code":"60000$page",'
                '"name":"票$page"}]',
          );
        },
      );

      expect(peak, AppConfig.catalogConcurrency, reason: '并发度必须被限制住');
    });

    test('翻页：单页内容非法会重试，而不是丢掉这一页', () async {
      int firstPageTries = 0;
      int countCalls = 0;

      final List<StockConfig> all = await const SinaSource().fetchSymbols(
        httpGet: (Uri uri, Map<String, String> headers) async {
          if (uri.path.contains('getHQNodeStockCount')) {
            countCalls++;
            return const HttpJsonResponse(statusCode: 200, body: '"1"');
          }
          final int page = int.parse(uri.queryParameters['page'] ?? '0');
          if (page == 1) {
            firstPageTries++;
            if (firstPageTries == 1) {
              return const HttpJsonResponse(statusCode: 200, body: '<html>');
            }
            return const HttpJsonResponse(
              statusCode: 200,
              body: '[{"symbol":"sh600519","code":"600519","name":"贵州茅台"}]',
            );
          }
          return const HttpJsonResponse(statusCode: 200, body: '[]');
        },
      );

      expect(countCalls, 1, reason: '判据先问总数，不要靠翻到空页');
      expect(firstPageTries, 2, reason: '第一页读坏了必须重试一次');
      expect(all, hasLength(1));
    });

    test('总数接口挂了：退化串行扫到底，不漏票', () async {
      final List<Uri> calls = <Uri>[];
      final Map<int, String> pages = <int, String>{
        1: '[{"symbol":"sh600519","code":"600519","name":"贵州茅台"}]',
        2: '[{"symbol":"sz000001","code":"000001","name":"平安银行"}]',
        3: '[]',
      };

      final List<StockConfig> all = await const SinaSource().fetchSymbols(
        httpGet: (Uri uri, Map<String, String> headers) async {
          calls.add(uri);
          if (uri.path.contains('getHQNodeStockCount')) {
            return const HttpJsonResponse(statusCode: 500, body: 'oops');
          }
          final int page = int.parse(uri.queryParameters['page'] ?? '0');
          return HttpJsonResponse(statusCode: 200, body: pages[page] ?? '[]');
        },
      );

      expect(
        all.map((StockConfig s) => s.key),
        <String>['000001@SZ', '600519@SH'],
      );
      // 1 次总数 + 3 页（最后一页空 → 收工）
      expect(calls.length, 4);
    });

    test('目录页地址：node=hs_a，100 条一页（接口硬顶）', () {
      final Uri uri = SinaSource.pageUri(7);
      expect(uri.queryParameters['page'], '7');
      expect(uri.queryParameters['num'], '100');
      expect(uri.queryParameters['node'], 'hs_a');
    });

    test('总数地址：getHQNodeStockCount', () {
      final Uri uri = SinaSource.countUri();
      expect(uri.path, contains('Market_Center.getHQNodeStockCount'));
      expect(uri.queryParameters['node'], 'hs_a');
      expect(uri.queryParameters['page'], isNull, reason: '总数接口不分页');
    });
  });

  group('腾讯：单位换算（错了不会报错，只会少两个数量级）', () {
    test('成交量按「手 ×100」换成股', () {
      const TencentSource source = TencentSource();
      final List<Quote> quotes =
          source.parseBatchQuotes(_bytes(_tencentShenzhen), stocks: _stocks);

      expect(quotes, hasLength(1));
      final Quote q = quotes.single;
      expect(q.price, 11.48);
      expect(q.previousClose, 11.54);
      expect(q.open, 11.56);
      // 65.1667 万手 → 6516.67 万股
      expect(q.volume, 651667 * 100);
      // 75245 万元 → 7.5245 亿元
      expect(q.turnover, 75245 * 10000);
      expect(q.high, 11.70);
      expect(q.low, 11.42);
      expect(q.timestamp, DateTime(2026, 11, 3, 10, 4, 51));
    });

    test('`~~` 空字段不会让后续下标错位', () {
      const TencentSource source = TencentSource();
      final List<Quote> quotes =
          source.parseBatchQuotes(_bytes(_tencentShenzhen), stocks: _stocks);
      // 29 号是空串；如果实现「跳过空字段」，最高价会读到 11.42（错一位）
      expect(quotes.single.high, 11.70);
      expect(quotes.single.low, 11.42);
    });

    test('字段不足 38 个整行丢弃（报文结构变了就别硬解）', () {
      const TencentSource source = TencentSource();
      final List<Quote> quotes = source.parseBatchQuotes(
        _bytes('v_sz000001="51~平安银行~000001~11.48~11.54~11.56";'),
        stocks: _stocks,
      );
      expect(quotes, isEmpty);
    });

    test('目录字段 code 自带前缀，按前缀判市场', () {
      const TencentSource source = TencentSource();
      const String body = '{"code":0,"data":{"rank_list":['
          '{"code":"sh600519","name":"贵州茅台"},'
          '{"code":"sz000001","name":"平安银行"},'
          '{"code":"bj920000","name":"安徽凤凰"}'
          ']}}';
      final CatalogPage page = source.parseCatalogPage(body);
      expect(
        page.items.map((StockConfig s) => s.key),
        <String>['600519@SH', '000001@SZ'],
      );
      expect(page.raw, 3);
    });
  });
}
