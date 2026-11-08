import 'dart:io';
import 'dart:ui' show ErrorCallback, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/services/local_store.dart';
import 'package:super_market/services/watchlist_repository.dart';
import 'package:super_market/utils/error_hooks.dart';

/// 审查台账（2026-11-08）批次 D：持久化空状态 / 请求代际 / 错误钩子 /
/// 图表空态 / 通道异常 / 弹层重入。
void main() {
  group('批次 D｜持久化', () {
    test('#1 清空自选后重新加载仍为空（不再复活默认列表）', () async {
      final MemoryKeyValueStore store = MemoryKeyValueStore();
      final WatchlistRepository repo = WatchlistRepository(store);
      expect(await repo.save(const <StockConfig>[]), isTrue);

      final WatchlistRepository afterRestart = WatchlistRepository(store);
      expect(await afterRestart.load(), isEmpty,
          reason: '写侧删键、读侧把「无存档」当成「首次安装」，空状态不可表达');
    });

    test('#1b 已有的自选仍然照常往返', () async {
      final MemoryKeyValueStore store = MemoryKeyValueStore();
      const List<StockConfig> stocks = <StockConfig>[
        StockConfig(code: '000001', name: '平安银行', region: 'SZ'),
      ];
      expect(await WatchlistRepository(store).save(stocks), isTrue);
      expect(
        (await WatchlistRepository(store).load())
            .map((StockConfig s) => s.key)
            .toList(),
        <String>['000001@SZ'],
      );
    });

    test('#15c remove 落盘失败时也要回滚内存缓存', () {
      final String src =
          File('lib/services/local_store.dart').readAsStringSync();
      // 文件实现在最后：内存实现也有一份同名 remove，不能误命中它。
      final int begin = src.lastIndexOf('Future<void> remove(');
      expect(begin, greaterThan(-1));
      final String body = src.substring(begin);
      expect(body.contains('on Object'), isTrue,
          reason: 'write 有回滚，remove 没有，删除会在内存与磁盘之间分歧');
      expect(body.contains('rethrow'), isTrue);
    });
  });

  group('批次 D｜异步回写与错误钩子', () {
    test('#8 详情弹层的同 mode 在途请求要有代际判据', () {
      final String src =
          File('lib/widgets/quote_detail_sheet.dart').readAsStringSync();
      expect(src.contains('_loadSeq'), isTrue,
          reason: '只用 _mode != asked 挡不住「分时→日K→分时」的同 mode 乱序');
    });

    test('#8b 清空搜索词时也要作废旧请求', () {
      final String src =
          File('lib/widgets/watchlist_sheet.dart').readAsStringSync();
      final int matches =
          RegExp(r'\+\+_seq|_seq\+\+').allMatches(src).length;
      expect(matches, greaterThanOrEqualTo(2),
          reason: '_seq 只在 _search 递增，清空输入时在途结果仍会回写');
    });

    test('#15a 不得吞掉上一任 PlatformDispatcher.onError', () {
      final ErrorCallback? original = PlatformDispatcher.instance.onError;
      bool called = false;
      PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
        called = true;
        return true;
      };
      final VoidCallback restore = installErrorHooks(
        report: (String message, StackTrace? stack) {},
      );
      addTearDown(() {
        restore();
        PlatformDispatcher.instance.onError = original;
      });

      PlatformDispatcher.instance.onError!(
        StateError('boom'),
        StackTrace.current,
      );
      expect(called, isTrue,
          reason: 'previousPlatform 被读走后从不调用，第三方处理器会整体丢失');
    });

    test('#15b 图表空态判据要用过滤后的有效点数', () {
      final String src =
          File('lib/widgets/quote_detail_sheet.dart').readAsStringSync();
      final int begin =
          src.indexOf('final bool empty = mode == ChartMode.intraday');
      expect(begin, greaterThan(-1));
      expect(src.substring(begin, begin + 260).contains('isValid'), isTrue,
          reason: '「非空但全无效」会画出一张没有错误占位的空白图');
    });
  });

  group('批次 D｜原生通道与弹层重入（源码守门）', () {
    test('#18 帧率通道不得只拦两类异常', () {
      final String src =
          File('lib/utils/frame_rate.dart').readAsStringSync();
      expect(src.contains('on Object catch'), isTrue,
          reason: '原生侧参数强转抛 ClassCastException 时 Dart Future 会挂起');
    });

    test('#18b 弹层入口要有重入闸门', () {
      final String src =
          File('lib/pages/quote_list_page.dart').readAsStringSync();
      expect(src.contains('_sheetOpen'), isTrue,
          reason: '快速连点会叠多个 modal 并并发存盘');
    });
  });
}
