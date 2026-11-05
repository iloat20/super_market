// 真网探针：把 PollingQuoteFeed 接到真实新浪 / 腾讯接口上跑几轮。
//
// 单测全是假网络，只能证明"逻辑对"，证明不了"这家接口现在还长这样"。
// 这个探针回答三个只有真网能回答的问题：
//   1. 能不能真的拿到报价（而不是被 403 / 空串挡住）；
//   2. 3 秒节奏下报价有多旧（staleness），时间戳单位对不对；
//   3. 代码目录能不能真的翻完 70 页（「换股票」功能的地基）。
//
// 用法（必须先去掉代理，否则 WS/HTTP 都会走 proxy 失败）：
//   unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY
//   flutter test tool/polling_live_probe_test.dart
//
// 环境变量：
//   PROBE_ROUNDS=3      轮询几轮
//   PROBE_CATALOG=1     是否下载全量目录（约 20s、70 个请求）

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/services/polling_quote_feed.dart';
import 'package:super_market/services/quote_feed.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/services/source/sina_source.dart';

void main() {
  final int rounds = int.tryParse(Platform.environment['PROBE_ROUNDS'] ?? '') ?? 3;
  final bool withCatalog = Platform.environment['PROBE_CATALOG'] == '1';

  test('真网：轮询通道能拿到实时价', () async {
    final DateTime startedAt = DateTime.now();
    final List<Quote> got = <Quote>[];
    final List<String> log = <String>[];

    final PollingQuoteFeed feed = PollingQuoteFeed(
      onQuotes: (List<Quote> q) {
        got.addAll(q);
        for (final Quote one in q) {
          final DateTime? t = one.timestamp;
          final int stale = t == null
              ? -1
              : DateTime.now().difference(t).inMilliseconds;
          log.add('  ${one.code}@${one.region} ${one.price.toStringAsFixed(2)} '
              '(${one.changePercent.toStringAsFixed(2)}%) '
              '量 ${one.volume.toInt()} 额 ${one.turnover.toStringAsFixed(0)} '
              't=${t?.toIso8601String()} 陈旧 ${stale}ms');
        }
      },
      stocks: AppConfig.stocks,
    );

    stdout.writeln('轮询 ${AppConfig.stocks.length} 只，'
        '间隔 ${AppConfig.pollInterval.inSeconds}s，共 $rounds 轮');
    feed.connect();
    await Future<void>.delayed(
      AppConfig.pollInterval * rounds + const Duration(seconds: 2),
    );
    feed.dispose();

    stdout.writeln('状态：${feed.status.value}，来源：${feed.sourceLabel}');
    for (final String line in log) {
      stdout.writeln(line);
    }

    expect(got, isNotEmpty, reason: '一条报价都没拿到，接口或解析已经变了');
    expect(feed.status.value, FeedStatus.connected);
    // 3 只 × 每轮一条；允许服务端偶尔少回一只
    expect(got.length, greaterThanOrEqualTo(AppConfig.stocks.length));
    expect(
      DateTime.now().difference(startedAt).inSeconds,
      greaterThan(0),
      reason: '确保真的等了，不是同步返回',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('真网：批量地址与 Referer 在真实服务端上成立', () async {
    const SinaSource source = SinaSource();
    final HttpRawResponse res = await defaultHttpGetBytes(
      source.batchQuoteUri(AppConfig.stocks),
      source.requestHeaders(),
    );
    final String preview =
        String.fromCharCodes(res.body.take(120).toList(growable: false));
    stdout.writeln('HTTP ${res.statusCode}，${res.byteLength} 字节');
    stdout.writeln('前 120 字节：$preview');

    expect(res.statusCode, 200, reason: '403 就是 Referer 失效了');
    final List<Quote> quotes =
        source.parseBatchQuotes(res.body, stocks: AppConfig.stocks);
    stdout.writeln('解析出 ${quotes.length} 条');
    expect(quotes, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('真网：代码目录能翻完全市场', () async {
    if (!withCatalog) {
      stdout.writeln('跳过（PROBE_CATALOG=1 才跑，约 20s / 70 个请求）');
      return;
    }
    const SinaSource source = SinaSource();
    final Stopwatch sw = Stopwatch()..start();
    final List<StockConfig> all = await source.fetchSymbols(
      httpGet: defaultHttpGet,
    );
    sw.stop();

    final int sh = all.where((StockConfig s) => s.region == 'SH').length;
    final int sz = all.where((StockConfig s) => s.region == 'SZ').length;
    stdout.writeln('目录 ${all.length} 条（SH $sh / SZ $sz），'
        '耗时 ${sw.elapsed.inMilliseconds}ms');

    final List<StockConfig> hits = all
        .where((StockConfig s) =>
            s.code == '600519' || s.code == '000001' || s.code == '601398')
        .toList();
    for (final StockConfig s in hits) {
      stdout.writeln('  ${s.key} ${s.name}');
    }

    expect(all.length, greaterThan(4000), reason: '沪深 A 股应在 5000 条量级');
    expect(hits, hasLength(3), reason: '三只常见票必须能在目录里搜到');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
