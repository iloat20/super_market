// 美股链路解析测试（fixture 全部来自 2026-11-05 真网探针，见
// tool/us_live_probe_test.dart）。
//
// 覆盖四段：
// 1. 新浪 `gb_` 报价：字段表 / 混批 / 脏数据守卫；
// 2. 腾讯美股写法：交易所后缀映射（NASDAQ→.OQ、NYSE→.N）；
// 3. 腾讯美股 K 线：`day` 键、量是**股**（A 股是手，误 ×100 是港股接入时
//    踩过的同一个坑）；
// 4. 存档：exchange 字段往返 + 旧存档（无 e 键）兼容。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/kline.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/services/source/sina_kline.dart';
import 'package:super_market/services/source/sina_source.dart';
import 'package:super_market/services/source/tencent_kline.dart';
import 'package:super_market/services/source/tencent_source.dart';
import 'package:super_market/services/watchlist_repository.dart';

const StockConfig aapl = StockConfig(
  code: 'AAPL',
  name: '苹果',
  region: 'US',
  exchange: 'NASDAQ',
);
const StockConfig baba = StockConfig(
  code: 'BABA',
  name: '阿里巴巴',
  region: 'US',
  exchange: 'NYSE',
);
const StockConfig geely = StockConfig(code: '000651', name: '格力电器', region: 'SZ');

/// 2026-11-05 18:16 实测 `hq.sinajs.cn/list=gb_aapl`（中文名在 GBK 线上，
/// fixture 里用 utf8 写、解析器不读名称，数字与逗号不受影响）。
const String _aaplBody =
    '苹果,349.5100,5.31,2026-11-05 18:16:10,17.6100,341.5650,354.5000,'
    '340.9900,351.7300,242.8900,89637676,53285985,5079142931169,8.30,'
    '42.110000,0.00,0.00,0.00,0.00,14532182001,63,350.5000,0.28,0.99,'
    'Nov 05 05:16AM EST,Nov 04 04:00PM EST,331.9000,204794,1,2026,'
    '31441204724.8845,351.5725,348.8300,71775350.3572,349.3722,349.5100';

String _sinaLine(String symbol, String body) =>
    'var hq_str_$symbol="$body";\n';

List<int> _bytes(String text) => utf8.encode(text);

List<Quote> _parseSina(String text, List<StockConfig> stocks) =>
    const SinaSource().parseBatchQuotes(_bytes(text), stocks: stocks);

void main() {
  group('新浪美股报价（gb_ 前缀）', () {
    test('wireSymbol：US → gb_ + 小写代码', () {
      expect(SinaSource.wireSymbol(aapl), 'gb_aapl');
      expect(SinaSource.wireSymbol(baba), 'gb_baba');
      // 既有写法不受影响
      expect(
        SinaSource.wireSymbol(geely),
        'sz000651',
      );
    });

    test('字段表：价/额/幅/开高低/量股/额USD/昨收/北京时间戳', () {
      final List<Quote> got = _parseSina(
        _sinaLine('gb_aapl', _aaplBody),
        <StockConfig>[aapl],
      );
      expect(got, hasLength(1));
      final Quote q = got.single;
      expect(q.code, 'AAPL');
      expect(q.region, 'US');
      expect(q.price, 349.51);
      expect(q.change, 17.61, reason: '涨跌额是现成字段 [4]，不用回算');
      expect(q.changePercent, 5.31, reason: '涨跌幅是现成字段 [2]');
      expect(q.open, closeTo(341.565, 1e-6), reason: '[5] 今开');
      expect(q.high, 354.50, reason: '[6] 最高');
      expect(q.low, 340.99, reason: '[7] 最低');
      expect(q.volume, 89637676, reason: '[10] 成交量，单位股，不换算');
      expect(q.turnover, closeTo(31441204724.88, 0.01), reason: '[30] 成交额 USD');
      expect(q.previousClose, 331.90, reason: '[26] 昨收（不在 [5]，[5] 是今开）');
      expect(
        q.timestamp,
        DateTime(2026, 11, 5, 18, 16, 10),
        reason: '[3] 时间戳是北京时间，与 A/H 同一坐标',
      );
      expect(q.tradingStatus, TradingStatus.normal);
      expect(q.source, QuoteSource.socket);
      expect(q.hasData, isTrue);
    });

    test('单位自洽：额 ÷ 量 ≈ 现价（换算错不报错，用比值当判据）', () {
      final Quote q = _parseSina(
        _sinaLine('gb_aapl', _aaplBody),
        <StockConfig>[aapl],
      ).single;
      expect(q.turnover / q.volume, closeTo(q.price, q.price * 0.05));
    });

    test('混批：A 股 + 美股一发全回（轮询架构不变的前提）', () {
      // A 股行：真报文截取（2026-11-05 实测 sz000651），五档盘口用 0 填充
      final String aShareBody =
          '格力电器,38.900,38.960,38.700,39.190,38.130,38.690,38.700,'
          '50744912,1955186789.840,'
          '${List<String>.filled(20, '0').join(',')}'
          ',2026-11-05,15:35:45,00';
      final List<Quote> got = _parseSina(
        '${_sinaLine('sz000651', aShareBody)}'
        '${_sinaLine('gb_aapl', _aaplBody)}',
        <StockConfig>[geely, aapl],
      );
      final Set<String> keys = <String>{
        for (final Quote q in got) '${q.code}@${q.region}',
      };
      expect(keys, containsAll(<String>['000651@SZ', 'AAPL@US']));
    });

    test('代码不存在（gb_brk_b 实测）：空串行跳过，不抛', () {
      final List<Quote> got = _parseSina(
        _sinaLine('gb_brk_b', ''),
        <StockConfig>[baba],
      );
      expect(got, isEmpty);
    });

    test('0 价（退市/停牌）不产出：不能覆盖卡上已有行情', () {
      final List<String> f = _aaplBody.split(',');
      f[1] = '0.0000';
      final List<Quote> got = _parseSina(
        _sinaLine('gb_aapl', f.join(',')),
        <StockConfig>[aapl],
      );
      expect(got, isEmpty);
    });

    test('字段不足 31（报文结构变了）整行跳过', () {
      final List<String> f = _aaplBody.split(',').sublist(0, 30);
      final List<Quote> got = _parseSina(
        _sinaLine('gb_aapl', f.join(',')),
        <StockConfig>[aapl],
      );
      expect(got, isEmpty);
    });

    test('时间戳脏数据（解析不出）跳过', () {
      final List<String> f = _aaplBody.split(',');
      f[3] = 'not-a-date';
      final List<Quote> got = _parseSina(
        _sinaLine('gb_aapl', f.join(',')),
        <StockConfig>[aapl],
      );
      expect(got, isEmpty);
    });

    test('markets 含 US：存档白名单并集由轮询链推导，必须把 US 带进来', () {
      expect(const SinaSource().markets, contains('US'));
    });
  });

  group('腾讯美股写法（交易所后缀）', () {
    test('NASDAQ → .OQ，NYSE → .N（2026-11-05 实测 usAAPL.OQ / usBABA.N）', () {
      expect(TencentSource.wireSymbol(aapl), 'usAAPL.OQ');
      expect(TencentSource.wireSymbol(baba), 'usBABA.N');
    });

    test('exchange 缺失按 NASDAQ 兜底（搜索侧已保证非空，这只是测试兜底）', () {
      const StockConfig noExchange = StockConfig(
        code: 'AAPL',
        name: '苹果',
        region: 'US',
      );
      expect(TencentSource.wireSymbol(noExchange), 'usAAPL.OQ');
    });

    test('腾讯不支持美股报价（qt.gtimg 实测 v_pv_none_match）：markets 不含 US', () {
      expect(const TencentSource().markets, isNot(contains('US')));
    });
  });

  group('腾讯美股日 K（web.ifzq.gtimg.cn）', () {
    const TencentKline source = TencentKline();

    // 2026-11-05 实测 fqkline/get?param=usAAPL.OQ,day,,,3,qfq（截取）
    const String usDaily =
        '{"code":0,"msg":"","data":{"usAAPL.OQ":{"day":['
        '["2026-10-31","343.920","343.910","347.090","341.030","42743575.000"],'
        '["2026-11-03","325.580","331.900","334.500","325.330","63160026.000"],'
        '["2026-11-04","341.570","349.510","354.500","340.990","89637749.000"]],'
        '"qt":{},"prec":"343.990","version":"16"}}}';

    test('`day` 键（美股无复权概念，与指数同形状）+ 量是股不 ×100', () {
      final List<Kline> bars = source.parseDaily(_bytes(usDaily), aapl);
      expect(bars, hasLength(3));
      final Kline last = bars.last;
      expect(last.time, DateTime(2026, 11, 4));
      expect(last.open, 341.57);
      expect(last.close, 349.51);
      expect(last.high, 354.50);
      expect(last.low, 340.99);
      expect(last.volume, 89637749, reason: '美股量本来就是股，×100 就错了 100 倍');
    });

    test('wireSymbol 后缀与日 K 地址一致', () {
      final Uri uri = source.dailyUri(aapl, 80);
      expect(uri.host, 'web.ifzq.gtimg.cn');
      expect(
        uri.queryParameters['param'],
        'usAAPL.OQ,day,,,80,qfq',
        reason: 'param 是位置式参数，逗号是语法的一部分',
      );
    });

    test('新浪 K 线不支持美股（data:null 实测）：loader 直接跳过', () {
      expect(const SinaKline().supports(aapl), isFalse);
      expect(const SinaKline().supports(geely), isTrue);
      // 港股行为不变
      expect(
        const SinaKline().supports(
          const StockConfig(code: '01378', name: '中国宏桥', region: 'HK'),
        ),
        isFalse,
      );
    });
  });

  group('订阅存档：exchange 字段', () {
    test('encode/decode 往返：US 条目带交易所', () {
      const List<StockConfig> stocks = <StockConfig>[aapl, baba, geely];
      final List<StockConfig> got = WatchlistRepository.decode(
        WatchlistRepository.encode(stocks),
      );
      expect(got[0].key, 'AAPL@US');
      expect(got[0].exchange, 'NASDAQ');
      expect(got[1].exchange, 'NYSE');
      expect(got[2].exchange, '', reason: 'A 股没有交易所字段');
    });

    test('旧存档（无 e 键）兼容：A/H 条目原样读回', () {
      const String legacy =
          '[{"c":"000651","n":"格力电器","r":"SZ"},'
          '{"c":"01378","n":"中国宏桥","r":"HK"}]';
      final List<StockConfig> got = WatchlistRepository.decode(legacy);
      expect(got, hasLength(2));
      expect(got[0].region, 'SZ');
      expect(got[0].exchange, '');
      expect(got[1].region, 'HK');
    });

    test('US 条目缺 exchange / 交易所不合法：丢弃并留日志（去了也出不了数）', () {
      const String bad =
          '[{"c":"AAPL","n":"苹果","r":"US"},'
          '{"c":"TSLP","n":"某AMEX票","r":"US","e":"AMEX"},'
          '{"c":"BABA","n":"阿里巴巴","r":"US","e":"NYSE"}]';
      final List<StockConfig> got = WatchlistRepository.decode(bad);
      expect(got.map((StockConfig s) => s.code), <String>['BABA']);
    });

    test('US 代码形状：1–5 位大写字母；小写/数字/带点不放行', () {
      expect(WatchlistRepository.isValidCode('AAPL'), isTrue);
      expect(WatchlistRepository.isValidCode('A'), isTrue);
      expect(WatchlistRepository.isValidCode('aapl'), isFalse);
      expect(WatchlistRepository.isValidCode('BRK_B'), isFalse);
      expect(WatchlistRepository.isValidCode('BRK.B'), isFalse);
      // 既有形状不受影响
      expect(WatchlistRepository.isValidCode('000651'), isTrue);
      expect(WatchlistRepository.isValidCode('01378'), isTrue);
      expect(WatchlistRepository.isValidCode('1234567'), isFalse);
    });

    test('手输代码兜底不支持美股：字母代码推断不出交易所', () {
      expect(WatchlistRepository.regionForCode('AAPL'), isNull);
      expect(WatchlistRepository.regionForCode('000651'), 'SZ');
    });
  });
}
