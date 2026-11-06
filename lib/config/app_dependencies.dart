import '../services/kline_loader.dart';
import '../services/local_store.dart';
import '../services/symbol_directory.dart';
import '../services/watchlist_repository.dart';

/// 组合根产物：生产路径里数据层对象只在这里创建一次，再下发给 UI 层。
///
/// 为什么显式共享一个 store：`WatchlistRepository` 与 `SymbolDirectory`
/// 各自 new 一个 `FileKeyValueStore()` 时曾出现「同文件名、两份内存缓存
/// 互相抹 key」（R-02）。实例池已经能兜住，这里把意图写成显式共享，
/// 不再依赖工厂的隐式行为。
///
/// 页面里的 `??` 兜底**刻意保留**：16 个测试文件里有 56 处直接构造
/// `QuoteListPage` / 仓库 / 目录，其中 5 个页面测试只传 `serviceBuilder`。
/// 改成必填注入会一次编译失败，且对「生产路径走注入」这个目标没有增益。
///
/// 边界：`QuoteFeed` 不在这里创建——它的 `onQuotes` 回调属于页面状态，
/// 仍由 `QuoteFeeds.create` 在页面里构造。这是最小版与完整版的分界。
class AppDependencies {
  AppDependencies({
    required this.store,
    required this.watchlistRepository,
    required this.symbolDirectory,
    required this.klineLoader,
  });

  final KeyValueStore store;
  final WatchlistRepository watchlistRepository;
  final SymbolDirectory symbolDirectory;
  final KlineLoader klineLoader;

  /// 生产组装：磁盘存档 + 真网目录 + 真网走势。
  ///
  /// 只构造对象、不触发读盘或网络；`path_provider` 平台通道要等页面
  /// `initState` 之后的首帧回调才会用到。
  factory AppDependencies.production() {
    // 两个文件，两种生命周期——这是本节唯一需要解释的决定：
    //
    // | 内容 | 生命周期取决于 | 文件名 |
    // | --- | --- | --- |
    // | 订阅列表（用户数据） | 用户 | `user_state.json`（与数据源无关） |
    // | 股票目录缓存（派生数据） | 数据源格式 | `${QuoteFeeds.id}_state.json` |
    //
    // 原来两者同住 `${QuoteFeeds.id}_state.json`：换主力源＝换文件名＝
    // 读不到自选，且没有任何提示（`local_store.dart` 的 `fileName` 注释
    // 只为目录缓存的格式隔离辩护，用户数据是被顺带绑上去的）。
    final KeyValueStore userStore = userStoreFile();
    final KeyValueStore sourceCache = sourceCacheFile();
    return AppDependencies(
      store: userStore,
      watchlistRepository: WatchlistRepository(
        userStore,
        // 旧版把自选写在了带源 id 的文件里，这里给它一次迁移的机会
        legacyStore: sourceCache,
      ),
      symbolDirectory: SymbolDirectory(store: sourceCache),
      klineLoader: KlineLoader(),
    );
  }

  /// 用户数据文件（自选列表）：**不带**数据源 id。
  static KeyValueStore userStoreFile() =>
      FileKeyValueStore(fileName: 'user_state.json');

  /// 派生数据文件（股票目录缓存）：带数据源 id，换源不读旧格式。
  static KeyValueStore sourceCacheFile() => FileKeyValueStore();
}
