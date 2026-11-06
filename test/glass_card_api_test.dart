import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 卡片玻璃 API 契约（第二步口径复核后的钉子）。
///
/// 与 `dependency_pin_test.dart` / `glass_quality_pin_test.dart` 同一路数：
/// 这类配置错误在 flutter_tester 里不会让任何 widget 用例变红（无 Impeller、
/// premium 走降级路径），只有真机观感 / 升级到 2.0.0 时才会突然炸。
///
/// 背景（读 1.16.1 源码 + 实测）：
/// - 包内**没有** `GlassPanel`，CHANGELOG 里 `GlassPanel` 与 `0.15.0` 均零命中；
///   本工程的 `GlassPanel` 是 `lib/widgets/glass.dart` 自绘的组件，与包版本无关。
/// - `GlassCard` 才是被废弃的那个：`@Deprecated('Use GlassContainer.card
///   instead. Will be removed in 2.0.0.')`。实测引用一次即产生
///   `deprecated_member_use`，破坏「analyze 0 issue」门禁。
/// - `GlassContainer.card` 是非废弃的卡片预设；它把 `surfaceStyle` 暴露出来，
///   而依赖台账已预告 2.0.0 起默认材质会从 glass 翻成 solid，必须显式钉住。
void main() {
  test('列表卡片走非废弃的 GlassContainer.card 预设，光学参数一个不少', () {
    final String tile = File('lib/widgets/quote_tile.dart').readAsStringSync();

    expect(
      tile,
      contains('GlassContainer.card('),
      reason: 'GlassCard 已废弃（2.0.0 移除）且会触发 deprecated_member_use；'
          '卡片预设的正确入口是 GlassContainer.card',
    );
    for (final String pin in <String>[
      'surfaceStyle: GlassSurfaceStyle.glass',
      'quality: GlassQuality.premium',
      'settings: kGlassSurface',
      'useOwnLayer: true',
      'shape: const LiquidRoundedSuperellipse(borderRadius: 28)',
      'child: const SizedBox.shrink()',
    ]) {
      expect(
        tile,
        contains(pin),
        reason: '缺 $pin：换成卡片预设不能顺手丢掉 premium / '
            'kGlassSurface / 内容不进玻璃子树这些既有不变量',
      );
    }
  });

  test('lib/ 下不得出现已废弃的 GlassCard 调用', () {
    final Iterable<File> sources =
        Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((File f) => f.path.endsWith('.dart'));
    expect(sources, isNotEmpty);

    for (final File file in sources) {
      expect(
        file.readAsStringSync(),
        isNot(contains('GlassCard(')),
        reason: '${file.path} 用了 GlassCard：1.16.1 起已废弃、2.0.0 移除，'
            '且 flutter analyze 会报 deprecated_member_use',
      );
    }
  });

  test('GlassPanel 仍是工程自绘组件，不是从玻璃包导入的 API', () {
    final String glass = File('lib/widgets/glass.dart').readAsStringSync();

    expect(
      glass,
      contains('class GlassPanel extends StatelessWidget'),
      reason: 'GlassPanel 是本工程自绘的 BackdropFilter 面板，'
          '不属于 liquid_glass_widgets，因此不受包版本废弃影响',
    );
    expect(glass, contains("import 'glass_rim.dart';"));
    expect(glass, contains('BackdropFilter('));

    final Iterable<File> sources =
        Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((File f) => f.path.endsWith('.dart'));
    for (final File file in sources) {
      expect(
        file.readAsStringSync(),
        isNot(contains('show GlassPanel')),
        reason: '${file.path} 把 GlassPanel 当成包 API 导入了',
      );
    }
  });
}
