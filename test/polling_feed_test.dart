import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/services/polling_quote_feed.dart';
import 'package:super_market/services/quote_feed.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/services/source/polling_source.dart';
import 'package:super_market/services/source/sina_source.dart';
import 'package:super_market/services/source/tencent_source.dart';

const List<StockConfig> _stocks = <StockConfig>[
  StockConfig(code: '000001', name: '平安银行', region: 'SZ'),
  StockConfig(code: '600519', name: '贵州茅台', region: 'SH'),
];

/// 造一条新浪格式的报文。
///
/// 名称用 ASCII：本文件关心的是**时序与切换**，字符集已在
/// `polling_source_test.dart` 里单独钉过。用中文会让这里的失败原因变模糊
/// （到底是解析坏了还是调度坏了）。
String sinaLine(
  String code,
  String region, {
  double price = 11.49,
  String time = '10:04:54',
}) {
  final List<String> f = <String>[
    'NAME', '11.560', '11.540', '$price', '11.700', '11.420', '11.470',
    '11.480', '65173875', '752536297.040',
    ...List<String>.filled(20, '0'), // 10..29 五档
    '2026-11-03', time, '00',
  ];
  return 'var hq_str_${region.toLowerCase()}$code="${f.join(',')}";';
}

String tencentLine(String code, String region, {double price = 11.48}) {
  final List<String> f = <String>[
    '51', 'NAME', code, '$price', '11.54', '11.56', '651667', '0', '0',
    ...List<String>.filled(20, '0'), // 9..28 五档
    '', // 29 号天然空位
    '20261103100451', '-0.06', '-0.52', '11.70', '11.42', 'x', '651667', '75245',
  ];
  return 'v_${region.toLowerCase()}$code="${f.join('~')}";';
}

/// 可编程的假网络：按 host 分流，并记录每一次调用
class FakeNet {
  FakeNet(this.handler);

  HttpRawResponse Function(Uri uri) handler;
  final List<Uri> calls = <Uri>[];

  List<String> get hosts => calls.map((Uri u) => u.host).toList(growable: false);

  Future<HttpRawResponse> get(Uri uri, Map<String, String> headers) async {
    calls.add(uri);
    return handler(uri);
  }
}

HttpRawResponse ok(String body) =>
    HttpRawResponse(statusCode: 200, body: body.codeUnits);

HttpRawResponse http500(Uri uri) =>
    const HttpRawResponse(statusCode: 500, body: <int>[]);

/// 让「已排队的零延迟 timer」触发，并把 HTTP 的 Future 推完。
///
/// `tester.pump()` 不带时长时只重建一帧、不推进时钟，`Timer(Duration.zero)`
/// 不会触发——这是这类「定时器驱动的服务」在 widget 测试里最常见的坑。
Future<void> start(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 1));
  await tester.pump();
}

/// 推进一个轮询周期（3 秒）并让这一轮落地。
Future<void> advance(WidgetTester tester, [Duration? by]) async {
  await tester.pump(by ?? AppConfig.pollInterval);
  await tester.pump();
  await tester.pump();
}

void main() {
  group('轮询通道：基本节奏', () {
    testWidgets('connect 立即拉一轮，状态从连接中变已连接', (WidgetTester tester) async {
      final FakeNet net = FakeNet((Uri uri) => uri.host == 'hq.sinajs.cn'
          ? ok('${sinaLine('000001', 'SZ')}\n${sinaLine('600519', 'SH')}')
          : http500(uri));
      final List<Quote> got = <Quote>[];
      final PollingQuoteFeed feed = PollingQuoteFeed(
        onQuotes: got.addAll,
        chain: const <PollingSource>[SinaSource()],
        stocks: _stocks,
        httpGet: net.get,
      );

      expect(feed.status.value, FeedStatus.disconnected);
      feed.connect();
      expect(feed.status.value, FeedStatus.connecting);

      await start(tester);

      expect(net.calls, hasLength(1), reason: 'connect 后不该等 3 秒才有数据');
      expect(feed.status.value, FeedStatus.connected);
      expect(got.map((Quote q) => q.code).toSet(), <String>{'000001', '600519'});
      feed.dispose();
    });

    testWidgets('间隔到了才发下一轮（不是无脑连发）', (WidgetTester tester) async {
      final FakeNet net = FakeNet((Uri uri) => ok(sinaLine('000001', 'SZ')));
      final PollingQuoteFeed feed = PollingQuoteFeed(
        onQuotes: (List<Quote> _) {},
        chain: const <PollingSource>[SinaSource()],
        stocks: _stocks,
        httpGet: net.get,
      );

      feed.connect();
      await start(tester);
      expect(net.calls, hasLength(1));

      await tester.pump(const Duration(milliseconds: 2000));
      expect(net.calls, hasLength(1), reason: '2s 时还没到点');

      await advance(tester, const Duration(milliseconds: 1100));
      expect(net.calls, hasLength(2));
      feed.dispose();
    });

    testWidgets('pause 停发、resume 立刻补一轮', (WidgetTester tester) async {
      final FakeNet net = FakeNet((Uri uri) => ok(sinaLine('000001', 'SZ')));
      final PollingQuoteFeed feed = PollingQuoteFeed(
        onQuotes: (List<Quote> _) {},
        chain: const <PollingSource>[SinaSource()],
        stocks: _stocks,
        httpGet: net.get,
      );

      feed.connect();
      await start(tester);
      final int beforePause = net.calls.length;

      feed.pause();
      expect(feed.status.value, FeedStatus.disconnected);
      await tester.pump(const Duration(seconds: 20));
      expect(net.calls, hasLength(beforePause), reason: '后台不该有任何请求');

      feed.resume();
      await start(tester);
      expect(net.calls.length, beforePause + 1, reason: '回前台应立即恢复');
      feed.dispose();
    });

    testWidgets('updateStocks 立刻按新列表拉一轮', (WidgetTester tester) async {
      final FakeNet net = FakeNet((Uri uri) => ok(sinaLine('000001', 'SZ')));
      final PollingQuoteFeed feed = PollingQuoteFeed(
        onQuotes: (List<Quote> _) {},
        chain: const <PollingSource>[SinaSource()],
        stocks: _stocks,
        httpGet: net.get,
      );

      feed.connect();
      await start(tester);

      feed.updateStocks(const <StockConfig>[
        StockConfig(code: '601398', name: '工商银行', region: 'SH'),
      ]);
      await start(tester);

      expect(net.calls.last.path, contains('sh601398'));
      expect(feed.stocks.single.code, '601398');
      feed.dispose();
    });
  });

  group('轮询通道：主备切换', () {
    testWidgets('主力连续失败 3 次后切到备份（第 4 次请求换了域名）',
        (WidgetTester tester) async {
      final FakeNet net = FakeNet((Uri uri) => uri.host == 'hq.sinajs.cn'
          ? http500(uri)
          : ok(tencentLine('000001', 'SZ')));
      final List<Quote> got = <Quote>[];
      final PollingQuoteFeed feed = PollingQuoteFeed(
        onQuotes: got.addAll,
        chain: const <PollingSource>[SinaSource(), TencentSource()],
        stocks: _stocks,
        httpGet: net.get,
      );

      feed.connect();
      await start(tester);
      await advance(tester);
      await advance(tester);

      // 前三次都打在主力上
      expect(
        net.hosts,
        <String>['hq.sinajs.cn', 'hq.sinajs.cn', 'hq.sinajs.cn'],
      );
      expect(feed.sourceLabel, '腾讯财经', reason: '连续 3 次失败后应已切源');
      // 切源那一刻还没拿到一次成功，状态仍是「重连中」——
      // 这就是它该有的语义，不能因为"换了个源"就假装已连接
      expect(feed.status.value, FeedStatus.reconnecting);

      await advance(tester);
      expect(net.hosts.last, 'qt.gtimg.cn');
      expect(got.single.code, '000001');
      expect(feed.status.value, FeedStatus.connected);
      feed.dispose();
    });

    testWidgets('单次失败不换源（地铁进隧道不该让界面闪一下）',
        (WidgetTester tester) async {
      int n = 0;
      final FakeNet net = FakeNet((Uri uri) {
        n++;
        return n == 2 ? http500(uri) : ok(sinaLine('000001', 'SZ'));
      });
      final PollingQuoteFeed feed = PollingQuoteFeed(
        onQuotes: (List<Quote> _) {},
        chain: const <PollingSource>[SinaSource(), TencentSource()],
        stocks: _stocks,
        httpGet: net.get,
      );

      feed.connect();
      await start(tester);
      await advance(tester);

      expect(feed.sourceLabel, '新浪财经');
      expect(net.hosts.toSet(), <String>{'hq.sinajs.cn'});
      feed.dispose();
    });

    testWidgets('切源后更旧的时间戳被丢弃（价格不能往回跳）',
        (WidgetTester tester) async {
      // 主力给 10:04:54 的价，备份给 10:04:51 的旧价
      final FakeNet net = FakeNet((Uri uri) => uri.host == 'hq.sinajs.cn'
          ? ok(sinaLine('000001', 'SZ', price: 11.49, time: '10:04:54'))
          : ok(tencentLine('000001', 'SZ', price: 11.20)));
      final List<Quote> got = <Quote>[];
      final PollingQuoteFeed feed = PollingQuoteFeed(
        onQuotes: got.addAll,
        chain: const <PollingSource>[SinaSource(), TencentSource()],
        stocks: _stocks,
        httpGet: net.get,
      );

      feed.connect();
      await start(tester);
      expect(got, hasLength(1));
      expect(got.single.price, 11.49);

      // 让主力开始失败，逼它切到备份
      net.handler = (Uri uri) => uri.host == 'hq.sinajs.cn'
          ? http500(uri)
          : ok(tencentLine('000001', 'SZ', price: 11.20));
      await advance(tester);
      await advance(tester);
      await advance(tester);
      await advance(tester);

      expect(net.hosts.last, 'qt.gtimg.cn');
      expect(
        got.where((Quote q) => q.price == 11.20),
        isEmpty,
        reason: '备份的时间戳更早，不能覆盖已经在显示的更新价',
      );
      feed.dispose();
    });
  });

  group('轮询通道：全都不通', () {
    testWidgets('一圈都失败后报错并放慢节奏', (WidgetTester tester) async {
      final FakeNet net = FakeNet(http500);
      final PollingQuoteFeed feed = PollingQuoteFeed(
        onQuotes: (List<Quote> _) {},
        chain: const <PollingSource>[SinaSource(), TencentSource()],
        stocks: _stocks,
        httpGet: net.get,
      );

      feed.connect();
      await start(tester);
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(seconds: 10));
        await tester.pump();
      }

      expect(feed.lastError.value, isNotNull);
      expect(feed.lastError.value, contains('都不通'));
      expect(feed.status.value, FeedStatus.reconnecting);
      expect(
        feed.currentInterval,
        greaterThan(AppConfig.pollInterval),
        reason: '一直失败还按 3s 打，只是在刷日志',
      );
      expect(feed.currentInterval, lessThanOrEqualTo(AppConfig.pollBackoffMax));
      // 两个内核都被试过
      expect(net.hosts.toSet(), <String>{'hq.sinajs.cn', 'qt.gtimg.cn'});
      feed.dispose();
    });
  });

  group('轮询通道：对外声明', () {
    test('不需要 Key、自带快照', () {
      final PollingQuoteFeed feed = PollingQuoteFeed(
        onQuotes: (List<Quote> _) {},
        stocks: _stocks,
        httpGet: (Uri uri, Map<String, String> h) async => http500(uri),
      );
      expect(feed.sourceLabel, '新浪财经');
      expect(feed.stocks, hasLength(2));
      feed.dispose();
    });
  });

  group('轮询通道：生命周期回归（审查台账 R-06/R-07/R-14）', () {
    testWidgets('dispose 后在途请求落地，不得触碰已释放的 notifier（R-06）',
        (WidgetTester tester) async {
      final Completer<HttpRawResponse> gate = Completer<HttpRawResponse>();
      final PollingQuoteFeed feed = PollingQuoteFeed(
        onQuotes: (List<Quote> _) {},
        chain: const <PollingSource>[SinaSource()],
        stocks: _stocks,
        httpGet: (Uri uri, Map<String, String> h) => gate.future,
      );

      // 缺陷的可观察信号在日志里：dispose 后写 notifier 的 FlutterError
      // 被 _poll 的 on Object 吞掉、转成一条「轮询失败」日志，
      // 不会走到 unhandled error，所以直接拦截 debugPrint 断言。
      final List<String> logs = <String>[];
      final DebugPrintCallback original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        logs.add(message ?? '');
      };
      try {
        feed.connect();
        await tester.pump(const Duration(milliseconds: 1));
        // 请求还挂在 gate 上时销毁：真正的退出路径就是这样的时序
        feed.dispose();
        gate.complete(ok(sinaLine('000001', 'SZ')));
        await tester.pump();
        await tester.pump();
      } finally {
        debugPrint = original;
      }
      final String all = logs.join('\n');
      expect(
        all.contains('was used after being disposed'),
        isFalse,
        reason: 'dispose 后落地的在途请求不得读写 status/lastError notifier',
      );
      expect(all.contains('轮询成功'), isFalse,
          reason: 'dispose 后不该再走 _onSuccess 的业务路径');
    });

    testWidgets('后台暂停态下 connect() 不得恢复轮询（R-07）',
        (WidgetTester tester) async {
      final FakeNet net = FakeNet((Uri uri) => ok(sinaLine('000001', 'SZ')));
      final PollingQuoteFeed feed = PollingQuoteFeed(
        onQuotes: (List<Quote> _) {},
        chain: const <PollingSource>[SinaSource()],
        stocks: _stocks,
        httpGet: net.get,
      );

      // 冷启动竞态：切后台发生在 bootstrap 的 connect 之前
      feed.pause();
      feed.connect();
      await start(tester);
      await tester.pump(const Duration(seconds: 4));

      expect(net.calls, isEmpty, reason: 'bootstrap 的 connect 不该清掉后台暂停态');
      expect(feed.status.value, FeedStatus.disconnected);
      feed.dispose();
    });

    testWidgets('删空订阅列表：状态归 disconnected；再加回恢复轮询（R-14）',
        (WidgetTester tester) async {
      final FakeNet net = FakeNet((Uri uri) => ok(sinaLine('000001', 'SZ')));
      final PollingQuoteFeed feed = PollingQuoteFeed(
        onQuotes: (List<Quote> _) {},
        chain: const <PollingSource>[SinaSource()],
        stocks: _stocks,
        httpGet: net.get,
      );

      feed.connect();
      await start(tester);
      expect(feed.status.value, FeedStatus.connected);

      feed.updateStocks(const <StockConfig>[]);
      await tester.pump();
      expect(feed.status.value, FeedStatus.disconnected,
          reason: '空列表不该残留「已连接」的假状态');

      feed.updateStocks(_stocks);
      await start(tester);
      expect(net.calls, hasLength(greaterThan(1)),
          reason: '重新加回标的必须恢复轮询');
      feed.dispose();
    });
  });
}
