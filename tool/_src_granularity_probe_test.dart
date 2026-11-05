// 一次性探针：腾讯 vs 新浪，服务端快照更新粒度对拍。
//
// 各以 1s 高频轮询 N 轮，记录每轮拿到的报价时间戳；相邻时间戳的差
// 就是服务端的快照粒度（客户端再快也只能拿到同一份缓存）。
//
// 用法：
//   NO_PROXY=localhost,127.0.0.1 GRAN_ROUNDS=40 flutter test tool/_src_granularity_probe_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/services/source/polling_source.dart';
import 'package:super_market/services/source/sina_source.dart';
import 'package:super_market/services/source/tencent_source.dart';

class Obs {
  Obs(this.recvMs, this.quoteMs, this.vol);
  final int recvMs;
  final int quoteMs;
  final double vol; // 成交量：同一份快照它一定不变
}

Future<List<Obs>> probe(
  PollingSource source,
  List<StockConfig> stocks,
  int rounds,
) async {
  final List<Obs> out = <Obs>[];
  for (int i = 0; i < rounds; i++) {
    final int t0 = DateTime.now().millisecondsSinceEpoch;
    try {
      final HttpRawResponse res = await defaultHttpGetBytes(
        source.batchQuoteUri(stocks),
        source.requestHeaders(),
      );
      if (res.isOk) {
        final List<Quote> quotes =
            source.parseBatchQuotes(res.body, stocks: stocks);
        if (quotes.isNotEmpty) {
          final Quote q = quotes.first;
          final DateTime? ts = q.timestamp;
          if (ts != null) {
            int ms = ts.millisecondsSinceEpoch;
            if (ts.year < 2000) {
              ms *= 1000;
            }
            out.add(Obs(t0, ms, q.volume.toDouble()));
          }
        }
      }
      // ignore: avoid_catches_without_on_exceptions
    } catch (_) {}
    final int spent = DateTime.now().millisecondsSinceEpoch - t0;
    if (spent < 1000) {
      await Future<void>.delayed(Duration(milliseconds: 1000 - spent));
    }
  }
  return out;
}

void report(String name, List<Obs> obs) {
  stdout.writeln('==== $name（${obs.length} 轮）====');
  if (obs.isEmpty) {
    stdout.writeln('  无数据');
    return;
  }
  int repeats = 0;
  final List<int> gaps = <int>[];
  for (int i = 1; i < obs.length; i++) {
    final int d = obs[i].quoteMs - obs[i - 1].quoteMs;
    if (d == 0) {
      repeats++;
    } else {
      gaps.add(d);
    }
  }
  gaps.sort();
  stdout.writeln(
      '  快照时间变化 ${gaps.length} 次，重复快照 $repeats 次（'
      '${(repeats * 100 / (obs.length - 1)).toStringAsFixed(0)}% 命中缓存）');
  if (gaps.isNotEmpty) {
    stdout.writeln(
        '  快照粒度: min=${gaps.first}ms p50=${gaps[gaps.length ~/ 2]}ms '
        'max=${gaps.last}ms');
  }
  final List<int> stale =
      obs.map((Obs o) => o.recvMs - o.quoteMs).toList()..sort();
  stdout.writeln(
      '  陈旧度: p50=${stale[stale.length ~/ 2]}ms p90='
      '${stale[(stale.length * 0.9).floor()]}ms max=${stale.last}ms');
}

void main() {
  final int rounds =
      int.tryParse(Platform.environment['GRAN_ROUNDS'] ?? '') ?? 40;

  test('腾讯 vs 新浪 快照粒度对拍', () async {
    const List<StockConfig> stocks = AppConfig.stocks;
    final List<Obs> tx = await probe(TencentSource(), stocks, rounds);
    final List<Obs> sina = await probe(SinaSource(), stocks, rounds);
    report('腾讯 qt.gtimg.cn', tx);
    report('新浪 hq.sinajs.cn', sina);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
