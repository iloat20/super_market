import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/services/source/sina_source.dart';

/// 审查台账 R-12 的回归测试（R-04/R-05 的解析层随 iTick 通道退役，
/// 数值安全由 UI 层 shouldApplyQuote 的 isFinite 闸门继续守护）。
///
/// 缺陷背景（2026-11-04 审查）：
/// - R-04：`QuoteParser._asInt` 对 `num` 直接 `toInt()`，`1e999` 经
///   `jsonDecode` 变成 `double.infinity`，`Infinity.toInt()` 抛
///   `UnsupportedError`（Error 而非 Exception）。
/// - R-05：`QuoteParser._asDouble` 不过滤 NaN / Infinity，敌意帧可以把
///   `Infinity` 价格一路送进 UI 与图表 painter（NaN 坐标）。
/// - R-12：新浪港股 `_parseHkDateTime` 对年份无位数/范围限制，单行脏数据
///   抛出的异常会拖垮 `parseBatchQuotes` 整批。
///
/// 原始缺陷下这三个测试都是红的；修复后必须全绿。
const StockConfig kTencent =
    StockConfig(code: '00700', name: '腾讯控股', region: 'HK');
const StockConfig kPingAn =
    StockConfig(code: '000001', name: '平安银行', region: 'SZ');
const StockConfig kMaotai =
    StockConfig(code: '600519', name: '贵州茅台', region: 'SH');

/// 新浪 A 股 33 字段行（与 polling_feed_test 的 fixture 同构，ASCII 名称）
String sinaA(String code, String region, {double price = 11.49}) {
  final List<String> f = <String>[
    'NAME', '11.560', '11.540', '$price', '11.700', '11.420', '11.470',
    '11.480', '65173875', '752536297.040',
    ...List<String>.filled(20, '0'), // 10..29 五档
    '2026-11-03', '10:04:54', '00',
  ];
  return 'var hq_str_${region.toLowerCase()}$code="${f.join(',')}";';
}

/// 新浪港股行（真网截取的日期字段被替换为畸形超长年份）
const String badHkLine =
    'var hq_str_rt_hk00700="TENCENT,XX,393.200,392.200,402.600,391.800,'
    '397.000,4.800,1.224,396.800,397.000,6139652907.100,15425176,14.429,'
    '0.000,654.376,375.200,999999999999/01/01,14:30:19,30|3,N|Y|Y,'
    '0.000|0.000|0.000,0|||0.000|0.000|0.000, |0,Y";';

void main() {

  group('新浪港股日期健壮性（R-12）', () {
    test('畸形年份只丢该行，不拖垮整批、不抛异常', () {
      final List<Quote> quotes = const SinaSource().parseBatchQuotes(
        latin1.encode('$badHkLine\n${sinaA('000001', 'SZ')}'),
        stocks: const <StockConfig>[kTencent, kPingAn],
      );
      expect(quotes.map((Quote q) => q.code).toList(), <String>['000001'],
          reason: '脏时间戳的 HK 行只丢自己，同批 A 股行必须照常返回');
    });

    test('超界但位数正常的年份同样被拒（2026 正常）', () {
      final String outOfRange = badHkLine.replaceFirst(
        '999999999999/01/01',
        '99999/01/01',
      );
      final List<Quote> quotes = const SinaSource().parseBatchQuotes(
        latin1.encode('$outOfRange\n${sinaA('600519', 'SH')}'),
        stocks: const <StockConfig>[kTencent, kMaotai],
      );
      expect(quotes.map((Quote q) => q.code).toList(), <String>['600519']);
    });
  });
}
