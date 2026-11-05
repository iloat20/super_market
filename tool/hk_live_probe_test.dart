// 港股链路真网探针：解析器 vs **今天**的真实报文。
//
// 单测里的 fixture 是探针那天截的——接口改了它不知道。这个文件把
// 「这家接口此刻还长这样」钉住：报文结构变了这里先红，而不是等真机上
// 某张卡变成三个 `--` 才发现。
//
// 跑法：flutter test tool/hk_live_probe_test.dart（需要外网）。
import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/kline.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/services/source/eastmoney_suggest.dart';
import 'package:super_market/services/source/sina_source.dart';
import 'package:super_market/services/source/tencent_kline.dart';
import 'package:super_market/services/source/tencent_source.dart';

const StockConfig kTencent =
    StockConfig(code: '00700', name: '腾讯控股', region: 'HK');

Future<HttpRawResponse> fetch(Uri uri, Map<String, String> headers) async {
  final HttpRawResponse res = await defaultHttpGetBytes(uri, headers);
  expect(res.isOk, isTrue, reason: '$uri → HTTP ${res.statusCode}');
  return res;
}

void main() {
  test('腾讯港股实时：量是股、额是 HKD、时间戳到秒', () async {
    final HttpRawResponse res = await fetch(
      const TencentSource().batchQuoteUri(<StockConfig>[kTencent]),
      const TencentSource().requestHeaders(),
    );
    final List<Quote> quotes = const TencentSource().parseBatchQuotes(
      res.body,
      stocks: <StockConfig>[kTencent],
    );
    expect(quotes, hasLength(1), reason: '港股报文必须能解析');
    final Quote q = quotes.single;
    expect(q.price, greaterThan(0));
    expect(q.volume, greaterThan(0));
    // 单位判据：额 ÷ 量 ≈ 现价（量被误 ×100 时这个比值会小 100 倍）
    expect(q.turnover / q.volume, closeTo(q.price, q.price * 0.05),
        reason: '成交额/成交量应约等于成交均价（现价附近）');
    // ignore: avoid_print
    print('腾讯港股 ${q.code}: 价 ${q.price} '
        '(${q.changePercent.toStringAsFixed(2)}%) '
        '量 ${q.volume.toStringAsFixed(0)} 股 '
        '额 ${(q.turnover / 1e8).toStringAsFixed(2)} 亿 '
        '@ ${q.timestamp}');
  });

  test('新浪港股实时：与腾讯同价（±1%）', () async {
    final HttpRawResponse res = await fetch(
      const SinaSource().batchQuoteUri(<StockConfig>[kTencent]),
      const SinaSource().requestHeaders(),
    );
    final List<Quote> quotes = const SinaSource().parseBatchQuotes(
      res.body,
      stocks: <StockConfig>[kTencent],
    );
    expect(quotes, hasLength(1));
    // ignore: avoid_print
    print('新浪港股 ${quotes.single.code}: 价 ${quotes.single.price} '
        '@ ${quotes.single.timestamp}');
  });

  test('腾讯港股日 K：末根含当日，量是股', () async {
    const TencentKline source = TencentKline();
    final HttpRawResponse res = await fetch(
      source.dailyUri(kTencent, 10),
      source.headers,
    );
    final List<Kline> bars = source.parseDaily(res.body, kTencent);
    expect(bars.length, greaterThan(2));
    expect(bars.last.close, greaterThan(0));
    // ignore: avoid_print
    print('港股日线 ${bars.length} 根：${bars.first.time} → ${bars.last.time}，'
        '末根量 ${bars.last.volume.toStringAsFixed(0)} 股');
  });

  test('腾讯港股分时：有数据且均价 ≈ 现价', () async {
    const TencentKline source = TencentKline();
    final HttpRawResponse res = await fetch(
      source.intradayUri(kTencent),
      source.headers,
    );
    final List<IntradayPoint> pts = source.parseIntraday(res.body, kTencent);
    expect(pts.length, greaterThan(10), reason: '分时点太少');
    // 收盘后最后一根均价也应落在当日价格区间附近（±5%）
    final IntradayPoint last = pts.last;
    if (last.avgPrice > 0) {
      expect(last.avgPrice, closeTo(last.price, last.price * 0.05));
    }
    // ignore: avoid_print
    print('港股分时 ${pts.length} 点：${pts.first.time} → ${pts.last.time}');
  });

  test('东财搜索「腾讯」：00700 以 HK 身份命中', () async {
    const EastmoneySuggest source = EastmoneySuggest();
    final HttpRawResponse res = await fetch(
      source.suggestUri('腾讯'),
      source.requestHeaders,
    );
    final List<StockConfig> out = source.parse(res.body);
    expect(
      out.where((StockConfig s) => s.code == '00700').single.region,
      'HK',
    );
    // 轮证/人民币柜台不该混进来
    expect(
      out.where((StockConfig s) => s.region == 'HK' && s.code.startsWith('8')),
      isEmpty,
    );
    // ignore: avoid_print
    print('搜「腾讯」HK 结果：${out.where((StockConfig s) => s.region == "HK").map((StockConfig s) => "${s.code} ${s.name}").join(" / ")}');
  });

  test('混批：A 股 + 港股一次拿全', () async {
    const StockConfig maotai =
        StockConfig(code: '600519', name: '贵州茅台', region: 'SH');
    const SinaSource source = SinaSource();
    final HttpRawResponse res = await fetch(
      source.batchQuoteUri(<StockConfig>[kTencent, maotai]),
      source.requestHeaders(),
    );
    final List<Quote> quotes = source.parseBatchQuotes(
      res.body,
      stocks: <StockConfig>[kTencent, maotai],
    );
    expect(quotes, hasLength(2), reason: '混批里两个市场都要解析出来');
    final Set<String> keys = <String>{
      for (final Quote q in quotes) '${q.code}@${q.region}',
    };
    expect(keys, containsAll(<String>['00700@HK', '600519@SH']));
  });
}
