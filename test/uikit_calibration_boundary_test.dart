/// 1.17.0「按原生 UIKit 重新校准」边界守门。
///
/// ## 这一轮到底校准了什么
///
/// 上游 1.17.0 的 CHANGELOG：把 `GlassTabBar` / `GlassSegmentedControl` /
/// `AnimatedGlassIndicator` / `GlassSwitch`（新增 `thumbShadow`）/ `GlassSlider`
/// 五类**交互控件**的镜片折射、色散、镜面高光边缘对齐 UIKit 的 platter /
/// resting well / lifted lens；并让 `GlassSwitch` / `GlassSlider` 只在按下或
/// 拖动时挂 shader 层。实现全部在 `liquid_glass_widgets` 包内，
/// 精确数值与 1.16.1→1.17.0 源码对比见 `tool/probe_uikit_calibration.py`
/// 与 README 二·五十五。
///
/// ## 本工程为什么只有「守门」没有「校准」
///
/// `lib/` 对这五个控件的引用数是 **0**：没有 TabBar、Switch、Slider，
/// 唯一的近似控件是详情弹层自绘的「分时 / 日K」`_Segment`，它是纯
/// `AnimatedContainer`（零玻璃、零 shader、零常驻 GPU）。因此上游这次校准
/// **没有本地对象**，本工程的常驻 GPU 成本仍在 5 张行情卡片的
/// `GlassContainer.card(useOwnLayer: true, quality: premium)` 上——
/// 不能把上游的「省常驻 GPU」记成我们的收益。
///
/// 这些用例守的是三件会静默出错的事：
/// 1. 上游若改掉 `thumbShadow` / 指示器预设 / 静止态短路，升级时能当场发现；
/// 2. 将来谁把五个控件之一引进 `lib/`，必须同步走玻璃升级 SOP
///    （`docs/dep-liquid-glass.md` 第四节）、重跑 5 张 golden 与真机走查；
/// 3. 卡片那条真正吃 GPU 的 premium 路径不要被误当成可省的常驻层删掉。
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 五个被 1.17.0 重新校准的交互控件（同时是「引入即触发 SOP」的名单）。
const List<String> _controls = <String>[
  'GlassTabBar',
  'GlassSegmentedControl',
  'AnimatedGlassIndicator',
  'GlassSwitch',
  'GlassSlider',
];

/// 匹配「被实例化」，不匹配文档注释里的类名，也不匹配 `import`。
final RegExp _usage = RegExp(
  r'\b(?:GlassTabBar|GlassSegmentedControl|AnimatedGlassIndicator|'
  r'GlassSwitch|GlassSlider)\s*(?:\.|\()',
);

void _sinkBool(bool _) {}

void _sinkDouble(double _) {}

/// 解析已安装包根目录：从 `.dart_tool/package_config.json` 取 rootUri。
///
/// 不用硬编码 pub cache 路径（换镜像源 pub.dev / pub.flutter-io.cn 或换机器
/// 都会假红）。**也不用 `Isolate.resolvePackageUri`**：flutter_tester 沙箱里
/// 它抛 `Unsupported operation: Isolate.resolvePackageUriSync`（实测），
/// 守门测试要能在 CI 的逻辑测试口径下跑。
Directory _glassPackageRoot() {
  final File cfg = File('.dart_tool/package_config.json');
  if (!cfg.existsSync()) {
    throw StateError('缺少 .dart_tool/package_config.json；先跑 flutter pub get');
  }
  final RegExp pattern = RegExp(
    r'"name"\s*:\s*"liquid_glass_widgets"\s*,\s*"rootUri"\s*:\s*"([^"]+)"',
  );
  final Match? match = pattern.firstMatch(cfg.readAsStringSync());
  if (match == null) {
    throw StateError('package_config.json 里找不到 liquid_glass_widgets');
  }
  final String uri = match.group(1)!;
  if (!uri.startsWith('file:///')) {
    return Directory(uri);
  }
  // Windows: file:///C:/... -> C:/...；POSIX: file:///home/... -> /home/...
  return Directory(
    RegExp(r'^file:///[A-Za-z]:/').hasMatch(uri)
        ? uri.substring(8)
        : uri.substring(7),
  );
}

/// 扫 [root] 下所有 `.dart` 的**代码行**，返回五控件被使用的位置。
List<String> findControlUsages(Directory root) {
  if (!root.existsSync()) {
    return <String>[];
  }
  final List<String> hits = <String>[];
  for (final FileSystemEntity entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) {
      continue;
    }
    for (final String raw in entity.readAsLinesSync()) {
      final String line = raw.trimLeft();
      if (line.startsWith('//') ||
          line.startsWith('*') ||
          line.startsWith('/*')) {
        continue;
      }
      if (_usage.hasMatch(line)) {
        hits.add('${entity.path.replaceAll(r'\', '/')}: ${raw.trim()}');
      }
    }
  }
  hits.sort();
  return hits;
}

String _readGlassSource(Directory root, String relative) {
  final File file = File('${root.path}/$relative');
  expect(file.existsSync(), isTrue, reason: '包源码缺文件：$relative');
  return file.readAsStringSync();
}

void main() {
  test('GlassSwitch / GlassSlider 都暴露 thumbShadow（1.17.0 新增前者）', () {
    // 这两个构造调用本身就是编译期钉子：上游删掉 thumbShadow 会直接编译失败。
    // 传空列表是上游约定的「禁用静止投影」写法。
    const GlassSwitch sw = GlassSwitch(
      value: true,
      onChanged: _sinkBool,
      thumbShadow: [],
    );
    const GlassSlider sl = GlassSlider(
      value: 0.5,
      onChanged: _sinkDouble,
      thumbShadow: [],
    );
    expect(sw.thumbShadow, isEmpty);
    expect(sl.thumbShadow, isEmpty);
  });

  test('指示器基准 ios27Indicator：清透近轴透镜的折射/边缘高光数值', () {
    final LiquidGlassSettings s = AnimatedGlassIndicator.baseIndicatorSettings;
    // blur / frost 必须为 0：指示器药丸是折射透镜，套 BackdropFilter 会
    // 让它采样已模糊的合成图，SDF 描边和镜面高光全毁。
    expect(s.blur, 0);
    expect(s.frost, 0);
    expect(s.thickness, 28);
    expect(s.refractiveIndex, 1.17);
    expect(s.chromaticAberration, 0);
    expect(s.lensModel, GlassLensModel.paraxial);
    expect(s.rimShade, 1.0);
    expect(s.rimShadeEnds, 0.56);
    expect(s.rimLight, 1.0);
    expect(s.lightAngle, closeTo(math.pi / 2, 1e-9));
    expect(s.lightIntensity, 0);
    expect(s.glassColor.a, 0);
    // 1.17.0 的 breaking：省略 indicatorSettings 时默认就是这一套，
    // 不再是 classicIndicator 的球形药丸。
    expect(
      s.refractiveIndex,
      LiquidGlassSettings.ios27Indicator.refractiveIndex,
    );
    expect(
      s.refractiveIndex,
      isNot(LiquidGlassSettings.classicIndicator.refractiveIndex),
      reason: '如果又变回 classic 基准，说明上游撤销了 ios27 指示器校准',
    );
  });

  test('静止态不挂 shader 层：GlassEffect 的 interactionIntensity 闸门仍在', () {
    final Directory root = _glassPackageRoot();
    final String src = _readGlassSource(
      root,
      'lib/widgets/shared/glass_effect.dart',
    );
    expect(
      src.contains('if (activeIntensity <= 0.001) {'),
      isTrue,
      reason: '1.16.1 无此分支、恒挂 LiquidGlass.withOwnLayer；'
          '被删掉意味着 Switch/Slider 又开始常驻占用一层 backdrop filter',
    );
    expect(src.contains('return widget.child;'), isTrue);
    // 挂上之后，折射/边缘强度按交互强度从 1.0 / 0 线性抬起，而不是全量常驻。
    expect(
      src.contains(
        '1.0 + (widget.settings.refractiveIndex - 1.0) * activeIntensity',
      ),
      isTrue,
    );
    expect(src.contains('LiquidGlass.withOwnLayer('), isTrue);
  });

  test('Switch / Slider 的 shader 强度由按下 / 拖动动画驱动', () {
    final Directory root = _glassPackageRoot();
    for (final String relative in <String>[
      'lib/widgets/interactive/glass_switch.dart',
      'lib/widgets/interactive/glass_slider.dart',
    ]) {
      final String src = _readGlassSource(root, relative);
      expect(
        src.contains('interactionIntensity: transition'),
        isTrue,
        reason: '$relative 不再把交互强度喂给 GlassEffect，静止态短路会失效',
      );
      expect(src.contains('_thicknessAnimation.value'), isTrue);
      expect(src.contains('mounts zero shader layers at rest'), isTrue);
      expect(src.contains('final List<BoxShadow>? thumbShadow;'), isTrue);
    }
  });

  test('本工程 lib/ 零引用这五个控件（引入必须同步走玻璃 SOP）', () {
    expect(
      findControlUsages(Directory('lib')),
      isEmpty,
      reason: '五控件都已校准到 UIKit 的 premium 折射镜片，'
          'flutter_tester 无 Impeller 验不了光学；引入任一控件都要按 '
          'docs/dep-liquid-glass.md 第四节重跑 5 张 golden + 真机玻璃走查，'
          '并把 README 二·五十五 的「零曝光」结论改写。',
    );
  });

  test('扫描器不是摆设：能点名违规、放过注释和无关命名', () {
    final Directory tmp = Directory.systemTemp.createTempSync('uikit_boundary_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    File('${tmp.path}/bad.dart').writeAsStringSync(
      "import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';\n"
      '// 注释里提到 GlassSwitch( 不算数\n'
      'const widget = GlassSwitch(value: true, onChanged: f);\n'
      'final bar = GlassTabBar.bottom(tabs: []);\n',
    );
    File('${tmp.path}/ok.dart').writeAsStringSync(
      'const String label = "GlassSlider";\n'
      'final bool useGlassSwitch = false;\n',
    );
    final List<String> hits = findControlUsages(tmp);
    expect(hits, hasLength(2), reason: '两个真实实例化都要被抓到');
    expect(hits.every((String h) => h.contains('bad.dart')), isTrue);
    expect(_controls.length, 5);
  });

  test('常驻 GPU 成本在卡片，不在交互控件：卡片仍是 premium + useOwnLayer', () {
    final String src = File('lib/widgets/quote_tile.dart').readAsStringSync();
    expect(src, contains('GlassContainer.card('));
    expect(src, contains('useOwnLayer: true'));
    expect(src, contains('quality: GlassQuality.premium'));
    // 唯一的近似分段控件零玻璃、零 shader，本来就不吃常驻 GPU。
    final String detail =
        File('lib/widgets/quote_detail_sheet.dart').readAsStringSync();
    expect(detail, contains('class _Segment'));
    expect(detail, contains('AnimatedContainer('));
  });
}
