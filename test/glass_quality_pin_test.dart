import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// `main()` 全局玻璃配置的「钉子」测试。
///
/// 与 `test/dependency_pin_test.dart` 同一路数：配置写错不会让任何 widget
/// 测试变红（flutter_tester 没有 Impeller，premium 走降级路径），只有真机上
/// 才表现为「玻璃突然变成白板」，而那种回退靠肉眼很难归因。所以这里直接
/// 把 `lib/main.dart` 的源码当契约读一遍。
///
/// 背景：`adaptiveQuality: true` 会插入 root `GlassAdaptiveScope`，它是
/// **全局质量上限**，连 `quality: GlassQuality.premium` 这种显式声明也会被
/// 压下去（包内 `glass_theme_helpers.dart` 的解析优先级注释）。本应用卡片
/// 与订阅弹层都显式写了 premium，且整套 `kGlassSurface` 是照 iOS 27
/// premium 档逐项调的，因此自适应必须开着、但自由度必须全部关掉。
void main() {
  test('main.dart 开 adaptiveQuality，且把质量档钉死在 premium', () {
    final String source = File('lib/main.dart').readAsStringSync();

    expect(
      source,
      contains('adaptiveQuality: true'),
      reason: '全局初始化清单要求开启设备性能自适应',
    );
    expect(
      source,
      contains('adaptiveConfig: kGlassAdaptiveConfig'),
      reason: '不能裸开自适应：默认配置会在首帧/预热期把 premium 压到 standard',
    );

    final Match? config = RegExp(r'GlassAdaptiveScopeConfig\(([\s\S]*?)\)')
        .firstMatch(source);
    expect(
      config,
      isNotNull,
      reason: '找不到 GlassAdaptiveScopeConfig 定义，质量档无法被钉住',
    );

    final String body = config!.group(1)!;
    for (final String pin in <String>[
      'minQuality: GlassQuality.premium',
      'maxQuality: GlassQuality.premium',
      'initialQuality: GlassQuality.premium',
      'allowStepUp: false',
    ]) {
      expect(
        body,
        contains(pin),
        reason:
            '缺 $pin：包内 Phase 1 静态探针 / Phase 2 预热 / Phase 3 '
            '运行时迟滞都仍有降档路径，会把 premium 玻璃降级',
      );
    }
  });

  test('全局主题仍是 ios27，没有被 simple(standard) 换掉', () {
    final String source = File('lib/main.dart').readAsStringSync();

    expect(
      source,
      contains('GlassThemeData.ios27()'),
      reason:
          'kGlassSurface / kSheetGlassSurface 的参数基线是 '
          'LiquidGlassSettings.ios27Light，换主题等于整套光学作废',
    );
    expect(
      source,
      isNot(contains('GlassThemeData.simple(')),
      reason: 'simple 工厂会把 light/dark 变体换回包内默认材质',
    );
    expect(
      source,
      contains('brightnessResolver: Theme.maybeBrightnessOf'),
      reason: 'MaterialApp 必须显式桥接 ThemeMode，否则暗色系统下阴影/描边消失',
    );
  });

  /// 下面是两条「行为刻画」用例，守住上面钉子的**前提**：包的行为一旦在
  /// 升级时变了（比如 minQuality 不再兜住静态探针），钉子就失效了。
  /// flutter_tester 是软件渲染器 / Linux target，Phase 1 静态探针必定给出
  /// 一个低档值，正好是验证 `_floorQuality` 是否生效的场景。

  Future<GlassQuality> pinnedCeilingOf(
    WidgetTester tester, {
    GlassAdaptiveScopeConfig? config,
  }) async {
    GlassQuality? observed;
    await tester.pumpWidget(
      LiquidGlassWidgets.wrap(
        adaptiveQuality: true,
        adaptiveConfig: config,
        child: Builder(
          builder: (BuildContext context) {
            observed = GlassAdaptiveScopeData.of(context).effectiveQuality;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    // 静态探针的降档经 postFrameCallback → setState 落地，首帧仍是
    // initState 播种的 maxQuality；多泵一帧才能读到探针后的稳态。
    await tester.pump();
    return observed!;
  }

  testWidgets('对照组：裸开自适应（不传 config）会把质量上限压低', (WidgetTester tester) async {
    // 这条是「为什么必须钉」的可执行证据：默认配置下静态探针会在第二帧
    // 给出低于 premium 的档位。若哪天它变成 premium，说明上游改了策略，
    // 下面的钉住用例仍然要绿，但 main.dart 里的注释需要同步修订。
    final GlassQuality quality = await pinnedCeilingOf(tester);
    expect(quality, isNot(GlassQuality.premium));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  });

  testWidgets('钉住 premium 的配置连静态探针的强制降档也兜得住', (WidgetTester tester) async {
    final GlassQuality quality = await pinnedCeilingOf(
      tester,
      config: const GlassAdaptiveScopeConfig(
        minQuality: GlassQuality.premium,
        maxQuality: GlassQuality.premium,
        initialQuality: GlassQuality.premium,
        allowStepUp: false,
      ),
    );
    expect(
      quality,
      GlassQuality.premium,
      reason:
          'minQuality 必须把 Phase 1 的 forced 值兜回 premium，'
          '否则 kGlassSurface 的 iOS 27 光学会在首帧就退化',
    );
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  });
}
