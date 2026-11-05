import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/services/local_store.dart';

/// 审查台账 R-02 / R-03 的回归测试。
///
/// 缺陷背景（2026-11-04 审查）：
/// - R-02：`quote_list_page.dart` 给 `WatchlistRepository` 和
///   `SymbolDirectory` 各 new 了一个 `FileKeyValueStore()`，两个实例默认
///   同名文件却各持内存缓存，write 是「读自己缓存 → 整文件覆盖」——
///   交错的写入会 last-writer-wins 抹掉对方 key（订阅丢失）。
///   修复：无参（默认参数）构造返回进程级共享实例。
/// - R-03：`writeAsString` 直接覆盖目标文件，写入中断 → JSON 截断 →
///   下次启动静默重置丢数据。修复：临时文件 + rename（同分区原子）；
///   损坏文件重置前留 `.bak`。
Future<Directory> Function() _provider(Directory dir) => () async => dir;

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('itick_store_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('存储实例共享（R-02）', () {
    test('同参数（默认）构造返回同一实例，写入互相可见', () async {
      // 注意：必须复用同一个 provider 引用——实例池按 provider 的
      // identityHashCode 分池，生产代码都传 null（指向同一个
      // getApplicationSupportDirectory），天然共享。
      // 闭包（而非函数声明）是有意的：同一闭包对象才有稳定 identity。
      // ignore: prefer_function_declarations_over_variables
      final Future<Directory> Function() provider = () async => tempDir;
      final FileKeyValueStore a = FileKeyValueStore(
        directoryProvider: provider,
        fileName: 'shared.json',
      );
      final FileKeyValueStore b = FileKeyValueStore(
        directoryProvider: provider,
        fileName: 'shared.json',
      );
      expect(identical(a, b), isTrue,
          reason: '同一文件的两个 store 必须是同一实例，否则互相抹数据');

      await a.write('watchlist.v1', 'A');
      await b.write('symbols.v1', 'B');
      expect(await a.read('watchlist.v1'), 'A',
          reason: 'b 写 symbols 不得抹掉 a 的 watchlist');
      expect(await b.read('symbols.v1'), 'B');
    });

    test('不同文件名的实例互相独立（缓存不得串台）', () async {
      final FileKeyValueStore a = FileKeyValueStore(
        directoryProvider: _provider(tempDir),
        fileName: 'one.json',
      );
      final FileKeyValueStore b = FileKeyValueStore(
        directoryProvider: _provider(tempDir),
        fileName: 'two.json',
      );
      expect(identical(a, b), isFalse);
      await a.write('k', 'A');
      expect(await b.read('k'), isNull);
    });
  });

  group('损坏存档与原子写（R-03）', () {
    test('损坏存档被重置，且坏文件留 .bak 便于排查', () async {
      final File file =
          File('${tempDir.path}${Platform.pathSeparator}corrupt.json');
      await file.writeAsString('{"watchlist.v1":"[{"c":"0000', flush: true);
      final FileKeyValueStore store = FileKeyValueStore(
        directoryProvider: _provider(tempDir),
        fileName: 'corrupt.json',
      );

      expect(await store.read('watchlist.v1'), isNull,
          reason: '损坏存档读不到东西（已有行为）');
      final File bak =
          File('${tempDir.path}${Platform.pathSeparator}corrupt.json.bak');
      expect(bak.existsSync(), isTrue,
          reason: '重置前应把坏文件改名留档，丢数据不能悄无声息');
      expect(bak.readAsStringSync(), contains('watchlist.v1'));
    });

    test('写入成功后不留临时文件，读取往返一致', () async {
      final FileKeyValueStore store = FileKeyValueStore(
        directoryProvider: _provider(tempDir),
        fileName: 'atomic.json',
      );
      await store.write('watchlist.v1', '[{"c":"000001","r":"SZ"}]');

      expect(await store.read('watchlist.v1'), '[{"c":"000001","r":"SZ"}]');
      expect(
        tempDir.listSync().whereType<File>().map((File f) => f.path).where(
              (String p) => p.endsWith('.tmp'),
            ),
        isEmpty,
        reason: '原子写走临时文件 + rename，成功后不得残留 .tmp',
      );
    });
  });
}
