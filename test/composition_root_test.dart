import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/config/app_dependencies.dart';
import 'package:super_market/services/local_store.dart';

/// A11 最小版（S3b）：组合根必须上移到 `main()`。
///
/// 这是**静态架构不变量**，不是行为测试：钉住「生产路径显式组装并下发依赖」，
/// 防止页面继续靠 `??` 自造数据层对象。保留 `??` 兜底是刻意的——
/// 16 个测试文件里 56 处构造调用依赖它，改成 required 会一次编译失败 5 处。
///
/// 红态（实施前）：`main.dart` 只有 `const QuoteListPage()`、
/// 没有 AppDependencies、页面没有 klineLoader 通道。
/// 行为正确性由全量 `flutter test`（页面注入路径的既有 128 个用例）收口。

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('组合根：main() 显式组装依赖并下发给 App', () {
    final String main = _read('lib/main.dart');
    expect(main, contains('AppDependencies.production()'),
        reason: 'main() 必须成为组合根，而不是让页面自己 ?? 造数据层对象');
    expect(main, contains('SuperMarketApp(dependencies: deps'),
        reason: '组装好的依赖必须显式传给 App');
    expect(main, contains('klineLoader: dependencies.klineLoader'),
        reason: 'KlineLoader 也要由组合根下发，弹层不应再 new 一个');
  });

  test('页面：详情弹层使用注入的 KlineLoader', () {
    final String page = _read('lib/pages/quote_list_page.dart');
    expect(page, contains('loader: widget.klineLoader'),
        reason: '打开详情弹层时必须把注入的 loader 传下去');
  });

  test('依赖容器：用户数据与目录缓存必须是**两个**文件', () {
    // R-02 的原始教训是「两个实例各持内存缓存写同一个文件会互相抹 key」。
    // 当时的修法是「共享同一个实例 + 同一个文件」——副作用是用户数据
    // （自选）与派生数据（目录缓存）被绑在同一条生命周期上：文件名带
    // 数据源 id，一旦按文档调换主备，自选静默回到默认列表。
    //
    // 现在改为「两个文件」：跨实例互相抹 key 的前提随之消失（不同文件），
    // 而自选的生命周期不再随数据源变。这条断言守的就是这个分工。
    final KeyValueStore user = AppDependencies.userStoreFile();
    final KeyValueStore cache = AppDependencies.sourceCacheFile();
    expect(
      identical(user, cache),
      isFalse,
      reason: '自选是用户数据、目录是派生缓存，生命周期不同，不能共用一个文件',
    );
    expect(
      identical(user, AppDependencies.userStoreFile()),
      isTrue,
      reason: '同一文件名必须命中实例池，否则又回到「两份内存缓存写同一个文件」',
    );
  });

  test('依赖容器：订阅仓库带旧文件迁移入口', () {
    final String src = _read('lib/config/app_dependencies.dart');
    expect(
      src,
      contains('legacyStore: sourceCache'),
      reason: '升级后必须把旧文件名里的自选搬过来，'
          '否则「修换源丢自选」这个动作本身又丢一次自选',
    );
  });
}
