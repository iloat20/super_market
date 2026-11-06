import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/services/local_store.dart';
import 'package:super_market/services/watchlist_repository.dart';

/// 可编程失败的 store：模拟「磁盘满 / 目录不可写」。
class _FlakyStore implements KeyValueStore {
  _FlakyStore({this.failWrites = false});

  bool failWrites;
  final Map<String, String> data = <String, String>{};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) {
      throw const FileSystemException('磁盘满');
    }
    data[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    if (failWrites) {
      throw const FileSystemException('磁盘满');
    }
    data.remove(key);
  }
}

void main() {
  group('FileKeyValueStore：一次失败不得让整进程再也读不到存档', () {
    test('目录提供者第一次抛错后必须允许重试', () async {
      final Directory root = Directory.systemTemp.createTempSync('sm_retry_');
      addTearDown(() => root.deleteSync(recursive: true));

      int calls = 0;
      Future<Directory> provider() async {
        calls++;
        if (calls == 1) {
          throw StateError('path_provider 平台通道还没就绪');
        }
        return root;
      }

      final FileKeyValueStore store = FileKeyValueStore(
        directoryProvider: provider,
        fileName: 'retry.json',
      );

      await expectLater(store.read('k'), throwsA(isA<StateError>()));
      // 关键：`_fileFuture` 若把这次失败永久缓存，下面这行会抛同一个异常，
      // 而 `_loading` 那边是「失败后允许下一个调用方重试」的语义。
      expect(await store.read('k'), isNull);
      expect(calls, 2);
    });

    test('落盘失败时内存缓存必须回滚（缓存不得比磁盘新）', () async {
      final Directory root = Directory.systemTemp.createTempSync('sm_rollback_');
      addTearDown(() => root.deleteSync(recursive: true));
      // 目标路径占成一个**目录**：读得到空，写的时候 rename 必失败
      Directory('${root.path}${Platform.pathSeparator}state.json')
          .createSync(recursive: true);

      final FileKeyValueStore store = FileKeyValueStore(
        directoryProvider: () async => root,
        fileName: 'state.json',
      );

      expect(await store.read('k'), isNull);
      await expectLater(store.write('k', 'v'), throwsA(anything));
      expect(
        await store.read('k'),
        isNull,
        reason: '这一笔没落盘成功，缓存里就不能留着它；'
            '否则下次无关的写盘会把 `_cache` 全量写下去，把它顺手带上',
      );
    });
  });

  group('WatchlistRepository：写失败必须能被告知', () {
    test('store 抛异常时 save 返回 false（而不是静默成功）', () async {
      final _FlakyStore store = _FlakyStore(failWrites: true);
      final WatchlistRepository repo = WatchlistRepository(store);

      final bool ok = await repo.save(const <StockConfig>[
        StockConfig(code: '600519', name: '贵州茅台', region: 'SH'),
      ]);

      expect(ok, isFalse);
      expect(store.data, isEmpty);
    });

    test('store 正常时 save 返回 true 且内容可读回', () async {
      final _FlakyStore store = _FlakyStore();
      final WatchlistRepository repo = WatchlistRepository(store);
      const List<StockConfig> want = <StockConfig>[
        StockConfig(code: '600519', name: '贵州茅台', region: 'SH'),
      ];

      expect(await repo.save(want), isTrue);
      expect(await repo.load(), want);
    });
  });

  group('WatchlistRepository：用户数据与数据源解耦', () {
    test('新文件为空时会从旧文件名（带源 id）迁移过来', () async {
      final _FlakyStore userStore = _FlakyStore();
      final _FlakyStore legacyStore = _FlakyStore();
      const List<StockConfig> saved = <StockConfig>[
        StockConfig(code: '600519', name: '贵州茅台', region: 'SH'),
        StockConfig(code: 'PDD', name: '拼多多', region: 'US', exchange: 'NASDAQ'),
      ];
      legacyStore.data[WatchlistRepository.storageKey] =
          WatchlistRepository.encode(saved);

      final WatchlistRepository repo = WatchlistRepository(
        userStore,
        legacyStore: legacyStore,
      );

      expect(
        await repo.load(),
        saved,
        reason: '升级后第一次启动必须还原子选，而不是退回 AppConfig.stocks',
      );
      expect(
        userStore.data[WatchlistRepository.storageKey],
        isNotNull,
        reason: '迁移要落地：否则每次启动都得再读一遍旧文件',
      );
    });

    test('新文件已有数据时不读旧文件（不覆盖用户当前选择）', () async {
      final _FlakyStore userStore = _FlakyStore();
      final _FlakyStore legacyStore = _FlakyStore();
      const List<StockConfig> current = <StockConfig>[
        StockConfig(code: '000001', name: '平安银行', region: 'SZ'),
      ];
      const List<StockConfig> older = <StockConfig>[
        StockConfig(code: '600519', name: '贵州茅台', region: 'SH'),
      ];
      userStore.data[WatchlistRepository.storageKey] =
          WatchlistRepository.encode(current);
      legacyStore.data[WatchlistRepository.storageKey] =
          WatchlistRepository.encode(older);

      final WatchlistRepository repo = WatchlistRepository(
        userStore,
        legacyStore: legacyStore,
      );

      expect(await repo.load(), current);
    });
  });

  group('手输代码兜底：与搜索侧同口径', () {
    test('B 股与北交所号段一律不支持（返回 null，不猜市场）', () {
      // 2 开头：深市 B 股（200xxx）
      expect(WatchlistRepository.regionForCode('200011'), isNull);
      // 9 开头：沪市 B 股（900xxx）与北交所（920xxx）
      expect(WatchlistRepository.regionForCode('900901'), isNull);
      expect(WatchlistRepository.regionForCode('920000'), isNull);
    });

    test('正常 A 股与港股仍然能推断', () {
      expect(WatchlistRepository.regionForCode('000001'), 'SZ');
      expect(WatchlistRepository.regionForCode('300750'), 'SZ');
      expect(WatchlistRepository.regionForCode('600519'), 'SH');
      expect(WatchlistRepository.regionForCode('510300'), 'SH');
      expect(WatchlistRepository.regionForCode('00700'), 'HK');
    });
  });
}
