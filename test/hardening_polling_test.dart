import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/services/polling_quote_feed.dart';
import 'package:super_market/services/quote_feed.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/services/source/polling_source.dart';
import 'package:super_market/services/source/sina_source.dart';
import 'package:super_market/services/source/tencent_source.dart';

/// 审查台账（2026-11-08）批次 A 的回归断言：轮询状态机 / 在途响应 /
/// 覆盖缺口 / 连接池 / 异常分类。原始缺陷下这些断言均为红。
const List<StockConfig> kTwo = <StockConfig>[
  StockConfig(code: '000001', name: 'PINGAN', region: 'SZ'),
  StockConfig(code: '600519', name: 'MAOTAI', region: 'SH'),
];

String sinaLine(String code, String region, {double price = 11.49}) {
  final List<String> f = <String>[
    'NAME', '11.560', '11.540', '$price', '11.700', '11.420', '11.470',
    '11.480', '65173875', '752536297.040',
    ...List<String>.filled(20, '0'),
    '2026-11-03', '10:04:54', '00',
  ];
  return 'var hq_str_${region.toLowerCase()}$code="${f.join(',')}";';
}

HttpRawResponse ok(String body) =>
    HttpRawResponse(statusCode: 200, body: body.codeUnits);

String bothLines() => '${sinaLine('000001', 'SZ')}\n${sinaLine('600519', 'SH')}';

typedef RawHandler = HttpRawResponse Function(Uri uri);

class FakeNet {
  FakeNet(this.handler);

  final RawHandler handler;
  final List<Uri> calls = <Uri>[];

  Future<HttpRawResponse> get(Uri uri, Map<String, String> headers) {
    calls.add(uri);
    return Future<HttpRawResponse>.value(handler(uri));
  }
}

/// 每一轮请求都挂在一个 Completer 上，便于精确制造「在途」。
class GateNet {
  final List<Completer<HttpRawResponse>> gates =
      <Completer<HttpRawResponse>>[];

  Future<HttpRawResponse> get(Uri uri, Map<String, String> headers) {
    final Completer<HttpRawResponse> c = Completer<HttpRawResponse>();
    gates.add(c);
    return c.future;
  }

  void completeLast(HttpRawResponse res) => gates.last.complete(res);
}

/// 前两轮立即失败（把 _failStreak 推到 2），第三轮挂在途。
class ScriptedNet {
  int calls = 0;
  final Completer<HttpRawResponse> third = Completer<HttpRawResponse>();

  Future<HttpRawResponse> get(Uri uri, Map<String, String> headers) {
    calls++;
    if (calls >= 3) {
      return third.future;
    }
    return Future<HttpRawResponse>.value(
      const HttpRawResponse(statusCode: 500, body: <int>[]),
    );
  }
}

Future<void> start(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 1));
  await tester.pump();
}

void main() {
  group('批次 A｜轮询状态机与在途响应', () {
    testWidgets('#2 空自选下 pause→resume 不把状态卡在 connecting',
        (WidgetTester tester) async {
      int calls = 0;
      final PollingQuoteFeed feed = PollingQuoteFeed(
        onQuotes: (_) {},
        chain: const <PollingSource>[SinaSource()],
        stocks: kTwo,
        httpGet: (Uri uri, Map<String, String> headers) {
          calls++;
          return Future<HttpRawResponse>.value(ok(bothLines()));
        },
      );
      feed.connect();
      await start(tester);
      feed.updateStocks(const <StockConfig>[]);
      feed.pause();
      feed.resume();
      await start(tester);

      expect(feed.status.value, FeedStatus.disconnected,
          reason: '空订阅没有可拉的对象，resume 不该宣称正在连接并永远不回退');
      feed.updateStocks(kTwo);
      await start(tester);
      expect(calls, greaterThan(1), reason: '重新加回订阅后轮询链必须能自行恢复');
      feed.dispose();
    });

    testWidgets('#3 后台在途失败不得推进切源与退避', (WidgetTester tester) async {
      final ScriptedNet net = ScriptedNet();
      final PollingQuoteFeed feed = PollingQuoteFeed(
        onQuotes: (_) {},
        chain: const <PollingSource>[SinaSource(), TencentSource()],
        stocks: kTwo,
        httpGet: net.get,
        interval: const Duration(milliseconds: 1),
      );
      feed.connect();
      await tester.pump(const Duration(milliseconds: 1));
      for (int i = 0; i < 2; i++) {
        await tester.pump(const Duration(milliseconds: 2));
        await tester.pump();
      }
      expect(net.calls, 3, reason: '第三次请求应已在途');
      expect(feed.sourceLabel, '新浪财经');

      feed.pause();
      net.third.complete(const HttpRawResponse(statusCode: 500, body: <int>[]));
      await tester.pump();
      await tester.pump();

      expect(feed.sourceLabel, '新浪财经',
          reason: 'pause 之后落地的失败不得累计失败次数、不得切源');
      expect(feed.lastError.value, isNull);
      feed.dispose();
    });

    testWidgets('#4 主链本轮漏掉 A 股行时要报缺口，不静默判成功',
        (WidgetTester tester) async {
      final FakeNet net = FakeNet((Uri uri) => ok(sinaLine('600519', 'SH')));
      final PollingQuoteFeed feed = PollingQuoteFeed(
        onQuotes: (_) {},
        chain: const <PollingSource>[SinaSource()],
        stocks: kTwo,
        httpGet: net.get,
      );
      feed.connect();
      await start(tester);

      expect(feed.status.value, FeedStatus.connected);
      expect(feed.lastError.value, isNotNull,
          reason: '000001 本轮没回来，却没有任何可观测信号');
      expect(feed.lastError.value, contains('旧价'));
      feed.dispose();
    });

    testWidgets('#11 在途响应落地时不得把已删除标的推给 UI',
        (WidgetTester tester) async {
      final GateNet net = GateNet();
      final List<Quote> got = <Quote>[];
      final PollingQuoteFeed feed = PollingQuoteFeed(
        onQuotes: got.addAll,
        chain: const <PollingSource>[SinaSource()],
        stocks: kTwo,
        httpGet: net.get,
      );
      feed.connect();
      await tester.pump(const Duration(milliseconds: 1));
      feed.updateStocks(const <StockConfig>[
        StockConfig(code: '600519', name: 'MAOTAI', region: 'SH'),
      ]);
      net.completeLast(ok(bothLines()));
      await tester.pump();
      await tester.pump();

      expect(got.map((Quote q) => q.code).toList(), isNot(contains('000001')),
          reason: '旧订阅快照的响应不得回写已删除标的');
      feed.dispose();
    });

    testWidgets('#7 编码错误不得被当成可重试的网络失败',
        (WidgetTester tester) async {
      final PollingQuoteFeed feed = PollingQuoteFeed(
        onQuotes: (_) {},
        chain: const <PollingSource>[SinaSource(), TencentSource()],
        stocks: kTwo,
        httpGet: (Uri uri, Map<String, String> headers) =>
            Future<HttpRawResponse>.error(ArgumentError('只允许 https')),
      );
      feed.connect();
      await start(tester);

      expect(feed.lastError.value, contains('配置'),
          reason: 'requireHttps 的 ArgumentError 是编码错误，不该被降级成「源暂时都不通」');
      expect(feed.sourceLabel, '新浪财经', reason: '编码错误不该触发切源');
      feed.dispose();
    });
  });

  group('批次 A｜共享连接池', () {
    test('#6 失败置脏后不得 force-close 仍在途的并发请求', () {
      final String src =
          File('lib/services/rest_client.dart').readAsStringSync();
      final int begin = src.indexOf('HttpClient get _httpClient');
      final int end = src.indexOf('/// 丢掉当前连接池', begin);
      expect(begin, greaterThan(-1));
      expect(end, greaterThan(begin));
      final String getter = src.substring(begin, end);

      expect(getter.contains('close(force: true)'), isFalse,
          reason: 'force close 会击落同一池上其它模块的在途请求');
      expect(src.contains('_sharedClientInFlight'), isTrue,
          reason: '重建必须等共享池上没有在途请求');
    });
  });
}
