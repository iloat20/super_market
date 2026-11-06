import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/services/polling_quote_feed.dart';
import 'package:super_market/services/quote_feed.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/services/source/polling_source.dart';
import 'package:super_market/services/source/sina_source.dart';
import 'package:super_market/services/source/tencent_source.dart';

/// 订阅里**同时有** A 股和美股。这是默认配置的形态
/// （`AppConfig.stocks` 里就有 `PDD@US`），也是「主备覆盖不一致」的触发条件：
/// 新浪声明 `markets = [SZ, SH, HK, US]`，腾讯只有 `[SZ, SH, HK]`。
const List<StockConfig> _mixed = <StockConfig>[
  StockConfig(code: '600519', name: '贵州茅台', region: 'SH'),
  StockConfig(code: 'PDD', name: '拼多多', region: 'US', exchange: 'NASDAQ'),
];

const List<StockConfig> _aShares = <StockConfig>[
  StockConfig(code: '000001', name: '平安银行', region: 'SZ'),
  StockConfig(code: '600519', name: '贵州茅台', region: 'SH'),
];

String _sinaLine(String code, String region, {double price = 11.49}) {
  final List<String> f = <String>[
    'NAME', '11.560', '11.540', '$price', '11.700', '11.420', '11.470',
    '11.480', '65173875', '752536297.040',
    ...List<String>.filled(20, '0'),
    '2026-11-03', '10:04:54', '00',
  ];
  return 'var hq_str_${region.toLowerCase()}$code="${f.join(',')}";';
}

String _tencentLine(String code, String region, {String time = '20261103100451'}) {
  final List<String> f = <String>[
    '51', 'NAME', code, '11.48', '11.54', '11.56', '651667', '0', '0',
    ...List<String>.filled(20, '0'),
    '',
    time, '-0.06', '-0.52', '11.70', '11.42', 'x', '651667', '75245',
  ];
  return 'v_${region.toLowerCase()}$code="${f.join('~')}";';
}

class _FakeNet {
  _FakeNet(this.handler);

  HttpRawResponse Function(Uri uri) handler;
  final List<Uri> calls = <Uri>[];

  Future<HttpRawResponse> get(Uri uri, Map<String, String> headers) async {
    calls.add(uri);
    return handler(uri);
  }
}

HttpRawResponse _ok(String body) =>
    HttpRawResponse(statusCode: 200, body: body.codeUnits);

HttpRawResponse _http500(Uri uri) =>
    const HttpRawResponse(statusCode: 500, body: <int>[]);

/// 直接吐出固定 [Quote] 的源：用来构造「时间戳在未来」这类解析器
/// 已经不该产出的脏数据，验证 feed 层还有第二道闸。
class _ScriptedSource implements PollingSource {
  _ScriptedSource(this.next);

  List<Quote> next;

  @override
  String get id => 'scripted';

  @override
  String get displayName => 'Scripted';

  @override
  List<String> get markets => const <String>['SH'];

  @override
  Uri batchQuoteUri(List<StockConfig> stocks) =>
      Uri.https('scripted.test', '/q');

  @override
  Map<String, String> requestHeaders() => const <String, String>{};

  @override
  List<Quote> parseBatchQuotes(
    List<int> bytes, {
    required List<StockConfig> stocks,
  }) => next;

  @override
  Future<List<StockConfig>> fetchSymbols({required HttpGetJson httpGet}) async =>
      const <StockConfig>[];
}

Future<void> _start(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 1));
  await tester.pump();
}

Future<void> _advance(WidgetTester tester) async {
  await tester.pump(AppConfig.pollInterval);
  await tester.pump();
  await tester.pump();
}

Quote _quote(String code, String region, DateTime stamp, {double price = 12}) =>
    Quote(
      code: code,
      region: region,
      price: price,
      change: 0,
      changePercent: 0,
      timestamp: stamp,
    );

void main() {
  group('覆盖契约：备源不覆盖的市场不得被静默丢下', () {
    testWidgets('只把当前内核**声明支持**的标的拼进 URL', (WidgetTester tester) async {
      final _FakeNet net = _FakeNet((Uri uri) => _ok(_tencentLine('600519', 'sh')));
      final PollingQuoteFeed feed = PollingQuoteFeed(
        onQuotes: (List<Quote> _) {},
        // 故意把腾讯放主力：它是覆盖较窄的那个
        chain: const <PollingSource>[TencentSource(), SinaSource()],
        stocks: _mixed,
        httpGet: net.get,
      );

      feed.connect();
      await _start(tester);

      expect(net.calls, hasLength(1));
      final String url = net.calls.single.toString();
      expect(url, contains('sh600519'), reason: 'A 股该问');
      expect(
        url.toLowerCase(),
        isNot(contains('pdd')),
        reason: '腾讯的报价端点不支持美股，拼进去只会换回一行 v_pv_none_match',
      );

      feed.dispose();
    });

    testWidgets('覆盖不全时必须明说，而不是判成「一切正常」', (WidgetTester tester) async {
      final _FakeNet net = _FakeNet((Uri uri) => _ok(_tencentLine('600519', 'sh')));
      final PollingQuoteFeed feed = PollingQuoteFeed(
        onQuotes: (List<Quote> _) {},
        chain: const <PollingSource>[TencentSource(), SinaSource()],
        stocks: _mixed,
        httpGet: net.get,
      );

      feed.connect();
      await _start(tester);

      expect(feed.status.value, FeedStatus.connected);
      expect(
        feed.lastError.value,
        contains('不提供 1 只标的'),
        reason: 'PDD 拿不到必须说出来，否则用户只会看到一张永远不动的卡',
      );

      feed.dispose();
    });

    testWidgets('没有覆盖全部的备源时，不切源（原地退避）', (WidgetTester tester) async {
      final _FakeNet net = _FakeNet(_http500);
      final PollingQuoteFeed feed = PollingQuoteFeed(
        onQuotes: (List<Quote> _) {},
        chain: const <PollingSource>[SinaSource(), TencentSource()],
        stocks: _mixed,
        httpGet: net.get,
      );

      feed.connect();
      await _start(tester);
      expect(feed.sourceLabel, '新浪财经');

      // 连续失败 3 次 → 本该切腾讯；但腾讯不覆盖 US，切过去 = PDD 静默冻结
      for (int i = 0; i < AppConfig.pollFailoverAfter; i++) {
        await _advance(tester);
      }

      expect(
        feed.sourceLabel,
        '新浪财经',
        reason: '主源虽然有病，但备源覆盖不全——切过去会把 PDD 静默丢下，'
            '而整批仍有 A 股有价，于是那一轮还会被判「成功」',
      );
      expect(feed.status.value, FeedStatus.reconnecting);
      feed.dispose();
    });
  });

  group('生命周期：pause 必须挡住已在途的响应', () {
    testWidgets('请求在飞时切后台，落地后不得改写状态、不得推数据', (WidgetTester tester) async {
      final Completer<HttpRawResponse> gate = Completer<HttpRawResponse>();
      final List<Quote> got = <Quote>[];
      final PollingQuoteFeed feed = PollingQuoteFeed(
        onQuotes: got.addAll,
        chain: const <PollingSource>[SinaSource()],
        stocks: _aShares,
        httpGet: (Uri uri, Map<String, String> headers) => gate.future,
      );

      feed.connect();
      await tester.pump(const Duration(milliseconds: 1));
      expect(feed.status.value, FeedStatus.connecting, reason: '这一轮还没回来');

      feed.pause();
      expect(feed.status.value, FeedStatus.disconnected);

      gate.complete(_ok(_sinaLine('000001', 'sz')));
      await tester.pump();
      await tester.pump();

      expect(
        feed.status.value,
        FeedStatus.disconnected,
        reason: '在途响应把 pause 置的 disconnected 顶回 connected，等于后台还在跑',
      );
      expect(got, isEmpty, reason: '后台不该再往 UI 推数据');
      feed.dispose();
    });
  });

  group('时间戳卫生：未来时间戳不得污染只增不减的棘轮', () {
    testWidgets('比现在晚太多的报价被丢弃，且不阻塞后续正常报价', (WidgetTester tester) async {
      final DateTime now = DateTime(2026, 11, 3, 10, 0);
      final _ScriptedSource source = _ScriptedSource(<Quote>[
        _quote('600519', 'SH', DateTime(2027, 1, 1), price: 999),
      ]);
      final List<Quote> got = <Quote>[];
      final PollingQuoteFeed feed = PollingQuoteFeed(
        onQuotes: got.addAll,
        chain: <PollingSource>[source],
        stocks: const <StockConfig>[
          StockConfig(code: '600519', name: '贵州茅台', region: 'SH'),
        ],
        httpGet: (Uri uri, Map<String, String> headers) async =>
            _ok('whatever'),
        now: () => now,
      );

      feed.connect();
      await _start(tester);
      expect(got, isEmpty, reason: '2027 年的报价是脏数据');

      // 关键：脏值不能把这只票永久钉死
      source.next = <Quote>[_quote('600519', 'SH', now, price: 11.5)];
      await _advance(tester);
      expect(got.map((Quote q) => q.price), <double>[11.5]);
      feed.dispose();
    });
  });

  group('腾讯解析器：越界日期必须判死', () {
    test('13 月 / 25 点这类值不得被 DateTime 归一化成未来时间', () {
      const TencentSource source = TencentSource();
      const List<StockConfig> stocks = <StockConfig>[
        StockConfig(code: '600519', name: '贵州茅台', region: 'SH'),
      ];

      // 对照：正常时间能解析出来（否则下面的断言会因为别的原因通过）
      final List<Quote> good = source.parseBatchQuotes(
        _tencentLine('600519', 'sh').codeUnits,
        stocks: stocks,
      );
      expect(good, hasLength(1));
      expect(good.single.timestamp, DateTime(2026, 11, 3, 10, 4, 51));

      for (final String dirty in <String>[
        '20261340100451', // 13 月 → 会被归一化成 2027 年
        '20261103250000', // 25 点 → 会被归一化成次日
        '20261103246000', // 60 分
        '20261103235960', // 60 秒
      ]) {
        final List<Quote> parsed = source.parseBatchQuotes(
          _tencentLine('600519', 'sh', time: dirty).codeUnits,
          stocks: stocks,
        );
        expect(parsed, isEmpty, reason: '越界时间戳 $dirty 必须整条丢弃');
      }
    });
  });
}
