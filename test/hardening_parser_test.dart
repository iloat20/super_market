import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/kline.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/services/source/eastmoney_us_source.dart';
import 'package:super_market/services/source/sina_kline.dart';
import 'package:super_market/services/source/sina_source.dart';
import 'package:super_market/services/source/tencent_kline.dart';
import 'package:super_market/services/source/tencent_source.dart';
import 'package:super_market/services/watchlist_repository.dart';

/// 审查台账（2026-11-08）批次 B：异常输入 / 数值溢出 / 代码映射 / 状态语义。
const StockConfig kAapl =
    StockConfig(code: 'AAPL', name: 'Apple', region: 'US', exchange: 'NASDAQ');
const StockConfig kMsft = StockConfig(
  code: 'MSFT',
  name: 'Microsoft',
  region: 'US',
  exchange: 'NASDAQ',
);
const StockConfig kBabaNyse =
    StockConfig(code: 'BABA', name: 'Alibaba', region: 'US', exchange: 'nyse');
const StockConfig kBabaUnknown =
    StockConfig(code: 'BABA', name: 'Alibaba', region: 'US', exchange: 'AMEX');
const StockConfig kPingAn =
    StockConfig(code: '000001', name: 'PINGAN', region: 'SZ');
const StockConfig kMaotai =
    StockConfig(code: '600519', name: 'MAOTAI', region: 'SH');

String sinaA(String code, String region, {double price = 11.49}) {
  final List<String> f = <String>[
    'NAME', '11.560', '11.540', '$price', '11.700', '11.420', '11.470',
    '11.480', '65173875', '752536297.040',
    ...List<String>.filled(20, '0'),
    '2026-11-03', '10:04:54', '00',
  ];
  return 'var hq_str_${region.toLowerCase()}$code="${f.join(',')}";';
}

String tencentA(String code, String region) {
  final List<String> f = <String>[
    '51', 'NAME', code, '11.48', '11.54', '11.56', '651667', '0', '0',
    ...List<String>.filled(20, '0'),
    '',
    '20261103100451', '-0.06', '-0.52', '11.70', '11.42', 'x', '651667',
    '75245',
  ];
  return 'v_${region.toLowerCase()}$code="${f.join('~')}";';
}

Map<String, Object?> emRow(String code, {Object? f124 = 1793998800}) =>
    <String, Object?>{
      'f2': 342.37,
      'f3': -0.52,
      'f4': -1.8,
      'f5': 44703806,
      'f6': 15323860736.0,
      'f12': code,
      'f13': 105,
      'f15': 345.79,
      'f16': 338.3,
      'f17': 338.73,
      'f18': 344.17,
      'f124': f124,
    };

String eastmoneyBody(List<Map<String, Object?>> diff) =>
    jsonEncode(<String, Object?>{
      'rc': 0,
      'data': <String, Object?>{'total': diff.length, 'diff': diff},
    });

String tencentIntraday(String date, List<String> rows) =>
    jsonEncode(<String, Object?>{
      'code': 0,
      'data': <String, Object?>{
        'usAAPL.OQ': <String, Object?>{
          'data': <String, Object?>{'date': date, 'data': rows},
        },
      },
    });

String sinaIntraday(List<Map<String, Object?>> rows) =>
    jsonEncode(<String, Object?>{
      'result': <String, Object?>{'data': rows},
    });

void main() {
  group('批次 B｜异常输入与数值溢出', () {
    test('#5 f124 极端值不得抛 Error 拖垮整批', () {
      final String body = eastmoneyBody(<Map<String, Object?>>[
        emRow('AAPL', f124: '1e308'),
        emRow('MSFT'),
      ]);
      List<Quote> out = const <Quote>[];
      Object? thrown;
      try {
        out = const EastmoneyUsSource().parseBatchQuotes(
          utf8.encode(body),
          stocks: <StockConfig>[kAapl, kMsft],
        );
      } on Object catch (e) {
        thrown = e;
      }
      expect(thrown, isNull,
          reason: 'Infinity.round() 抛 UnsupportedError，parseBatchQuotes 只拦 FormatException');
      expect(out.map((Quote q) => q.code).toList(), <String>['MSFT'],
          reason: '脏时间戳只丢该行，同批正常行必须照常返回');
    });

    test('#12 新浪派生涨跌幅溢出为 Infinity 时整行丢弃', () {
      final String body =
          '${sinaA('000001', 'SZ', price: 1e308)}\n${sinaA('600519', 'SH')}';
      final List<Quote> out = const SinaSource().parseBatchQuotes(
        latin1.encode(body),
        stocks: <StockConfig>[kPingAn, kMaotai],
      );
      expect(out.map((Quote q) => q.code).toList(), <String>['600519']);
    });

    test('#12b 东财派生涨跌幅同样必须有限', () {
      final String body = eastmoneyBody(<Map<String, Object?>>[
        <String, Object?>{
          'f2': 1e308,
          'f18': 11.54,
          'f12': 'AAPL',
          'f124': 1793998800,
        },
      ]);
      final List<Quote> out = const EastmoneyUsSource().parseBatchQuotes(
        utf8.encode(body),
        stocks: <StockConfig>[kAapl],
      );
      expect(out, isEmpty,
          reason: 'change / prevClose * 100 溢出成 Infinity，不该写进 Quote');
    });

    test('#13a 腾讯分时越界日期不得被 DateTime 归一化进错误年份', () {
      final String body = tencentIntraday(
        '20261345',
        <String>['0930 1450.00 1650 239250000.00'],
      );
      final List<IntradayPoint> out = const TencentKline().parseIntraday(
        utf8.encode(body),
        kAapl,
      );
      expect(out, isEmpty,
          reason: '13 月 45 日会被归一化成 2027-02-14，整批时间轴都错了');
    });

    test('#13b 腾讯分时负时钟不得归一化成前一晚', () {
      final String body = tencentIntraday('20261103', <String>[
        '-130 1450.00 1650 239250000.00',
        '0931 1451.00 1700 239250000.00',
      ]);
      final List<IntradayPoint> out = const TencentKline().parseIntraday(
        utf8.encode(body),
        kAapl,
      );
      expect(out.length, 1);
      expect(out.single.time.hour, 9);
    });

    test('#14d 新浪分时负成交量不得流入模型', () {
      final String body = sinaIntraday(<Map<String, Object?>>[
        <String, Object?>{
          'day': '2026-11-03 10:40:00',
          'close': '11.49',
          'volume': '-5000',
          'amount': '57450',
        },
        <String, Object?>{
          'day': '2026-11-03 10:41:00',
          'close': '11.50',
          'volume': '1000',
          'amount': '11500',
        },
      ]);
      final List<IntradayPoint> out = const SinaKline().parseIntraday(
        utf8.encode(body),
        kPingAn,
      );
      expect(out, isNotEmpty);
      expect(out.every((IntradayPoint p) => p.volume >= 0), isTrue);
    });
  });

  group('批次 B｜代码映射与状态语义', () {
    test('#14a 美股交易所大小写规范化，未知值不静默按 NASDAQ', () {
      expect(EastmoneyUsSource.secidOf(kBabaNyse), '106.BABA');
      expect(TencentSource.wireSymbol(kBabaNyse), 'usBABA.N');
      expect(EastmoneyUsSource.secidOf(kBabaUnknown),
          isNot(startsWith('105.')));
      expect(EastmoneyUsSource.secidOf(kBabaUnknown),
          isNot(startsWith('106.')));
      expect(TencentSource.wireSymbol(kBabaUnknown), isNot(contains('.OQ')));
      expect(TencentSource.wireSymbol(kBabaUnknown), isNot(contains('.N')));
    });

    test('#14b 5 位字母代码不得混进港股', () {
      expect(
        WatchlistRepository.decode('[{"c":"ABCDE","r":"HK","n":"X"}]'),
        isEmpty,
      );
    });

    test('#14c 不提供交易状态的源不得谎报 normal', () {
      final List<Quote> out = const TencentSource().parseBatchQuotes(
        latin1.encode(tencentA('600519', 'SH')),
        stocks: <StockConfig>[kMaotai],
      );
      expect(out, isNotEmpty);
      expect(out.single.tradingStatus, TradingStatus.unknown);
    });

    test('#14c2 源不给状态时不得抹掉已知的停牌状态', () {
      final Quote current = Quote(
        code: '600519',
        region: 'SH',
        price: 11.48,
        change: 0,
        changePercent: 0,
        timestamp: DateTime(2026, 11, 3, 10, 0),
        tradingStatus: TradingStatus.suspended,
      );
      final Quote incoming = Quote(
        code: '600519',
        region: 'SH',
        price: 11.49,
        change: 0.01,
        changePercent: 0.1,
        timestamp: DateTime(2026, 11, 3, 10, 1),
        tradingStatus: TradingStatus.unknown,
      );
      expect(shouldApplyQuote(current, incoming), isFalse,
          reason: '切到不提供状态的源时，停牌角标不该凭空消失');
    });
  });
}
