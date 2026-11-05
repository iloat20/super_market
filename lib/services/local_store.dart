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
    // C-02（review-2026-11-05）：池 key 用 provider.hashCode（== 语义），
    // 不用 identityHashCode。默认路径的 provider 是每次 factory 求值都新建
    // 的顶层函数 tear-off，「相等对象必有相等 hashCode」是语言规范的保证；
    // 而 identical 只是 VM 的实现细节（2026-11-05 探针实测 VM 会规范化
    // tear-off，但规范不承诺）。改后池对默认构造路径的共享从「依赖实现」
    // 变成「依赖规范」。
    final String key = '${provider.hashCode}|$name';
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

  /// 首读单飞（C-03 前半）：并发首读在途时的共享 Future。
  Future<Map<String, String>>? _loading;

  /// 落盘队列（C-03 后半）：同一实例的落盘严格串行。
  ///
  /// `.tmp` 路径是固定的（`<file>.tmp`），两个 write 并发时一旦交错
  /// （A 写 tmp → A rename → B 写 tmp → B rename），B 的 rename 会因 tmp
  /// 已被 A 搬走而抛 FileSystemException——那次落盘就丢了（内存缓存
  /// 不受影响，但要等下一次成功写盘才补上）。排队后互不干扰；排到后面的
  /// 成员总是把**当时最新的** `_cache` 全量写下去，天然把前面的变更一起带上。
  Future<void> _writeQueue = Future<void>.value();

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
    // C-03 前半：首读必须单飞。并发首读时每个调用方各自读盘、各自赋
    // _cache，拿到的是**不同的 map 实例**——后完成者覆盖先完成者，
    // 先到的调用方拿着被丢弃的旧实例改 key，改动永远进不了 _cache
    // （64 路并发写实测丢掉第一笔，read 返回 null）。单飞后所有调用方
    // 共享同一次读盘的同一个实例。
    final Future<Map<String, String>>? inFlight = _loading;
    if (inFlight != null) {
      return inFlight;
    }
    final Future<Map<String, String>> future = _loadFromDisk();
    _loading = future;
    return future.whenComplete(() {
      // 成败都清场：成功后走 _cache 快路径；失败允许下一个调用方重试
      _loading = null;
    });
  }

  Future<Map<String, String>> _loadFromDisk() async {
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
    await _enqueueWrite();
  }

  /// 把一次全量落盘排进队列；返回的 Future 在**这一次落盘**完成时完成。
  ///
  /// 队列成员失败（磁盘错误）时：调用方拿到的 Future 照常抛（`save` 的
  /// catch 会记日志），队列本身吞掉失败继续走——坏一次不能堵死后面所有写。
  Future<void> _enqueueWrite() {
    final Future<void> run = _writeQueue.then<void>((_) => _writeAll(_cache!));
    _writeQueue = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  @override
  Future<void> remove(String key) async {
    final Map<String, String> data = await _load();
    if (data.remove(key) == null) {
      return;
    }
    await _enqueueWrite();
  }
}
