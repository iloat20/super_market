import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/kline.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/services/kline_loader.dart';
import 'package:super_market/widgets/kline_chart.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/services/source/kline_source.dart';
import 'package:super_market/services/source/sina_kline.dart';
import 'package:super_market/utils/quote_freshness.dart';

/// 审查台账（2026-11-08）批次 C：时钟回拨 / 缓存边界 / 增量锚点 /
/// 复权口径 / 时区折算。
const StockConfig kMaotai =
    StockConfig(code: '600519', name: 'MAOTAI', region: 'SH');

Quote quoteAt(DateTime ts) => Quote(
  code: '600519',
  region: 'SH',
  price: 11.48,
  change: 0.01,
  changePercent: 0.1,
  timestamp: ts,
);

String dayOf(int i) {
  final DateTime t = DateTime(2026, 1, 1).add(Duration(days: i));
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}

List<int> sinaBody(int count) => utf8.encode(
  jsonEncode(<String, Object?>{
    'result': <String, Object?>{
      'data': <Object?>[
        for (int i = 0; i < count; i++)
          <String, Object?>{
            'day': dayOf(i),
            'open': '9.5',
            'high': '10.5',
            'low': '9.0',
            'close': '10.0',
            'volume': '1000',
          },
      ],
    },
  }),
);

KlineLoader loaderFor(DateTime Function() now, void Function() onRequest) =>
    KlineLoader(
      chain: <KlineSource>[SinaKline()],
      httpGet: (Uri uri, Map<String, String> headers) async {
        onRequest();
        return HttpRawResponse(
          statusCode: 200,
          body: sinaBody(int.parse(uri.queryParameters['datalen'] ?? '80')),
        );
      },
      now: now,
    );

void main() {
  group('批次 C｜时钟回拨与新鲜度', () {
    test('#9 回拨超过一个判决线周期时，旧价不得再被标成实时', () {
      final DateTime now = DateTime(2026, 11, 8, 10);
      final Quote q = quoteAt(now.add(const Duration(hours: 2)));
      expect(isStale(q, now), isTrue,
          reason: '本地时钟被调回时，「不误标时钟偏差」不该变成「永远实时」');
      expect(staleIn(q, now), isNull);
    });

    test('#9b 小幅超前仍不误标（既有契约）', () {
      final DateTime now = DateTime(2026, 11, 8, 10);
      expect(isStale(quoteAt(now.add(const Duration(seconds: 30))), now),
          isFalse);
    });

    test('#9c staleIn 不得把负差放大成超长剩余时间', () {
      final DateTime now = DateTime(2026, 11, 8, 10);
      final Duration? remaining =
          staleIn(quoteAt(now.add(const Duration(minutes: 4))), now);
      expect(remaining, isNotNull);
      expect(remaining! <= kQuoteStaleAfter, isTrue,
          reason: '5 分钟 + 4 分钟 = 9 分钟的定时器会让界面长时间不复查');
    });
  });

  group('批次 C｜K 线缓存边界', () {
    test('#10 恰好等于 TTL 时与 isStale 同为开区间，不算过期', () async {
      DateTime clock = DateTime(2026, 11, 3, 10);
      int calls = 0;
      final KlineLoader loader =
          loaderFor(() => clock, () => calls++);
      await loader.loadDaily(kMaotai);
      expect(calls, 1);
      clock = clock.add(AppConfig.klineCacheTtl);
      await loader.loadDaily(kMaotai);
      expect(calls, 1,
          reason: '缓存用 !isBefore（等于即过期），新鲜度用 >（等于仍新鲜），口径相反');
    });

    test('#10 墙钟回拨后缓存不得长期不过期', () async {
      DateTime clock = DateTime(2026, 11, 3, 10);
      int calls = 0;
      final KlineLoader loader =
          loaderFor(() => clock, () => calls++);
      await loader.loadDaily(kMaotai);
      expect(calls, 1);
      clock = clock.subtract(const Duration(hours: 2));
      await loader.loadDaily(kMaotai);
      expect(calls, greaterThan(1),
          reason: 'expiresAt 是绝对墙钟，回拨后永远走不到，末根会长期脱节');
    });
  });

  group('批次 C｜增量、复权口径与时区（源码守门）', () {
    test('#17 增量锚点按交易日归一化，不看时分秒 / 时区标记', () {
      final String src =
          File('lib/services/kline_loader.dart').readAsStringSync();
      expect(src.contains('a.time == b.time'), isFalse,
          reason: 'DateTime 相等含时刻与 isUtc，带后缀的日线会让增量永久回退全量');
      expect(src.contains('_sameDay(a.time, b.time)'), isTrue);
    });

    test('#17b 末根刷新分支不得用更早时刻覆盖较晚的 bar', () {
      final String src =
          File('lib/services/kline_loader.dart').readAsStringSync();
      expect(src.contains('!latest.time.isBefore(last.time)'), isTrue);
    });

    test('#16 复权序列与实时报价的口径必须能被 UI 区分', () {
      final String model =
          File('lib/models/kline.dart').readAsStringSync();
      final String ui =
          File('lib/widgets/quote_detail_sheet.dart').readAsStringSync();
      expect(model.contains('includesToday'), isTrue,
          reason: 'KlineResult 要能说出「这条序列本身含当日实时 bar」');
      expect(ui.contains('includesToday'), isTrue,
          reason: '腾讯 qfq 含当日，不该再用未复权报价叠出一根混价 bar');
    });

    test('#16b qfq 序列刷新末根时不得混入报价的 high/low', () {
      final List<Kline> bars = <Kline>[
        Kline(
          time: DateTime(2026, 11, 4),
          open: 341.57,
          high: 354.50,
          low: 340.99,
          close: 349.51,
          volume: 1,
        ),
      ];
      final Quote q = Quote(
        code: 'AAPL',
        region: 'US',
        price: 349.99,
        change: 8.42,
        changePercent: 2.46,
        previousClose: 341.57,
        open: 341.57,
        high: 400.0,
        low: 300.0,
        volume: 89637749,
        timestamp: DateTime(2026, 11, 5, 3, 30),
      );
      final List<Kline> patched = patchTodayBar(bars, q, adjusted: true);
      expect(patched.last.high, 354.50,
          reason: '复权序列的极值不能被未复权报价撑开');
      expect(patched.last.low, 340.99);
      expect(patched.last.close, 349.99, reason: '实时价刷新仍要保留');
    });

    test('#17c 美东折算走纯字段偏移，不依赖设备本地时区的夏令时', () {
      final String src =
          File('lib/utils/trading_day.dart').readAsStringSync();
      expect(src.contains('beijing.subtract('), isFalse,
          reason: '本地标记 DateTime 的 subtract 跨 DST 换制点时字段偏移会少/多 1 小时');
      expect(src.contains('_minusHours'), isTrue);
    });
  });
}
