import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/services/source/eastmoney_suggest.dart';

/// 真实报文形状（2026-11-03 实测 `searchapi.eastmoney.com/api/suggest/get`）。
///
/// 只保留本项目的解析路径会用到的字段，其余（PinYin / ID / JYS / MktNum …）
/// 原样省略——**如果真的少传了关键字段，解析会失败，用例会红**，
/// 这正是想要的保护。
String _row(
  String code,
  String name, {
  required String marketType,
  String classify = 'AStock',
  String typeName = '沪A',
}) =>
    '{"Code":"$code","Name":"$name","PinYin":"PY","ID":"${code}1",'
        '"JYS":"2","Classify":"$classify","MarketType":"$marketType",'
        '"SecurityTypeName":"$typeName"}';

/// 美股行（2026-11-05 实测：AAPL=TypeUS 1/NASDAQ，BABA=TypeUS 3/NYSE，
/// ETF=TypeUS 5，BRK_B 的 Code 带下划线）。
String _usRow(
  String code,
  String name, {
  required String typeUs,
  required String jys,
}) =>
    '{"Code":"$code","Name":"$name","PinYin":"PY","ID":"${code}7",'
        '"JYS":"$jys","Classify":"UsStock","MarketType":"7",'
        '"SecurityTypeName":"美股","SecurityType":"7","MktNum":"105",'
        '"TypeUS":"$typeUs","QuoteID":"105.$code"}';

String _body(List<String> rows) =>
    '{"QuotationCodeTable":{"Data":[${rows.join(',')}],"Status":0,'
    '"Message":"","TotalCount":${rows.length}}}';

List<int> _bytes(String s) => utf8.encode(s);

List<String> _labels(List<StockConfig> items) =>
    items.map((StockConfig s) => '${s.name}(${s.region}${s.code})').toList();

void main() {
  const EastmoneySuggest suggest = EastmoneySuggest();

  group('东财搜索建议：解析', () {
    test('单条 A 股：抬出代码、名称、市场', () {
      final List<StockConfig> got = suggest.parse(
        _bytes(_body(<String>[_row('600519', '贵州茅台', marketType: '1')])),
      );
      expect(got.length, 1);
      expect(got.single.code, '600519');
      expect(got.single.name, '贵州茅台');
      expect(got.single.region, 'SH');
      expect(got.single.key, '600519@SH');
    });

    test('多条结果保持服务端顺序（它按相似度排过）', () {
      final List<StockConfig> got = suggest.parse(
        _bytes(
          _body(<String>[
            _row('600000', '浦发银行', marketType: '1'),
            _row('600015', '华夏银行', marketType: '1'),
            _row('000001', '平安银行', marketType: '2', typeName: '深A'),
          ]),
        ),
      );
      expect(_labels(got), <String>[
        '浦发银行(SH600000)',
        '华夏银行(SH600015)',
        '平安银行(SZ000001)',
      ]);
    });

    test('科创板要留下：它的 Classify 是 23 而不是 AStock', () {
      // 按 Classify == 'AStock' 过滤会把中芯国际这类票整批漏掉。
      // 判据必须是 MarketType（1=沪 2=深）+ 号段，不是 Classify。
      final List<StockConfig> got = suggest.parse(
        _bytes(
          _body(<String>[
            _row('688981', '中芯国际',
                marketType: '1', classify: '23', typeName: '科创板'),
          ]),
        ),
      );
      expect(_labels(got), <String>['中芯国际(SH688981)']);
    });

    test('创业板（300 开头）保留为深市', () {
      final List<StockConfig> got = suggest.parse(
        _bytes(
          _body(<String>[
            _row('300750', '宁德时代', marketType: '2', typeName: '深A'),
          ]),
        ),
      );
      expect(_labels(got), <String>['宁德时代(SZ300750)']);
    });

    test('北交所被滤掉（MarketType=_TB）', () {
      final List<StockConfig> got = suggest.parse(
        _bytes(
          _body(<String>[
            _row('920047', '诺思兰德',
                marketType: '_TB', classify: 'NEEQ', typeName: '京A'),
          ]),
        ),
      );
      expect(got, isEmpty);
    });

    test('北交所这一层单独可测：号段放行时只靠 MarketType 拦', () {
      // 真实的北交所代码是 8/4/9 开头，号段校验本来就会挡——上一条用例
      // 因此有两道防线，测不出「MarketType 过滤」到底在不在。
      // 这条故意用 6 开头，让号段放行，只剩市场字段能拦。
      final List<StockConfig> got = suggest.parse(
        _bytes(
          _body(<String>[
            _row('600000', '某北交所票',
                marketType: '_TB', classify: 'NEEQ', typeName: '京A'),
          ]),
        ),
      );
      expect(got, isEmpty);
    });

    test('B 股被滤掉：市场字段合法，号段不合法', () {
      // 200011 深物业B 的 MarketType 也是 2。只看市场字段会把它当股票，
      // 加进订阅后行情接口对它返回空，界面上三个 `--` 且不报错。
      final List<StockConfig> got = suggest.parse(
        _bytes(
          _body(<String>[
            _row('200011', '深物业B',
                marketType: '2', classify: 'BStock', typeName: '深B'),
            _row('900901', '云赛B股',
                marketType: '1', classify: 'BStock', typeName: '沪B'),
          ]),
        ),
      );
      expect(got, isEmpty);
    });

    test('板块条目被滤掉（BK0475 银行Ⅱ，代码不是 6 位数字）', () {
      final List<StockConfig> got = suggest.parse(
        _bytes(
          _body(<String>[
            _row('BK0475', '银行Ⅱ', marketType: '1', classify: 'BK', typeName: '板块'),
            _row('600000', '浦发银行', marketType: '1'),
          ]),
        ),
      );
      expect(_labels(got), <String>['浦发银行(SH600000)']);
    });

    test('无结果时 Data 是 null', () {
      expect(
        suggest.parse(
          _bytes('{"QuotationCodeTable":{"Data":null,"Status":0}}'),
        ),
        isEmpty,
      );
    });

    test('空响应 / HTML / 结构不对，返回空且不抛', () {
      expect(suggest.parse(<int>[]), isEmpty);
      expect(suggest.parse(_bytes('')), isEmpty);
      expect(suggest.parse(_bytes('<html>502</html>')), isEmpty);
      expect(suggest.parse(_bytes('{"foo":1}')), isEmpty);
      expect(suggest.parse(_bytes('{"QuotationCodeTable":{"Data":{}}}')), isEmpty);
    });

    test('同一条重复出现只保留一份', () {
      final List<StockConfig> got = suggest.parse(
        _bytes(
          _body(<String>[
            _row('600519', '贵州茅台', marketType: '1'),
            _row('600519', '贵州茅台', marketType: '1'),
          ]),
        ),
      );
      expect(got.length, 1);
    });

    test('条数被封顶（服务端给的再多也只留 maxResults）', () {
      final List<StockConfig> got = suggest.parse(
        _bytes(
          _body(<String>[
            for (int i = 0; i < 40; i++)
              _row('60${i.toString().padLeft(4, '0')}', '票$i', marketType: '1'),
          ]),
        ),
      );
      expect(got.length, EastmoneySuggest.maxResults);
    });
  });

  group('东财搜索建议：美股（MarketType=7 / UsStock）', () {
    test('NASDAQ 正股（AAPL）：US 身份 + 交易所 NASDAQ', () {
      final List<StockConfig> got = suggest.parse(
        _bytes(
          _body(<String>[_usRow('AAPL', '苹果', typeUs: '1', jys: 'NASDAQ')]),
        ),
      );
      expect(got.length, 1);
      expect(got.single.code, 'AAPL');
      expect(got.single.name, '苹果');
      expect(got.single.region, 'US');
      expect(got.single.exchange, 'NASDAQ');
      expect(got.single.key, 'AAPL@US');
    });

    test('NYSE 中概 ADR（BABA，TypeUS=3）：放行', () {
      final List<StockConfig> got = suggest.parse(
        _bytes(
          _body(<String>[_usRow('BABA', '阿里巴巴', typeUs: '3', jys: 'NYSE')]),
        ),
      );
      expect(got.single.region, 'US');
      expect(got.single.exchange, 'NYSE');
    });

    test('ETF / 债票据（TypeUS 5/6）不放行：行情源未验证，搜到也出不了数', () {
      final List<StockConfig> got = suggest.parse(
        _bytes(
          _body(<String>[
            _usRow('AAPB', '二倍做多苹果ETF', typeUs: '5', jys: 'NASDAQ'),
            _usRow('AAPL29', 'Apple Inc Notes 2029', typeUs: '6', jys: 'NASDAQ'),
          ]),
        ),
      );
      expect(got, isEmpty);
    });

    test('AMEX 不放行：腾讯后缀（.N?）未实测，宁可搜不到也别搜到没数', () {
      final List<StockConfig> got = suggest.parse(
        _bytes(
          _body(<String>[_usRow('TSLP', '特斯拉收益ETF', typeUs: '5', jys: 'AMEX')]),
        ),
      );
      expect(got, isEmpty);
    });

    test('带下划线的多类股（BRK_B）不放行：新浪 gb_brk_b 实测空串', () {
      final List<StockConfig> got = suggest.parse(
        _bytes(
          _body(<String>[_usRow('BRK_B', '伯克希尔哈撒韦-B', typeUs: '1', jys: 'NYSE')]),
        ),
      );
      expect(got, isEmpty);
    });

    test('代码形状不对（小写 / 超长 / 空）不放行', () {
      final List<StockConfig> got = suggest.parse(
        _bytes(
          _body(<String>[
            _usRow('aapl', '小写', typeUs: '1', jys: 'NASDAQ'),
            _usRow('ABCDEF', '六位', typeUs: '1', jys: 'NASDAQ'),
            _usRow('', '空代码', typeUs: '1', jys: 'NASDAQ'),
          ]),
        ),
      );
      expect(got, isEmpty);
    });

    test('美股与 A 股混排：各自归位', () {
      final List<StockConfig> got = suggest.parse(
        _bytes(
          _body(<String>[
            _row('600519', '贵州茅台', marketType: '1'),
            _usRow('AAPL', '苹果', typeUs: '1', jys: 'NASDAQ'),
          ]),
        ),
      );
      expect(_labels(got), <String>['贵州茅台(SH600519)', '苹果(USAAPL)']);
    });
  });

  group('东财搜索建议：请求', () {
    test('地址带 input / type / count，中文正确编码', () {
      final Uri uri = suggest.suggestUri('贵州茅台');
      expect(uri.host, 'searchapi.eastmoney.com');
      expect(uri.path, '/api/suggest/get');
      expect(uri.queryParameters['input'], '贵州茅台');
      expect(uri.queryParameters['count'], '20');
      expect(uri.toString(), contains('input=%E8%B4%B5%E5%B7%9E'));
    });

    test('请求头带 Referer（照抄网页端约定，实测不带也能用）', () {
      expect(suggest.requestHeaders['Referer'], isNotNull);
      expect(suggest.requestHeaders['User-Agent'], isNotNull);
    });
  });
}
