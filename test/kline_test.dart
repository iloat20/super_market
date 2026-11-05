import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/kline.dart';
import 'package:super_market/services/kline_loader.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/services/source/kline_source.dart';
import 'package:super_market/services/source/sina_kline.dart';
import 'package:super_market/services/source/tencent_kline.dart';

/// 报文全部来自 2026-11-03 10:38–10:45 的真网抓取（只删掉与断言无关的字段）。
///
/// 为什么用真实报文而不是手写理想 JSON：这一层的 bug 全是「真实形状和文档
/// 想的不一样」——腾讯分钟 K 线是 O-C-H-L、指数 key 是 `day`、分时是累计值。
/// 手写 JSON 会把这些坑全部抹平，测试就永远绿。

const StockConfig kMaotai = StockConfig(
  code: '600519',
  name: '贵州茅台',
  region: 'SH',
);

List<int> _b(String s) => utf8.encode(s);

/// 新浪日线：**倒序**给，用来验证解析后按时间升序
const String _sinaDaily = '''
{"result":{"status":{"code":0},"data":[
 {"day":"2026-11-02","open":"1410.000","high":"1447.000","low":"1395.020","close":"1439.100","volume":"8269122","ma_price5":1374.36,"ma_volume5":5261698},
 {"day":"2026-10-30","open":"1363.000","high":"1393.370","low":"1352.980","close":"1392.050","volume":"5992729","ma_price5":1356.536,"ma_volume5":4439857},
 {"day":"2026-10-29","open":"1349.990","high":"1356.000","low":"1330.010","close":"1354.000","volume":"4299231","ma_price5":1345.126,"ma_volume5":4395029}]}}''';

/// 新浪分时：真实情况就是**跨日**的（昨天尾盘 + 今天早盘）
const String _sinaIntraday = '''
{"result":{"status":{"code":0},"data":[
 {"day":"2026-11-02 10:34:00","open":"1432.190","high":"1432.190","low":"1430.920","close":"1431.080","volume":"9300","amount":"13311209.0000"},
 {"day":"2026-11-03 09:30:00","open":"1450.000","high":"1450.000","low":"1450.000","close":"1450.000","volume":"165000","amount":"239250000.00"},
 {"day":"2026-11-03 09:31:00","open":"1450.000","high":"1451.000","low":"1436.000","close":"1436.000","volume":"162000","amount":"233109222.29"}]}}''';

/// 腾讯日线：数组顺序是 [日期, 开, 收, 高, 低, 量(手)]
/// 最后一根是**当日**（11-03），新浪那边是没有的
const String _tencentDaily = '''
{"code":0,"msg":"","data":{"sh600519":{
 "qfqday":[["2026-11-02","1410.000","1439.100","1447.000","1395.020","82691.000"],
           ["2026-11-03","1450.00","1451.01","1458.00","1435.10","25327"]],
 "qt":{},"prec":"1439.10","version":"…"}}}''';

/// 腾讯**指数**：key 是 `day`，不是 `qfqday`
const String _tencentIndex = '''
{"code":0,"msg":"","data":{"sh000001":{
 "day":[["2026-11-02","3614.310","3638.030","3648.130","3594.770","565372836.000"]],
 "qt":{}}}}''';

/// 腾讯分时：`HHmm 价格 累计量(手) 累计额(元)`
const String _tencentIntraday = '''
{"code":0,"msg":"","data":{"sh600519":{
 "data":{"data":["0930 1450.00 1650 239250000.00","0931 1436.00 3270 472359222.29"],
         "date":"20261103"},"qt":{}}}}''';

void main() {
  const SinaKline sina = SinaKline();
  const TencentKline tencent = TencentKline();

  group('新浪日线', () {
    test('字段解析：开高低收按名字取，成交量是股', () {
      final List<Kline> ks = sina.parseDaily(_b(_sinaDaily), kMaotai);
      expect(ks.length, 3);
      final Kline last = ks.last; // 2026-11-02
      expect(last.time, DateTime(2026, 11, 2));
      expect(last.open, 1410.0);
      expect(last.high, 1447.0);
      expect(last.low, 1395.02);
      expect(last.close, 1439.1);
      expect(last.volume, 8269122); // 股，不换算
    });

    test('倒序响应会被排成升序（UI 不该假设服务端顺序）', () {
      final List<Kline> ks = sina.parseDaily(_b(_sinaDaily), kMaotai);
      expect(
        ks.map((Kline k) => k.time).toList(),
        <DateTime>[
          DateTime(2026, 10, 29),
          DateTime(2026, 10, 30),
          DateTime(2026, 11, 2),
        ],
      );
    });

    test('data 为 null / 顶层不是 JSON 都返回空，不抛', () {
      expect(sina.parseDaily(_b('{"result":{"data":null}}'), kMaotai), isEmpty);
      expect(sina.parseDaily(_b('null'), kMaotai), isEmpty);
      expect(sina.parseDaily(_b('<html>502 Bad Gateway</html>'), kMaotai), isEmpty);
      expect(sina.parseDaily(<int>[], kMaotai), isEmpty);
    });

    test('0 价的 bar 被丢弃（停牌/退市不该画成贴底的蜡烛）', () {
      const String body = '''
{"result":{"data":[
 {"day":"2026-11-02","open":"0","high":"0","low":"0","close":"0","volume":"0"},
 {"day":"2026-11-03","open":"10","high":"11","low":"9","close":"10","volume":"100"}]}}''';
      final List<Kline> ks = sina.parseDaily(_b(body), kMaotai);
      expect(ks.length, 1);
      expect(ks.single.time, DateTime(2026, 11, 3));
    });
  });

  group('新浪分时', () {
    test('跨日数据只保留最新一天（否则左半张图是昨天的）', () {
      final List<IntradayPoint> pts = sina.parseIntraday(_b(_sinaIntraday), kMaotai);
      expect(pts.length, 2);
      expect(pts.first.time, DateTime(2026, 11, 3, 9, 30));
      expect(pts.last.time, DateTime(2026, 11, 3, 9, 31));
    });

    test('均价是当日累计额 ÷ 累计量，不是这一分钟的', () {
      final List<IntradayPoint> pts = sina.parseIntraday(_b(_sinaIntraday), kMaotai);
      // 第一分钟：239250000 / 165000 = 1450.0
      expect(pts.first.avgPrice, closeTo(1450.0, 0.001));
      // 第二分钟：累计 (239250000+233109222.29) / (165000+162000)
      expect(
        pts.last.avgPrice,
        closeTo(472359222.29 / 327000, 0.001),
      );
    });

    test('volume 是每分钟增量，直接取用不做差分', () {
      final List<IntradayPoint> pts = sina.parseIntraday(_b(_sinaIntraday), kMaotai);
      expect(pts.first.volume, 165000);
      expect(pts.last.volume, 162000);
    });
  });

  group('腾讯日线', () {
    test('数组是 [日期, 开, 收, 高, 低, 量]，按 OHLC 解析会把开收对调', () {
      final List<Kline> ks = tencent.parseDaily(_b(_tencentDaily), kMaotai);
      expect(ks.length, 2);
      final Kline first = ks.first;
      expect(first.open, 1410.0);
      expect(first.close, 1439.1);
      expect(first.high, 1447.0); // 若按 OHLC 读会得到 1439.1
      expect(first.low, 1395.02); // 若按 OHLC 读会得到 1447.0
    });

    test('成交量 手 → 股（×100）', () {
      final List<Kline> ks = tencent.parseDaily(_b(_tencentDaily), kMaotai);
      expect(ks.first.volume, 8269100); // 82691 手
      expect(ks.last.volume, 2532700); // 25327 手（无小数，也不能当股）
    });

    test('指数用 day 而不是 qfqday 也能解析', () {
      final List<Kline> ks = tencent.parseDaily(_b(_tencentIndex), kMaotai);
      expect(ks.length, 1);
      expect(ks.single.close, 3638.03);
      expect(ks.single.volume, 56537283600);
    });

    test('code 非 0 / 结构不对返回空', () {
      expect(tencent.parseDaily(_b('{"code":1,"msg":"err"}'), kMaotai), isEmpty);
      expect(tencent.parseDaily(_b('{"code":0,"data":{}}'), kMaotai), isEmpty);
      expect(tencent.parseDaily(_b(''), kMaotai), isEmpty);
    });
  });

  group('腾讯分时', () {
    test('累计量差分成分钟增量（不差分会画成一条上升斜线）', () {
      final List<IntradayPoint> pts = tencent.parseIntraday(_b(_tencentIntraday), kMaotai);
      expect(pts.length, 2);
      expect(pts.first.volume, 165000); // 1650 手 × 100
      expect(pts.last.volume, 162000); // (3270-1650) 手 × 100
    });

    test('均价 = 累计额 ÷ 累计量（股）', () {
      final List<IntradayPoint> pts = tencent.parseIntraday(_b(_tencentIntraday), kMaotai);
      expect(pts.first.avgPrice, closeTo(1450.0, 0.001));
      expect(
        pts.last.avgPrice,
        closeTo(472359222.29 / 327000, 0.001),
      );
    });

    test('时间由 date + HHmm 拼出，不是 1970 年', () {
      final List<IntradayPoint> pts = tencent.parseIntraday(_b(_tencentIntraday), kMaotai);
      expect(pts.first.time, DateTime(2026, 11, 3, 9, 30));
    });
  });

  group('KlineLoader：主备切换与缓存', () {
    // 每个用例一张干净的计数表：跨用例复用会让"调用了几次"的断言
    // 变成"加上上一个用例的几次"，而失败信息里完全看不出这一点。
    Map<String, int> calls = <String, int>{};

    setUp(() => calls = <String, int>{});

    KlineLoader loaderWith(List<KlineSource> chain, {DateTime Function()? now}) {
      return KlineLoader(
        chain: chain,
        now: now,
        httpGet: (Uri uri, Map<String, String> headers) async {
          final String host = uri.host;
          calls[host] = (calls[host] ?? 0) + 1;
          if (host == 'quotes.sina.cn') {
            return HttpRawResponse(statusCode: 200, body: _b(_sinaDaily));
          }
          if (host == 'web.ifzq.gtimg.cn') {
            return HttpRawResponse(statusCode: 200, body: _b(_tencentDaily));
          }
          return const HttpRawResponse(statusCode: 404, body: <int>[]);
        },
      );
    }

    test('第一源有数据就用第一源', () async {
      final KlineLoader loader = loaderWith(KlineSources2.both);
      final KlineResult<Kline> r = await loader.loadDaily(kMaotai);
      expect(r.sourceId, 'sina');
      expect(r.items.length, 3);
      expect(r.hasError, isFalse);
    });

    test('第一源返回 200 但解析为空 → 换第二源（主源坏了图不能白屏）', () async {
      final KlineLoader loader = KlineLoader(
        chain: KlineSources2.both,
        httpGet: (Uri uri, Map<String, String> headers) async {
          final String host = uri.host;
          calls[host] = (calls[host] ?? 0) + 1;
          // 新浪：200 + null（真网见过）
          if (host == 'quotes.sina.cn') {
            return HttpRawResponse(
              statusCode: 200,
              body: _b('{"result":{"data":null}}'),
            );
          }
          return HttpRawResponse(statusCode: 200, body: _b(_tencentDaily));
        },
      );
      final KlineResult<Kline> r = await loader.loadDaily(kMaotai);
      expect(r.sourceId, 'tencent');
      expect(r.items.length, 2);
      expect(calls['quotes.sina.cn'], 1);
      expect(calls['web.ifzq.gtimg.cn'], 1);
    });

    test('两个源都失败 → 带错误信息，不抛异常', () async {
      final KlineLoader loader = KlineLoader(
        chain: KlineSources2.both,
        httpGet: (Uri uri, Map<String, String> headers) async =>
            const HttpRawResponse(statusCode: 502, body: <int>[]),
      );
      final KlineResult<Kline> r = await loader.loadDaily(kMaotai);
      expect(r.items, isEmpty);
      expect(r.hasError, isTrue);
      expect(r.error, contains('502'));
    });

    test('30 秒内重复请求走缓存，不打外网', () async {
      final KlineLoader loader = loaderWith(KlineSources2.both);
      await loader.loadDaily(kMaotai);
      await loader.loadDaily(kMaotai);
      expect(calls['quotes.sina.cn'], 1);
    });

    test('缓存过期后重新请求', () async {
      DateTime now = DateTime(2026, 11, 3, 10, 0);
      final KlineLoader loader = loaderWith(KlineSources2.both, now: () => now);
      await loader.loadDaily(kMaotai);
      now = now.add(AppConfig.klineCacheTtl + const Duration(seconds: 1));
      await loader.loadDaily(kMaotai);
      expect(calls['quotes.sina.cn'], 2);
    });

    test('分时与日线是两个缓存键，互不影响', () async {
      final KlineLoader loader = KlineLoader(
        chain: KlineSources2.both,
        httpGet: (Uri uri, Map<String, String> headers) async {
          final String host = uri.host;
          calls[host] = (calls[host] ?? 0) + 1;
          final bool intraday = uri.path.contains('minute');
          if (host == 'quotes.sina.cn') {
            return HttpRawResponse(
              statusCode: 200,
              body: _b(intraday ? _sinaIntraday : _sinaDaily),
            );
          }
          return HttpRawResponse(
            statusCode: 200,
            body: _b(intraday ? _tencentIntraday : _tencentDaily),
          );
        },
      );
      await loader.loadDaily(kMaotai);
      await loader.loadIntraday(kMaotai);
      // 新浪的分时和日线是同一个 host（靠 query 区分），所以是 2 次
      expect(calls['quotes.sina.cn'], 2);
    });

    // R-02（review-2026-11-05）：symbol_directory 的 R-04 教训——
    // 「边界层必须连 Error 一起拦」没有推广到 K 线链路。上游形状突变时
    // 解析器/请求层可能抛出 Error（RangeError / StateError 等），
    // `on Exception` 拦不住，异常会穿透 loadDaily 把详情页挂在
    // 「加载走势…」。走势是装饰性数据，任何失败都只能变成 failed 结果。
    test('请求层抛 Error → 换下一个源，不穿透', () async {
      final KlineLoader loader = KlineLoader(
        chain: KlineSources2.both,
        httpGet: (Uri uri, Map<String, String> headers) async {
          final String host = uri.host;
          calls[host] = (calls[host] ?? 0) + 1;
          if (host == 'quotes.sina.cn') {
            // Error 不是 Exception：修复前这里会直接把 loadDaily 炸穿
            throw StateError('模拟请求层 Error');
          }
          return HttpRawResponse(statusCode: 200, body: _b(_tencentDaily));
        },
      );
      final KlineResult<Kline> r = await loader.loadDaily(kMaotai);
      expect(r.sourceId, 'tencent');
      expect(r.items.length, 2);
      expect(calls['web.ifzq.gtimg.cn'], 1, reason: 'Error 也要走主备切换');
    });

    test('两个源都抛 Error → 带错误信息返回 failed，不抛异常', () async {
      final KlineLoader loader = KlineLoader(
        chain: KlineSources2.both,
        httpGet: (Uri uri, Map<String, String> headers) async =>
            throw StateError('模拟两个源都炸'),
      );
      final KlineResult<Kline> r = await loader.loadDaily(kMaotai);
      expect(r.items, isEmpty);
      expect(r.hasError, isTrue);
    });
  });

  /// 数据层保留 `count` 能力（UI 已不提供翻页入口）：唯一的旋钮就是 count。
  ///
  /// 这一组**必须断言发出去的 datalen**，不能只断言 items.length——
  /// 假 http 无论 count 多少都回同一份报文，那种断言在"count 根本没传下去"
  /// 的情况下依然全绿，等于没测。
  group('count → datalen', () {
    List<int> asked = <int>[];

    setUp(() => asked = <int>[]);

    KlineLoader paged() => KlineLoader(
          chain: KlineSources2.both,
          httpGet: (Uri uri, Map<String, String> headers) async {
            asked.add(int.parse(uri.queryParameters['datalen']!));
            return HttpRawResponse(statusCode: 200, body: _b(_sinaDaily));
          },
        );

    test('不传 count 是 80，翻一页是 160', () async {
      final KlineLoader loader = paged();
      await loader.loadDaily(kMaotai);
      await loader.loadDaily(kMaotai, count: KlineSource.dailyPageStep * 2);
      expect(asked, <int>[80, 160]);
    });

    test('两个 count 是两个缓存键：各自拉一次，翻回去不重复请求', () async {
      final KlineLoader loader = paged();
      await loader.loadDaily(kMaotai);
      await loader.loadDaily(kMaotai, count: 160);
      await loader.loadDaily(kMaotai); // 80 那页还在，不该再发
      await loader.loadDaily(kMaotai, count: 160);
      expect(asked, <int>[80, 160]);
    });

    test('超过上限的 count 被夹到 maxDailyCount（按钮封顶之外再兜一层）', () async {
      await paged().loadDaily(kMaotai, count: 9999);
      expect(asked, <int>[KlineSource.maxDailyCount]);
    });

    test('0 / 负数被夹到 1：URL 里绝不能出现 datalen=0', () async {
      final KlineLoader loader = paged();
      await loader.loadDaily(kMaotai, count: 0);
      await loader.loadDaily(kMaotai, count: -5);
      // 两次都夹成 1，第二次命中缓存——顺带证明夹紧发生在缓存键之前
      expect(asked, <int>[1]);
    });
  });
}

/// 测试里显式列出链路：不依赖生产默认值，否则将来调顺序会悄悄改变断言含义
abstract final class KlineSources2 {
  static const List<KlineSource> both = <KlineSource>[
    SinaKline(),
    TencentKline(),
  ];
}
