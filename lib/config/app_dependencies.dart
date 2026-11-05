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
    final KeyValueStore store = FileKeyValueStore();
    return AppDependencies(
      store: store,
      watchlistRepository: WatchlistRepository(store),
      symbolDirectory: SymbolDirectory(store: store),
      klineLoader: KlineLoader(),
    );
  }
}
