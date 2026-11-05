import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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

  test('依赖容器：仓库与目录共享同一个 store 实例', () {
    final File file = File('lib/config/app_dependencies.dart');
    expect(file.existsSync(), isTrue,
        reason: 'R-02 的实例池修复要求 repo 与 directory 用同一 store');
    final String src = file.readAsStringSync();
    expect(src, contains('WatchlistRepository(store)'));
    expect(src, contains('SymbolDirectory(store: store)'));
  });
}
