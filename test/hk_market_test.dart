import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/kline.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/services/kline_loader.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/services/source/eastmoney_suggest.dart';
import 'package:super_market/services/source/sina_kline.dart';
import 'package:super_market/services/source/sina_source.dart';
import 'package:super_market/services/source/tencent_kline.dart';
import 'package:super_market/services/source/tencent_source.dart';
import 'package:super_market/services/watchlist_repository.dart';
import 'package:super_market/utils/market_session.dart';
import 'package:super_market/widgets/kline_chart.dart';

/// 港股（H 股）支持。
///
/// 所有 fixture 都来自 2026-11-03 盘中的真网探针，不是编的：
/// 单位换算的判据是「成交额 ÷ 成交量 ≈ 现价」——A 股腾讯的量是**手**，
/// 港股腾讯的量**本来就是股**，两边连时间戳格式都不一样。
const StockConfig kTencent =
    StockConfig(code: '00700', name: '腾讯控股', region: 'HK');
const StockConfig kPingAn =
    StockConfig(code: '000001', name: '平安银行', region: 'SZ');
const StockConfig kMaotai =
    StockConfig(code: '600519', name: '贵州茅台', region: 'SH');

List<int> _b(String s) => latin1.encode(s);

/// 腾讯港股实时报价（真网截取，中文名换成 ASCII 占位——解析器不使用名称）
const String _tencentHkLine =
    'v_hk00700="100~XX~00700~396.600~392.200~393.200~13442881.0~0~0~'
    '396.600~0~0~0~0~0~0~0~0~0~396.600~0~0~0~0~0~0~0~0~0~13442881.0~'
    '2026/11/03 13:43:12~4.400~1.12~402.600~391.800~396.600~13442881.0~'
    '5353940287.600~0~14.49~~0~0~2.75~36061.4294~36061.4294~TENCENT~'
    '1.34~656.700~375.200~1.19~7.71~0~0~0~0~0~13.30~2.77~0.15~100~'
    '-33.20~2.96~GP~20.41~11.00~-3.36~-6.24~-17.17~9092644829.00~'
    '9092644829.00~13.72~5.315~398.273~-26.85~HKD~1~30";';

/// 新浪港股实时报价（真网截取 14:30:19）
const String _sinaHkLine = 'var hq_str_rt_hk00700="TENCENT,XX,393.200,'
    '392.200,402.600,391.800,397.000,4.800,1.224,396.800,397.000,'
    '6139652907.100,15425176,14.429,0.000,654.376,375.200,'
    '2026/11/03,14:30:19,30|3,N|Y|Y,0.000|0.000|0.000,'
    '0|||0.000|0.000|0.000, |0,Y";';

void main() {
  group('协议写法（wireSymbol）', () {
    test('腾讯港股是 hk + 5 位代码', () {
      expect(TencentSource.wireSymbol(kTencent), 'hk00700');
      expect(TencentSource.wireSymbol(kPingAn), 'sz000001');
    });
    test('新浪港股前缀是 rt_hk（不是 hk）', () {
      expect(SinaSource.wireSymbol(kTencent), 'rt_hk00700');
      expect(SinaSource.wireSymbol(kPingAn), 'sz000001');
    });
    test('两家源的 markets 都含 HK', () {
      expect(const TencentSource().markets, contains('HK'));
      expect(const SinaSource().markets, contains('HK'));
    });
  });

  group('腾讯港股报价解析', () {
    test('量是股、额是 HKD 元，都不换算', () {
      final List<Quote> quotes = const TencentSource().parseBatchQuotes(
        _b(_tencentHkLine),
        stocks: <StockConfig>[kTencent],
      );
      expect(quotes, hasLength(1));
      final Quote q = quotes.single;
      expect(q.code, '00700');
      expect(q.region, 'HK');
      expect(q.price, 396.600);
      expect(q.previousClose, 392.200);
      expect(q.open, 393.200);
      expect(q.high, 402.600);
      expect(q.low, 391.800);
      // 量：13442881 股（A 股同位置是手，要 ×100——这里不能乘）
      expect(q.volume, 13442881);
      // 额：53.5 亿 HKD（A 股同位置是万元——这里不能 ×10000）
      expect(q.turnover, closeTo(5353940287.6, 0.01));
      // 单位自洽：额 ÷ 量 ≈ 现价（±1%）
      expect(q.turnover / q.volume, closeTo(q.price, q.price * 0.01));
      // 港股时间戳是 `2026/11/03 13:43:12`
      expect(q.timestamp, DateTime(2026, 11, 3, 13, 43, 12));
    });

    test('A 股解析不受影响：量 ×100、额 ×10000', () {
      const String line =
          'v_sz000001="51~XX~000001~11.48~11.54~11.56~651667~0~0~11.48~0~0~'
          '0~0~0~0~0~0~0~11.48~0~0~0~0~0~0~0~0~0~651667~20261103100451~'
          '-0.06~-0.52~11.70~11.42~11.48/651667/752453594~651667~75245~";';
      final List<Quote> quotes = const TencentSource().parseBatchQuotes(
        _b(line),
        stocks: <StockConfig>[kPingAn],
      );
      expect(quotes, hasLength(1));
      expect(quotes.single.volume, 65166700); // 手 → 股
      expect(quotes.single.turnover, closeTo(752450000, 1)); // 万元 → 元
    });
  });

  group('新浪港股报价解析', () {
    test('现价/涨跌取自现成字段，量是股', () {
      final List<Quote> quotes = const SinaSource().parseBatchQuotes(
        _b(_sinaHkLine),
        stocks: <StockConfig>[kTencent],
      );
      expect(quotes, hasLength(1));
      final Quote q = quotes.single;
      expect(q.price, 397.000);
      expect(q.change, 4.800);
      expect(q.changePercent, closeTo(1.224, 0.0001));
      expect(q.volume, 15425176);
      expect(q.turnover, closeTo(6139652907.1, 0.01));
      expect(q.timestamp, DateTime(2026, 11, 3, 14, 30, 19));
      // 额 ÷ 量 ≈ 现价
      expect(q.turnover / q.volume, closeTo(q.price, q.price * 0.01));
    });

    test('恰好 32 字段的 A 股变体报文被安全跳过（不 RangeError）', () {
      // 守卫曾是 f.length < 32，而 _status(f) 读 f[32]——恰好 32 字段的
      // 变体报文会 RangeError，且 parseBatchQuotes 无 try-catch，
      // 一轮解析炸掉整批行情。守卫改 33 后应整行跳过。
      final List<String> f = List<String>.filled(32, '0');
      f[0] = 'XX';
      f[1] = '11.56'; // 今开
      f[2] = '11.54'; // 昨收
      f[3] = '11.49'; // 现价
      f[4] = '11.70'; // 最高
      f[5] = '11.42'; // 最低
      f[8] = '65173875';
      f[9] = '752536297.040';
      f[30] = '2026-11-03';
      f[31] = '10:04:54';
      final String line = 'var hq_str_sz000001="${f.join(',')}";';
      final List<Quote> quotes = const SinaSource().parseBatchQuotes(
        _b(line),
        stocks: <StockConfig>[kPingAn],
      );
      expect(quotes, isEmpty);
    });

    test('A 股与港股混批：各走各的解析分支', () {
      final List<Quote> quotes = const SinaSource().parseBatchQuotes(
        _b('$_sinaHkLine\n'
            'var hq_str_sz000001="XX,11.560,11.540,11.490,11.700,11.420,'
            '11.470,11.480,65173875,752536297.040,0,0,0,0,0,0,0,0,0,0,0,0,'
            '0,0,0,0,0,0,0,0,2026-11-03,10:04:54,00";\n'),
        stocks: <StockConfig>[kTencent, kPingAn],
      );
      expect(quotes, hasLength(2));
      final Map<String, Quote> byKey = <String, Quote>{
        for (final Quote q in quotes) '${q.code}@${q.region}': q,
      };
      expect(byKey['00700@HK'], isNotNull);
      expect(byKey['000001@SZ']!.price, 11.490);
      expect(byKey['000001@SZ']!.volume, 65173875); // A 股新浪本来就是股
    });
  });

  group('港股 K 线', () {
    test('新浪 K 线不支持港股，腾讯支持', () {
      expect(const SinaKline().supports(kTencent), isFalse);
      expect(const SinaKline().supports(kMaotai), isTrue);
      expect(const TencentKline().supports(kTencent), isTrue);
    });

    test('腾讯港股日线：走 day 键、量是股（不 ×100）', () {
      // 真网截取（00700 最近 2 根）
      const String body =
          '{"code":0,"msg":"","data":{"hk00700":{"day":'
          '[["2026-10-30","376.400","383.600","387.600","375.200","22269954.000"],'
          '["2026-11-03","393.200","396.000","402.600","391.800","14103693.0"]],'
          '"qt":{}}}}';
      final List<Kline> ks =
          const TencentKline().parseDaily(_b(body), kTencent);
      expect(ks, hasLength(2));
      expect(ks.last.close, 396.000);
      expect(ks.last.volume, 14103693); // 不能 ×100
      expect(ks.last.time, DateTime(2026, 11, 3));
    });

    test('腾讯 A 股日线：量仍是手 ×100', () {
      const String body =
          '{"code":0,"data":{"sh600519":{"qfqday":'
          '[["2026-11-03","1450.00","1451.01","1458.00","1435.10","25327"]]}}}';
      final List<Kline> ks = const TencentKline().parseDaily(_b(body), kMaotai);
      expect(ks.single.volume, 2532700);
    });

    test('腾讯港股分时：累计量是股（不 ×100），均价 = 额 ÷ 量', () {
      // 真网截取（09:30 首根：量 745409 股、额 293123825 → 393.2 = 开盘价）
      const String body =
          '{"code":0,"data":{"hk00700":{"data":{"data":'
          '["0930 393.200 745409 293123825.400",'
          '"0931 394.400 1151996 452944619.800"],'
          '"date":"20261103"}}}}';
      final List<IntradayPoint> pts =
          const TencentKline().parseIntraday(_b(body), kTencent);
      expect(pts, hasLength(2));
      expect(pts.first.volume, 745409); // 首根增量就是全量，不能 ×100
      expect(pts.first.avgPrice, closeTo(393.2, 0.1));
      expect(pts.last.volume, 1151996 - 745409); // 差分后的增量
    });
  });

  group('KlineLoader 对港股跳过新浪', () {
    test('不发新浪请求，直接用腾讯', () async {
      final List<String> hosts = <String>[];
      final KlineLoader loader = KlineLoader(
        httpGet: (Uri uri, Map<String, String> headers) async {
          hosts.add(uri.host);
          return HttpRawResponse(
            statusCode: 200,
            body: _b(
              '{"code":0,"data":{"hk00700":{"day":'
              '[["2026-11-03","393.200","396.000","402.600","391.800","14103693.0"]],'
              '"qt":{}}}}',
            ),
          );
        },
      );
      final KlineResult<Kline> r = await loader.loadDaily(kTencent);
      expect(r.sourceId, 'tencent');
      expect(r.items, hasLength(1));
      expect(hosts, everyElement('web.ifzq.gtimg.cn'),
          reason: '新浪对港股 K 线只会返回 null，不该浪费这次请求');
    });
  });

  group('搜索（东财）对港股', () {
    StockConfig? oneOf(String body) =>
        const EastmoneySuggest().parse(utf8.encode(body)).firstOrNull;

    test('正股收入（含二次上市 -W）', () {
      expect(
        oneOf(
          '{"QuotationCodeTable":{"Data":['
          '{"Code":"00700","Name":"腾讯控股","MarketType":"5","SecurityTypeName":"港股"},'
          '{"Code":"09988","Name":"阿里巴巴-W","MarketType":"5","SecurityTypeName":"港股"}]}}',
        )?.region,
        'HK',
      );
    });

    test('人民币柜台（8 开头）与轮证（名称含 购/沽/牛/熊）挡掉', () {
      const String body =
          '{"QuotationCodeTable":{"Data":['
          '{"Code":"80700","Name":"腾讯控股-R","MarketType":"5","SecurityTypeName":"港股"},'
          '{"Code":"13005","Name":"腾讯法兴七三购A","MarketType":"5","SecurityTypeName":"港股"},'
          '{"Code":"13040","Name":"腾讯摩通六乙沽B","MarketType":"5","SecurityTypeName":"港股"}'
          ']}}';
      expect(const EastmoneySuggest().parse(utf8.encode(body)), isEmpty);
    });

    test('搜「00700」命中的是港股腾讯，不是深市模塑科技', () {
      // 真网截取：input=00700 时两类都在结果里，region 判据必须分开
      final List<StockConfig> out = const EastmoneySuggest().parse(utf8.encode(
        '{"QuotationCodeTable":{"Data":['
        '{"Code":"00700","Name":"腾讯控股","MarketType":"5","SecurityTypeName":"港股"},'
        '{"Code":"000700","Name":"模塑科技","MarketType":"2","SecurityTypeName":"深A"}'
        ']}}',
      ));
      expect(out, hasLength(2));
      expect(
        out.where((StockConfig s) => s.code == '00700').single.region,
        'HK',
      );
      expect(
        out.where((StockConfig s) => s.code == '000700').single.region,
        'SZ',
      );
    });
  });

  group('代码推断与存档', () {
    test('5 位纯数字是港股', () {
      expect(WatchlistRepository.regionForCode('00700'), 'HK');
      expect(WatchlistRepository.isValidCode('00700'), isTrue);
      // 6 位规则不变
      expect(WatchlistRepository.regionForCode('600519'), 'SH');
      expect(WatchlistRepository.regionForCode('000001'), 'SZ');
    });

    test('存档解码接受 HK 条目', () {
      final List<StockConfig> stocks = WatchlistRepository.decode(
        '[{"c":"00700","n":"腾讯控股","r":"HK"}]',
      );
      expect(stocks, hasLength(1));
      expect(stocks.single.region, 'HK');
    });
  });

  group('港股交易时段', () {
    DateTime d(int hour, int minute) => DateTime(2026, 11, 2, hour, minute);

    test('09:30–12:00 交易、12:00–13:00 午休、13:00–16:10 交易', () {
      expect(MarketSession.ofHk(d(9, 29)), MarketSession.preOpen);
      expect(MarketSession.ofHk(d(9, 30)), MarketSession.trading);
      expect(MarketSession.ofHk(d(11, 59)), MarketSession.trading);
      expect(MarketSession.ofHk(d(12, 0)), MarketSession.lunchBreak);
      expect(MarketSession.ofHk(d(12, 59)), MarketSession.lunchBreak);
      expect(MarketSession.ofHk(d(13, 0)), MarketSession.trading);
      expect(MarketSession.ofHk(d(16, 9)), MarketSession.trading,
          reason: '16:00–16:10 收市竞价，价格仍会动');
      expect(MarketSession.ofHk(d(16, 10)), MarketSession.closed);
    });

    test('周末休市；A 股口径不受影响', () {
      expect(
        MarketSession.ofHk(DateTime(2026, 11, 7, 10, 0)), // 周六
        MarketSession.weekend,
      );
      // A 股 15:00 收盘、港股 16:10——同一时刻两个答案
      expect(MarketSession.of(d(15, 30)), MarketSession.closed);
      expect(MarketSession.ofHk(d(15, 30)), MarketSession.trading);
    });
  });

  group('分时轴（港股 330 分钟）', () {
    DateTime t(int hour, int minute) => DateTime(2026, 11, 2, hour, minute);

    test('港股：09:30–12:00 + 13:00–16:00，午休不占宽', () {
      expect(tradingMinute(t(9, 30), hk: true), 0);
      expect(tradingMinute(t(11, 59), hk: true), 149);
      expect(tradingMinute(t(12, 0), hk: true), 150);
      expect(tradingMinute(t(12, 30), hk: true), 150, reason: '午休夹在上午收盘');
      expect(tradingMinute(t(13, 0), hk: true), 150);
      expect(tradingMinute(t(16, 0), hk: true), 330);
      expect(tradingMinute(t(16, 30), hk: true), 330);
    });

    test('A 股行为不变：240 分钟', () {
      expect(tradingMinute(t(11, 30)), 120);
      expect(tradingMinute(t(13, 0)), 120);
      expect(tradingMinute(t(15, 0)), 240);
      expect(tradingMinutesOf(hk: false), 240);
      expect(tradingMinutesOf(hk: true), 330);
    });
  });
}
