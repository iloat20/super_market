// 美股链路真网探针：解析器 vs **今天**的真实报文（与 hk_live_probe 同思路）。
//
// 单测里的 fixture 是探针那天截的——接口改了它不知道。这个文件把
// 「这家接口此刻还长这样」钉住：报文结构变了这里先红，而不是等真机上
// 某张卡变成三个 `--` 才发现。
//
// 事实链（2026-11-05 / 11-07 实测，细节见 README「二·三十三」「二·四十」）：
// - 新浪报价支持美股（`gb_` 前缀），且 **A/H/美股混批一发全回**；
// - 新浪 K 线不支持美股（`data:null`），美股 K 线只有腾讯 ifzq；
// - 腾讯 qt.gtimg.cn 报价端点不支持美股（`v_pv_none_match`），但
//   **混批里 A/H 照常返回、美股静默缺失**——切源时 A/H 不受影响；
// - 腾讯 ifzq 的日 K 响应里带 `qt` 报价块（美股也有、与新浪同价），但
//   **一只票要发一次 K 线请求**，不能批量；所以只把它当事实记录，不用作补位；
// - 东财 push2 支持美股**批量**报价（`secids=105.AAPL,106.BABA`），
//   与新浪逐字段同值，是现在的美股补位源（`EastmoneyUsSource`）；
// - 带点/下划线的多类股（BRK.B / BRK_B）两家都拿不到数据，搜索侧已挡。
//
// 跑法：unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY &&
//       flutter test tool/us_live_probe_test.dart（需要外网）。
import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/kline.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/services/source/eastmoney_us_source.dart';
import 'package:super_market/services/source/sina_kline.dart';
import 'package:super_market/services/source/sina_source.dart';
import 'package:super_market/services/source/tencent_kline.dart';
import 'package:super_market/services/source/tencent_source.dart';

const StockConfig kApple = StockConfig(
  code: 'AAPL',
  name: '苹果',
  region: 'US',
  exchange: 'NASDAQ',
);
const StockConfig kBaba = StockConfig(
  code: 'BABA',
  name: '阿里巴巴',
  region: 'US',
  exchange: 'NYSE',
);
const StockConfig kGeely = StockConfig(
  code: '000651',
  name: '格力电器',
  region: 'SZ',
);

Future<HttpRawResponse> fetch(Uri uri, Map<String, String> headers) async {
  final HttpRawResponse res = await defaultHttpGetBytes(uri, headers);
  expect(res.isOk, isTrue, reason: '$uri → HTTP ${res.statusCode}');
  return res;
}

void main() {
  test('新浪美股实时：字段表 + 单位自洽（额÷量≈现价）', () async {
    final HttpRawResponse res = await fetch(
      const SinaSource().batchQuoteUri(<StockConfig>[kApple]),
      const SinaSource().requestHeaders(),
    );
    final List<Quote> quotes = const SinaSource().parseBatchQuotes(
      res.body,
      stocks: <StockConfig>[kApple],
    );
    expect(quotes, hasLength(1), reason: 'gb_aapl 报文必须能解析');
    final Quote q = quotes.single;
    expect(q.price, greaterThan(0));
    expect(q.volume, greaterThan(0));
    expect(q.previousClose, greaterThan(0), reason: '昨收在 [26]，漏了它振幅就没了');
    // 单位判据：额 ÷ 量 ≈ 现价（量被误 ×100 或额被换算错时这个比值会歪）
    expect(
      q.turnover / q.volume,
      closeTo(q.price, q.price * 0.05),
      reason: '成交额/成交量应约等于成交均价（现价附近）',
    );
    // ignore: avoid_print
    print(
      '新浪美股 ${q.code}: 价 ${q.price} '
      '(${q.changePercent.toStringAsFixed(2)}%) '
      '量 ${q.volume.toStringAsFixed(0)} 股 '
      '额 ${(q.turnover / 1e8).toStringAsFixed(2)} 亿USD '
      '@ ${q.timestamp}',
    );
  });

  test('新浪混批：A 股 + 美股一发全回（轮询架构不变的前提）', () async {
    final HttpRawResponse res = await fetch(
      const SinaSource().batchQuoteUri(<StockConfig>[kGeely, kApple]),
      const SinaSource().requestHeaders(),
    );
    final List<Quote> quotes = const SinaSource().parseBatchQuotes(
      res.body,
      stocks: <StockConfig>[kGeely, kApple],
    );
    final Set<String> keys = <String>{
      for (final Quote q in quotes) '${q.code}@${q.region}',
    };
    expect(keys, containsAll(<String>['000651@SZ', 'AAPL@US']));
  });

  test('腾讯 ifzq 日 K：NASDAQ 后缀 .OQ、量是股、末根含当日', () async {
    const TencentKline source = TencentKline();
    final HttpRawResponse res = await fetch(
      source.dailyUri(kApple, 10),
      source.headers,
    );
    final List<Kline> bars = source.parseDaily(res.body, kApple);
    expect(bars.length, greaterThan(2));
    expect(bars.last.close, greaterThan(0));
    expect(
      bars.last.volume,
      lessThan(1e8),
      reason: '美股量是股（AAPL 一天 ~1 亿股）；若被 ×100 会到 1e10 量级',
    );
    // ignore: avoid_print
    print(
      '美股日线 ${bars.length} 根：${bars.first.time} → ${bars.last.time}，'
      '末根量 ${bars.last.volume.toStringAsFixed(0)} 股',
    );
  });

  test('腾讯 ifzq 日 K：NYSE 后缀 .N（中概 ADR）', () async {
    const TencentKline source = TencentKline();
    final HttpRawResponse res = await fetch(
      source.dailyUri(kBaba, 5),
      source.headers,
    );
    final List<Kline> bars = source.parseDaily(res.body, kBaba);
    expect(bars, isNotEmpty, reason: 'usBABA.N 必须有数据（.N 后缀写法实测有效）');
  });

  test('东财 push2 美股报价：批量两只、与新浪同值（补位源的真网证据）', () async {
    const EastmoneyUsSource em = EastmoneyUsSource();
    const List<StockConfig> stocks = <StockConfig>[kApple, kBaba];
    final HttpRawResponse res = await fetch(
      em.batchQuoteUri(stocks),
      em.requestHeaders(),
    );
    final List<Quote> quotes = em.parseBatchQuotes(res.body, stocks: stocks);
    expect(quotes, hasLength(2), reason: '105.AAPL / 106.BABA 各一只，批量必须都回');

    final Quote apple = quotes.firstWhere((Quote q) => q.code == 'AAPL');
    expect(apple.price, greaterThan(0));
    expect(apple.previousClose, greaterThan(0), reason: '昨收缺失就没有振幅');
    expect(apple.volume, greaterThan(0));
    // 单位判据：额 ÷ 量 ≈ 现价（缩放错了这个比值会歪 10 倍）
    expect(
      apple.turnover / apple.volume,
      closeTo(apple.price, apple.price * 0.05),
      reason: '成交额/成交量应约等于成交均价',
    );
    expect(apple.timestamp, isNotNull, reason: 'f124 是最后成交时刻');

    // 与新浪对同一只票：两次请求相隔几百毫秒，盘中允许小幅差异
    const SinaSource sina = SinaSource();
    final HttpRawResponse sinaRes = await fetch(
      sina.batchQuoteUri(<StockConfig>[kApple]),
      sina.requestHeaders(),
    );
    final Quote sinaApple = sina
        .parseBatchQuotes(sinaRes.body, stocks: <StockConfig>[kApple])
        .single;
    expect(
      apple.price,
      closeTo(sinaApple.price, sinaApple.price * 0.01),
      reason: '两个源对 AAPL 的价差超过 1% 就说明有一边读错了字段',
    );
    // ignore: avoid_print
    print(
      '东财美股 ${apple.code}: 价 ${apple.price} '
      '(${apple.changePercent.toStringAsFixed(2)}%) '
      '量 ${apple.volume.toStringAsFixed(0)} 股 '
      '@ ${apple.timestamp}｜新浪同价 ${sinaApple.price}',
    );
  });

  test('腾讯 qt.gtimg 报价端点不支持美股：解析为空（切源时 US 卡停更快照）', () async {
    final HttpRawResponse res = await fetch(
      const TencentSource().batchQuoteUri(<StockConfig>[kApple]),
      const TencentSource().requestHeaders(),
    );
    final List<Quote> quotes = const TencentSource().parseBatchQuotes(
      res.body,
      stocks: <StockConfig>[kApple],
    );
    expect(quotes, isEmpty, reason: 'v_pv_none_match：这是已知限制，不是解析错误');
  });

  test('新浪 K 线不支持美股：supports 挡住（不发注定为空的请求）', () {
    expect(const SinaKline().supports(kApple), isFalse);
  });
}
