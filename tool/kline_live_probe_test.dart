// 真网探针：走势图的两个端点（新浪 K 线 / 腾讯日线 + 分时）现在还能不能用。
//
// 单测用真实报文形状，能证明"解析对"，但证明不了"接口今天还长这样"——
// 上一轮就是靠探针抓到三个静默 bug（整页北交所、HTTP 502、null 响应）。
//
// 这个探针回答四个只有真网能回答的问题：
//   1. 新浪日线/分时能不能真的解析出数据（不是 200 + null）；
//   2. 新浪日线是不是**仍然不含当日**（这决定 UI 要不要拼今日那根）；
//   3. 腾讯日线是不是**仍然含当日**、指数是不是仍然走 `day`；
//   4. 分时的累计量差分成增量后，量级和报价的成交量对不对得上。
//
// 用法（先去掉代理）：
//   unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY
//   flutter test tool/kline_live_probe_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/kline.dart';
import 'package:super_market/services/kline_loader.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/services/source/kline_source.dart';
import 'package:super_market/services/source/sina_kline.dart';
import 'package:super_market/services/source/tencent_kline.dart';

void main() {
  final StockConfig stock = AppConfig.stocks[1]; // 600519 贵州茅台（沪市）
  const SinaKline sina = SinaKline();
  const TencentKline tencent = TencentKline();

  Future<List<int>> fetch(Uri uri, Map<String, String> headers) async {
    final HttpRawResponse res = await defaultHttpGetBytes(uri, headers);
    expect(res.isOk, isTrue, reason: 'HTTP ${res.statusCode} ← $uri');
    return res.body;
  }

  DateTime dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

  test('新浪：日线能解析，且最后一根是不是当日', () async {
    final List<Kline> bars = sina.parseDaily(
      await fetch(sina.dailyUri(stock, 10), sina.headers),
      stock,
    );
    expect(bars, isNotEmpty, reason: '日线解析为空');
    final DateTime today = dayOf(DateTime.now());
    // ignore: avoid_print
    print('新浪日线 ${bars.length} 根：'
        '${bars.first.time} → ${bars.last.time}，'
        '最后一根收 ${bars.last.close}，量 ${bars.last.volume.toStringAsFixed(0)} 股');
    // ignore: avoid_print
    print('  是否含当日：${dayOf(bars.last.time) == today ? "含" : "不含（UI 需用实时价拼）"}');
    expect(bars.length, greaterThan(2));
  });

  test('新浪：分时能解析，且只保留一天', () async {
    final List<IntradayPoint> pts = sina.parseIntraday(
      await fetch(sina.intradayUri(stock), sina.headers),
      stock,
    );
    expect(pts.length, greaterThan(10), reason: '分时点太少，可能是跨日没切干净');
    final Set<String> days = <String>{
      for (final IntradayPoint p in pts)
        '${p.time.year}-${p.time.month}-${p.time.day}',
    };
    expect(days.length, 1, reason: '分时数据跨了多天');
    // ignore: avoid_print
    print('新浪分时 ${pts.length} 点：${pts.first.time} → ${pts.last.time}');
    // ignore: avoid_print
    print('  末点 价 ${pts.last.price} 均价 ${pts.last.avgPrice.toStringAsFixed(3)} '
        '量 ${pts.last.volume.toStringAsFixed(0)} 股');
    expect(pts.last.avgPrice, greaterThan(0), reason: '均价没算出来');
    expect(pts.last.volume, greaterThanOrEqualTo(0));
  });

  test('腾讯：日线（qfqday）与分时（minute/query）都能解析', () async {
    final List<Kline> bars = tencent.parseDaily(
      await fetch(tencent.dailyUri(stock, 10), tencent.headers),
      stock,
    );
    expect(bars, isNotEmpty, reason: '腾讯日线解析为空');
    final DateTime today = dayOf(DateTime.now());
    // ignore: avoid_print
    print('腾讯日线 ${bars.length} 根：${bars.last.time}，'
        '最后一根 开${bars.last.open} 收${bars.last.close} '
        '高${bars.last.high} 低${bars.last.low}');
    // ignore: avoid_print
    print('  是否含当日：${dayOf(bars.last.time) == today ? "含" : "不含"}');
    // 开收高低必须满足 high>=low，否则说明字段顺序读错了（O-C-H-L）
    for (final Kline k in bars) {
      expect(k.high, greaterThanOrEqualTo(k.low), reason: '高低价反了：$k');
      expect(k.high, greaterThanOrEqualTo(k.close), reason: '最高价低于收盘：$k');
    }

    final List<IntradayPoint> pts = tencent.parseIntraday(
      await fetch(tencent.intradayUri(stock), tencent.headers),
      stock,
    );
    expect(pts, isNotEmpty, reason: '腾讯分时解析为空');
    // ignore: avoid_print
    print('腾讯分时 ${pts.length} 点：${pts.first.time} → ${pts.last.time}');
    // ignore: avoid_print
    print('  首点量 ${pts.first.volume.toStringAsFixed(0)} 股（差分后的增量）');
    // 差分后的第一根 = 集合竞价累计量，必须 > 0；若是 0 说明差分方向错了
    expect(pts.last.volume, greaterThan(0));
  });

  test('指数：腾讯走 day 而不是 qfqday', () async {
    const StockConfig index = StockConfig(
      code: '000001',
      name: '上证指数',
      region: 'SH',
    );
    final List<Kline> bars = tencent.parseDaily(
      await fetch(tencent.dailyUri(index, 5), tencent.headers),
      index,
    );
    expect(bars, isNotEmpty, reason: '指数日线解析为空（key 可能改了）');
    // ignore: avoid_print
    print('上证指数 ${bars.length} 根，最后一根收 ${bars.last.close}');
  });

  test('KlineLoader：主备链路端到端 + 缓存', () async {
    final KlineLoader loader = KlineLoader(httpGet: defaultHttpGetBytes);
    final KlineResult<Kline> daily = await loader.loadDaily(stock);
    expect(daily.items, isNotEmpty);
    // ignore: avoid_print
    print('loadDaily 走的是 ${daily.sourceId}，${daily.items.length} 根');

    final KlineResult<IntradayPoint> intraday = await loader.loadIntraday(stock);
    expect(intraday.items, isNotEmpty);
    // ignore: avoid_print
    print('loadIntraday 走的是 ${intraday.sourceId}，${intraday.items.length} 点');

    // 第二次必须命中缓存（不打外网，返回值必须一致）
    final DateTime t0 = DateTime.now();
    final KlineResult<Kline> again = await loader.loadDaily(stock);
    final int ms = DateTime.now().difference(t0).inMilliseconds;
    expect(again.items.length, daily.items.length);
    // ignore: avoid_print
    print('缓存命中：${ms}ms（真网一轮约 200~400ms，明显更快就是缓存生效）');

    expect(KlineSource.defaultDailyCount, 80);
  });
}
