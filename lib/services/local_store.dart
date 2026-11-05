import 'dart:convert';
import 'dart:io';

import 'quote_feeds.dart';

import 'package:path_provider/path_provider.dart';

import '../utils/app_log.dart';

/// 极简的「键 → 文本」持久化。
///
/// 抽成接口是为了可测：widget 测试里用 [MemoryKeyValueStore]，
/// 不需要真的读写磁盘（`path_provider` 在纯 widget 测试里没有平台通道可用）。
abstract interface class KeyValueStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> remove(String key);
}

/// 内存实现：测试用，也可作为「拿不到目录」时的降级实现。
class MemoryKeyValueStore implements KeyValueStore {
  MemoryKeyValueStore([Map<String, String>? initial])
    : _data = <String, String>{...?initial};

  final Map<String, String> _data;

  /// 写次数：测试用它断言「没必要的写盘不会发生」
  int writes = 0;

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async {
    _data[key] = value;
    writes++;
  }

  @override
  Future<void> remove(String key) async {
    _data.remove(key);
  }
}

/// 落到应用私有目录下的单个 JSON 文件里。
///
/// 为什么不用 shared_preferences：股票目录（沪深两市约 5200 条）精简后仍有
/// 约 195KB，而 SharedPreferences 是为「几百字节级」配置设计的
/// —— Android 侧每次读都是整份 XML 解析，塞 200KB 会拖慢启动。
/// 这里一个文件、一次读入、内存缓存，都不大。
///
/// **同参数构造返回同一实例**（进程级实例池）：本文件是「整文件覆盖」语义，
/// 两个实例各持内存缓存写同一个文件会 last-writer-wins 互相抹 key
/// （订阅列表和目录缓存曾因此互踩）。默认构造天然共享；测试要隔离时给
/// 不同的 fileName 或 directoryProvider 即可拿到独立实例。
class FileKeyValueStore implements KeyValueStore {
  /// 实例池：key = (directoryProvider 身份, fileName)。
  static final Map<String, FileKeyValueStore> _instances =
      <String, FileKeyValueStore>{};

  factory FileKeyValueStore({
    Future<Directory> Function()? directoryProvider,
    String? fileName,
  }) {
    final Future<Directory> Function() provider =
        directoryProvider ?? getApplicationSupportDirectory;
    final String name = fileName ?? '${QuoteFeeds.id}_state.json';
    final String key = '${identityHashCode(provider)}|$name';
    return _instances[key] ??= FileKeyValueStore._(
      directoryProvider: provider,
      fileName: name,
    );
  }

  FileKeyValueStore._({
    required Future<Directory> Function() directoryProvider,
    required String fileName,
  }) : // 命名参数不能写成 `this._directoryProvider`（私有名规则不适用），
       // 与 symbol_directory.dart 同款处理
       // ignore: prefer_initializing_formals
       _directoryProvider = directoryProvider,
       // ignore: prefer_initializing_formals
       _fileName = fileName;

  /// 文件名带数据源 id：换源后不会读到上一个源格式的目录缓存。
  ///
  /// 混用比读不到更糟——一份格式不对的目录会让搜索静默失准，
  /// 而「读不到」起码会重新下载。
  final String _fileName;

  final Future<Directory> Function() _directoryProvider;

  Map<String, String>? _cache;
  Future<File>? _fileFuture;

  Future<File> _file() =>
      _fileFuture ??= _directoryProvider().then((Directory dir) async {
        await dir.create(recursive: true);
        return File('${dir.path}${Platform.pathSeparator}$_fileName');
      });

  Future<Map<String, String>> _load() async {
    final Map<String, String>? cached = _cache;
    if (cached != null) {
      return cached;
    }
    final File file = await _file();
    Map<String, String> data = <String, String>{};
    try {
      if (await file.exists()) {
        final String raw = await file.readAsString();
        if (raw.isNotEmpty) {
          final Object? decoded = jsonDecode(raw);
          if (decoded is Map<String, Object?>) {
            data = decoded.map(
              (String k, Object? v) => MapEntry<String, String>(k, '$v'),
            );
          }
        }
      }
    } on Object catch (e) {
      // 存档损坏不应该让 App 起不来：丢弃它，后续写入会重建。
      // 丢之前先把坏文件改名留档（.bak）——静默重置等于静默丢数据，
      // 留一份现场用户报障时才查得下去失了什么。
      AppLog.e('本地状态读取失败，已重置: $e');
      try {
        final File bak = File('${file.path}.bak');
        if (bak.existsSync()) {
          bak.deleteSync();
        }
        if (file.existsSync()) {
          file.renameSync(bak.path);
        }
      } on Object catch (ioError) {
        AppLog.w('坏存档留档失败（不影响重置）: $ioError');
      }
      data = <String, String>{};
    }
    _cache = data;
    return data;
  }

  @override
  Future<String?> read(String key) async => (await _load())[key];

  /// 原子写：先写同目录临时文件再 rename。
  ///
  /// 直接 `writeAsString` 覆盖目标文件时，App 在写入中途被杀会留下半截
  /// JSON——下次启动整个存档被静默重置。同分区 rename 是原子的，
  /// 目标文件要么是旧内容要么是完整新内容。
  Future<void> _writeAll(Map<String, String> data) async {
    final File file = await _file();
    final File tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(data), flush: true);
    await tmp.rename(file.path);
  }

  @override
  Future<void> write(String key, String value) async {
    final Map<String, String> data = await _load();
    data[key] = value;
    await _writeAll(data);
  }

  @override
  Future<void> remove(String key) async {
    final Map<String, String> data = await _load();
    if (data.remove(key) == null) {
      return;
    }
    await _writeAll(data);
  }
}
