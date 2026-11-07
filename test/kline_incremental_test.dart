import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/kline.dart';
import 'package:super_market/services/kline_loader.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/services/source/kline_source.dart';
import 'package:super_market/services/source/sina_kline.dart';
import 'package:super_market/services/source/tencent_kline.dart';

/// 增量日线：TTL 过期后只拉「最新几根」再本地拼接。
///
/// 这批用例刻意**不看内部字段，只数发出去的 datalen / param 第 5 段**：
/// 优化是不是真的生效，只能由请求次数和根数证明。同时每条危险路径都必须
/// 证明它会**回退到全量**，因为拼接一旦错了，图上是一根人造跳空，
/// 而不是一次可以重试的失败。
///
/// 夹具与真网探针 `tool/probe_kline_delta.py` 对齐：count=2 的两根分别是
/// 「上一根（锚点）」和「最新一根」。

const StockConfig _maotai = StockConfig(
  code: '600519',
  name: '贵州茅台',
  region: 'SH',
);

const StockConfig _apple = StockConfig(code: 'AAPL', name: '苹果', region: 'US');

const List<KlineSource> _both = <KlineSource>[SinaKline(), TencentKline()];

String _d(int n) {
  final DateTime t = DateTime(2026, 1, 1).add(Duration(days: n));
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}

final List<String> _fullDays = <String>[for (int i = 1; i <= 80; i++) _d(i)];

/// 造新浪日线报文。`closeOf` 用来单独改某一根，模拟当日 bar 刷新 / 复权重算。
List<int> _sina(List<String> days, {double Function(String day)? closeOf}) =>
    utf8.encode(
      jsonEncode(<String, Object>{
        'result': <String, Object>{
          'status': <String, Object>{'code': 0},
          'data': <Object>[
            for (final String d in days)
              <String, Object>{
                'day': d,
                'open': '9.5',
                'high': '10.5',
                'low': '9.0',
                'close': (closeOf?.call(d) ?? 10.0).toStringAsFixed(2),
                'volume': '1000',
              },
          ],
        },
      }),
    );

/// 造腾讯日线报文：[日期, 开, 收, 高, 低, 量(手)]。
List<int> _tencent(List<String> days, {double Function(String day)? closeOf}) =>
    utf8.encode(
      jsonEncode(<String, Object>{
        'code': 0,
        'data': <String, Object>{
          'sh600519': <String, Object>{
            'qfqday': <Object>[
              for (final String d in days)
                <Object>[
                  d,
                  '9.5',
                  (closeOf?.call(d) ?? 99.0).toStringAsFixed(2),
                  '10.5',
                  '9.0',
                  '1000',
                ],
            ],
            'qt': <String, Object>{},
            'prec': '9.0',
            'version': 'x',
          },
        },
      }),
    );

class _Clock {
  DateTime value = DateTime(2026, 11, 3, 10, 0);

  DateTime Function() get call =>
      () => value;

  void expire() =>
      value = value.add(AppConfig.klineCacheTtl + const Duration(seconds: 1));
}

typedef _Responder = Future<HttpRawResponse> Function(bool isSina, int count);

/// 假网络：把每个请求的「源 + 根数」记进 [asked]，报文由测试自己给。
KlineLoader _loader(
  List<String> asked,
  _Responder respond, {
  DateTime Function()? now,
  List<KlineSource>? chain,
}) {
  return KlineLoader(
    chain: chain ?? _both,
    now: now,
    httpGet: (Uri uri, Map<String, String> headers) async {
      final bool isSina = uri.host == 'quotes.sina.cn';
      final int n = isSina
          ? int.parse(uri.queryParameters['datalen']!)
          : int.parse(uri.queryParameters['param']!.split(',')[4]);
      asked.add('${isSina ? 'sina' : 'tx'}:$n');
      return await respond(isSina, n);
    },
  );
}

/// 全量请求永远回 80 根（或按 count 截尾），增量请求由调用方覆写。
_Responder _net({
  List<int>? Function(bool isSina, int count)? delta,
  int sinaStatus = 200,
}) {
  return (bool isSina, int count) async {
    if (delta != null) {
      final List<int>? special = delta(isSina, count);
      if (special != null) {
        return HttpRawResponse(statusCode: 200, body: special);
      }
    }
    if (isSina) {
      return HttpRawResponse(
        statusCode: sinaStatus,
        body: _sina(_fullDays.sublist(_fullDays.length - count)),
      );
    }
    return HttpRawResponse(
      statusCode: 200,
      body: _tencent(_fullDays.sublist(_fullDays.length - count)),
    );
  };
}

void main() {
  group('增量日线：收益', () {
    test('TTL 过期后只请求 2 根，拼接出「79 根旧 + 1 根新」', () async {
      final List<String> asked = <String>[];
      final _Clock clock = _Clock();
      final KlineLoader loader = _loader(
        asked,
        _net(
          delta: (bool isSina, int count) {
            if (isSina && count == 2) {
              return _sina(<String>[
                _d(80),
                _d(81),
              ], closeOf: (String d) => d == _d(81) ? 11.0 : 10.0);
            }
            return null;
          },
        ),
        now: clock.call,
      );

      final first = await loader.loadDaily(_maotai);
      expect(first.items.length, 80);
      clock.expire();
      final second = await loader.loadDaily(_maotai);

      expect(asked, <String>[
        'sina:80',
        'sina:2',
      ], reason: '过期后若再发一次 80，说明增量根本没生效');
      expect(second.items.length, 80, reason: '窗口要保持 80 根，不能无限长');
      expect(second.items.first.time, DateTime.parse(_d(2)));
      expect(second.items.last.time, DateTime.parse(_d(81)));
      expect(second.items.last.close, 11.0);
      expect(second.sourceId, 'sina');
      expect(second.hasError, isFalse);
    });

    test('增量成功后仍在 TTL 内 → 一次请求都不发', () async {
      final List<String> asked = <String>[];
      final _Clock clock = _Clock();
      final KlineLoader loader = _loader(
        asked,
        _net(
          delta: (bool isSina, int count) =>
              isSina && count == 2 ? _sina(<String>[_d(80), _d(81)]) : null,
        ),
        now: clock.call,
      );

      await loader.loadDaily(_maotai);
      clock.expire();
      await loader.loadDaily(_maotai);
      await loader.loadDaily(_maotai);
      expect(asked, <String>['sina:80', 'sina:2']);
    });

    test('美股（新浪不支持）走腾讯，增量同样生效', () async {
      final List<String> asked = <String>[];
      final _Clock clock = _Clock();
      final KlineLoader loader = _loader(
        asked,
        _net(
          delta: (bool isSina, int count) =>
              !isSina && count == 2 ? _tencent(<String>[_d(80), _d(81)]) : null,
        ),
        now: clock.call,
      );

      final first = await loader.loadDaily(_apple);
      expect(first.sourceId, 'tencent');
      clock.expire();
      final second = await loader.loadDaily(_apple);

      expect(asked, <String>['tx:80', 'tx:2']);
      expect(second.items.length, 80);
      expect(second.items.last.time, DateTime.parse(_d(81)));
      expect(second.sourceId, 'tencent');
    });
  });

  group('增量日线：同日刷新与窗口维护', () {
    test('最后一根同日被更新 → 覆盖而不是追加，长度不变', () async {
      final List<String> asked = <String>[];
      final _Clock clock = _Clock();
      final KlineLoader loader = _loader(
        asked,
        _net(
          delta: (bool isSina, int count) {
            if (isSina && count == 2) {
              return _sina(<String>[
                _d(79),
                _d(80),
              ], closeOf: (String d) => d == _d(80) ? 12.0 : 10.0);
            }
            return null;
          },
        ),
        now: clock.call,
      );

      await loader.loadDaily(_maotai);
      clock.expire();
      final r = await loader.loadDaily(_maotai);

      expect(asked, <String>['sina:80', 'sina:2']);
      expect(r.items.length, 80, reason: '腾讯的当日 bar 会实时变，不能每 30s 多长一根');
      expect(r.items.last.time, DateTime.parse(_d(80)));
      expect(r.items.last.close, 12.0);
    });

    test('count=1 时缓存不足两根，退化为普通全量请求', () async {
      final List<String> asked = <String>[];
      final _Clock clock = _Clock();
      final KlineLoader loader = _loader(asked, _net(), now: clock.call);

      final first = await loader.loadDaily(_maotai, count: 1);
      clock.expire();
      final second = await loader.loadDaily(_maotai, count: 1);

      expect(asked, <String>['sina:1', 'sina:1']);
      expect(first.items.length, 1);
      expect(second.items.length, 1);
    });

    test('clear() 之后是全量重拉（手动重试不能拿旧缓存拼）', () async {
      final List<String> asked = <String>[];
      final KlineLoader loader = _loader(asked, _net());

      await loader.loadDaily(_maotai);
      loader.clear();
      await loader.loadDaily(_maotai);

      expect(asked, <String>['sina:80', 'sina:80']);
    });
  });

  group('增量日线：任何可疑情况都必须回退全量', () {
    test('锚点对不上（中间漏了交易日 / 跨了长假）→ 全量', () async {
      final List<String> asked = <String>[];
      final _Clock clock = _Clock();
      final KlineLoader loader = _loader(
        asked,
        _net(
          delta: (bool isSina, int count) =>
              isSina && count == 2 ? _sina(<String>[_d(85), _d(86)]) : null,
        ),
        now: clock.call,
      );

      await loader.loadDaily(_maotai);
      clock.expire();
      final r = await loader.loadDaily(_maotai);

      expect(asked, <String>['sina:80', 'sina:2', 'sina:80']);
      expect(r.items.length, 80);
      expect(r.items.last.time, DateTime.parse(_d(80)));
    });

    test('锚点价格被改（除权除息 / qfq 全历史重算）→ 全量', () async {
      final List<String> asked = <String>[];
      final _Clock clock = _Clock();
      final KlineLoader loader = _loader(
        asked,
        _net(
          delta: (bool isSina, int count) {
            if (isSina && count == 2) {
              return _sina(<String>[
                _d(80),
                _d(81),
              ], closeOf: (String d) => d == _d(80) ? 9.0 : 11.0);
            }
            return null;
          },
        ),
        now: clock.call,
      );

      await loader.loadDaily(_maotai);
      clock.expire();
      final r = await loader.loadDaily(_maotai);

      expect(asked, <String>['sina:80', 'sina:2', 'sina:80']);
      expect(r.items.length, 80);
    });

    test('增量请求失败 → 回退全量主备，绝不把备源的 bar 拼到主源序列上', () async {
      final List<String> asked = <String>[];
      final _Clock clock = _Clock();
      int phase = 0; // 0=首次全量，1=增量探测，2=全量主备回退
      final KlineLoader loader = _loader(asked, (bool isSina, int count) async {
        if (isSina && count == 2) {
          phase = 1;
          return const HttpRawResponse(statusCode: 502, body: <int>[]);
        }
        if (phase == 1 && isSina && count == 80) {
          phase = 2;
          return const HttpRawResponse(statusCode: 502, body: <int>[]);
        }
        if (isSina) {
          return HttpRawResponse(
            statusCode: 200,
            body: _sina(_fullDays.sublist(_fullDays.length - count)),
          );
        }
        return HttpRawResponse(
          statusCode: 200,
          body: _tencent(_fullDays.sublist(_fullDays.length - count)),
        );
      }, now: clock.call);

      final first = await loader.loadDaily(_maotai);
      expect(first.sourceId, 'sina');
      clock.expire();
      final second = await loader.loadDaily(_maotai);

      expect(asked, <String>['sina:80', 'sina:2', 'sina:80', 'tx:80']);
      expect(second.sourceId, 'tencent');
      expect(second.items.length, 80);
      expect(
        second.items.every((Kline k) => k.close == 99.0),
        isTrue,
        reason: '只要还剩一根新浪的 10.0，就是主备混拼',
      );
    });

    test('增量请求抛 Error → 回退全量，不穿透到详情页', () async {
      final List<String> asked = <String>[];
      final _Clock clock = _Clock();
      final KlineLoader loader = _loader(asked, (bool isSina, int count) async {
        if (isSina && count == 2) {
          throw StateError('模拟增量请求炸了');
        }
        return HttpRawResponse(
          statusCode: 200,
          body: _sina(_fullDays.sublist(_fullDays.length - count)),
        );
      }, now: clock.call);

      await loader.loadDaily(_maotai);
      clock.expire();
      final r = await loader.loadDaily(_maotai);

      expect(asked, <String>['sina:80', 'sina:2', 'sina:80']);
      expect(r.hasError, isFalse);
      expect(r.items.length, 80);
    });

    test('增量响应根数不对 → 回退全量', () async {
      final List<String> asked = <String>[];
      final _Clock clock = _Clock();
      final KlineLoader loader = _loader(
        asked,
        _net(
          delta: (bool isSina, int count) =>
              isSina && count == 2 ? _sina(<String>[_d(81)]) : null,
        ),
        now: clock.call,
      );

      await loader.loadDaily(_maotai);
      clock.expire();
      final r = await loader.loadDaily(_maotai);

      expect(asked, <String>['sina:80', 'sina:2', 'sina:80']);
      expect(r.items.length, 80);
    });
  });
}
