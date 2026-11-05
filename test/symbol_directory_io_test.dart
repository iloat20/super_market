import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:super_market/config/app_config.dart';
import 'package:super_market/services/local_store.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/services/source/symbol_catalog.dart';
import 'package:super_market/services/symbol_directory.dart';

/// 目录存档的**读盘边界**：读不出来是"没有缓存"，不是"不能工作"。
///
/// 这条路径曾经把异常直接抛给 `ensureLoaded` 的调用方：
/// `_readCache()` 在 `try` 之外（symbol_directory.dart:81），只有
/// `fetchSymbols` 被兜住。于是 path_provider 一失败，异常就穿过
/// `_WatchlistSheetState._prepareDirectory`，被 `unawaited(...)` 吞成一条
/// 引擎级 unhandled error——界面上没有任何提示，本地搜索永远是空的。

class _ThrowingStore implements KeyValueStore {
  @override
  Future<String?> read(String key) async => throw StateError('disk down');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('disk down');

  @override
  Future<void> remove(String key) async => throw StateError('disk down');
}

class _Catalog implements SymbolCatalog {
  _Catalog(this.items);

  final List<StockConfig> items;

  @override
  String get id => 'test';

  @override
  String get displayName => 'Test';

  @override
  List<String> get markets => const <String>['SZ', 'SH'];

  @override
  Future<List<StockConfig>> fetchSymbols({required HttpGetJson httpGet}) async =>
      items;
}

/// 造一份与 `_writeCache` 同格式的存档：`{"savedAt":ms,"rows":[[code,region,name]]}`
String _catalogJson(int n) {
  final List<List<String>> rows = <List<String>>[
    for (int i = 0; i < n; i++)
      <String>[
        (600000 + i).toString(),
        'SH',
        '测试股票$i',
      ],
  ];
  return jsonEncode(<String, Object>{
    'savedAt': DateTime(2026, 11, 4).millisecondsSinceEpoch,
    'rows': rows,
  });
}

const StockConfig _fetched = StockConfig(
  code: '600519',
  name: '贵州茅台',
  region: 'SH',
);

void main() {
  test('存档读不出来时，ensureLoaded 不该把异常抛给调用方', () async {
    final SymbolDirectory dir = SymbolDirectory(
      store: _ThrowingStore(),
      source: _Catalog(const <StockConfig>[_fetched]),
    );

    // 红态：当前这里会抛 StateError('disk down')
    await expectLater(dir.ensureLoaded(), completes);

    expect(
      dir.isLoaded,
      isTrue,
      reason: '缓存读不到 ≠ 不能拉新目录：应当降级成"无缓存"继续走网络',
    );
    expect(dir.count, 1);
    expect(dir.search('茅台').single.code, '600519');
  });

  test('小存档（走内联解析）：条目与搜索都正常', () async {
    final SymbolDirectory dir = SymbolDirectory(
      store: MemoryKeyValueStore(<String, String>{
        SymbolDirectory.storageKey: _catalogJson(3),
      }),
      source: _Catalog(const <StockConfig>[]),
    );
    await dir.ensureLoaded();

    expect(dir.count, 3);
    expect(dir.search('600001').single.region, 'SH');
  });

  test('大存档（5200 条，走上 isolate 的路径）也必须完整解析', () async {
    // 真实目录约 195KB。这里既是容量测试，也是"解码挪进 isolate 之后
    // 数据没被截断/串号"的回归——用 Isolate.run 时最容易出的错是
    // 返回值没被正确传回，表现为 count 变 0 或只有前几条。
    final SymbolDirectory dir = SymbolDirectory(
      store: MemoryKeyValueStore(<String, String>{
        SymbolDirectory.storageKey: _catalogJson(5200),
      }),
      source: _Catalog(const <StockConfig>[]),
    );
    await dir.ensureLoaded();

    expect(dir.count, 5200);
    expect(dir.search('600000').first.code, '600000');
    expect(dir.search('605199').first.code, '605199', reason: '最后一条也要在');
  });
}
