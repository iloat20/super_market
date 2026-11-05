import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/services/local_store.dart';
import 'package:super_market/services/rest_client.dart';
import 'package:super_market/services/source/symbol_catalog.dart';
import 'package:super_market/services/symbol_directory.dart';

/// 审查台账 R-11 / R-04（目录边界）的回归测试。
///
/// - R-11：目录缓存损坏或为空 + 抓取失败时，每次打开添加面板都会重新
///   触发 6 并发 × 200 页的全量抓取。修复：失败后进入
///   [AppConfig.symbolRetryCooldown] 冷却期，期间不重复打免费接口。
/// - R-04：`ensureLoaded` / `searchRemote` 只捕 `on Exception`，而
///   `Error`（如解析层对 Infinity 的 UnsupportedError）会直接逃逸到
///   UI 的 async gap。修复：边界层扩为 `on Object`。
class _FakeCatalog implements SymbolCatalog {
  int calls = 0;
  Object? thrown = const SymbolFetchException('目录服务挂了');

  @override
  String get id => 'fake';

  @override
  String get displayName => 'Fake';

  @override
  List<String> get markets => const <String>['SZ'];

  @override
  Future<List<StockConfig>> fetchSymbols({required HttpGetJson httpGet}) async {
    calls++;
    final Object? t = thrown;
    if (t != null) {
      throw t;
    }
    return const <StockConfig>[
      StockConfig(code: '000001', name: '平安银行', region: 'SZ'),
    ];
  }
}

void main() {
  group('目录抓取冷却（R-11）', () {
    test('失败后冷却期内不重抓，冷却过期后恢复', () async {
      final _FakeCatalog catalog = _FakeCatalog();
      DateTime now = DateTime(2026, 11, 4, 10);
      final SymbolDirectory dir = SymbolDirectory(
        store: MemoryKeyValueStore(),
        source: catalog,
        now: () => now,
      );

      await dir.ensureLoaded();
      expect(catalog.calls, 1, reason: '首次必然要抓');
      expect(dir.error, isNotNull);

      now = now.add(const Duration(minutes: 1));
      await dir.ensureLoaded();
      expect(catalog.calls, 1, reason: '冷却期内不该再打免费接口');

      now = now.add(const Duration(minutes: 11));
      catalog.thrown = null; // 冷却过期后源恢复
      await dir.ensureLoaded();
      expect(catalog.calls, 2, reason: '冷却过期后应恢复抓取');
      expect(dir.isLoaded, isTrue);
      expect(dir.error, isNull);
    });

    test('成功路径不受冷却影响：命中缓存零请求（对照）', () async {
      final _FakeCatalog catalog = _FakeCatalog()..thrown = null;
      DateTime now = DateTime(2026, 11, 4, 10);
      final SymbolDirectory dir = SymbolDirectory(
        store: MemoryKeyValueStore(),
        source: catalog,
        now: () => now,
      );

      await dir.ensureLoaded();
      await dir.ensureLoaded();
      expect(catalog.calls, 1, reason: '成功后走内存/缓存，不该重复抓');
    });
  });

  group('目录边界的 Error 拦截（R-04）', () {
    test('fetchSymbols 抛 Error 时不逃逸，记为加载失败', () async {
      final _FakeCatalog catalog = _FakeCatalog()
        ..thrown = UnsupportedError('Infinity.toInt()（模拟解析层 Error）');
      final SymbolDirectory dir = SymbolDirectory(
        store: MemoryKeyValueStore(),
        source: catalog,
      );

      // 红态：on Exception 拦不住 Error，ensureLoaded 直接把异常抛给调用方
      await dir.ensureLoaded();
      expect(dir.error, isNotNull);
      expect(dir.isLoaded, isFalse);
    });

    test('searchRemote 抛 Error 时返回 null（请求失败），不逃逸', () async {
      final SymbolDirectory dir = SymbolDirectory(
        store: MemoryKeyValueStore(),
        httpGetBytes: (Uri uri, Map<String, String> headers) async =>
            throw UnsupportedError('boom'),
      );

      final List<StockConfig>? result = await dir.searchRemote('茅台');
      expect(result, isNull, reason: 'null 语义 = 这一次请求失败');
    });
  });
}
