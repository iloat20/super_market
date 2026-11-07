/// R8 配置边界守门：把 Android 17 官方建议的三条构建配置钉成断言。
///
/// ## 为什么需要这么一条测试
///
/// 2026-11-07 核过 [Android 17 内存效率指南](https://developer.android.com/about/versions/17/behavior-changes-all)
/// 与 Monzo 案例后确认：本项目 `isMinifyEnabled` / `isShrinkResources` /
/// `proguard-android-optimize.txt` / Full Mode 默认开，四项**已经全对**。
/// 危险的不是「没配」，而是后续有人按一篇过时教程「帮忙修正」：
/// 把 optimize 文件换回 legacy、或在 gradle.properties 里加一行
/// `android.enableR8.fullMode=false`——两者都不会让 `flutter analyze` 变红，
/// 只会让 release 包悄悄退回兼容模式（实测 dex +76 248 B，README 二·四十九）。
///
/// 这条测试把「无声回退」变成「当场变红」。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 会让 R8 对整个代码库停手的全局选项（官方明确要求移除）。
const List<String> _globalBlockers = <String>[
  '-dontoptimize',
  '-dontshrink',
  '-dontobfuscate',
];

/// 扫 [root] 下所有 `.pro` / consumer `proguard.txt`，返回命中的全局禁用项。
///
/// 只按行首匹配：注释里写「不要加 -dontoptimize」不该被算成违规。
List<String> findGlobalOptimizationBlockers(Directory root) {
  if (!root.existsSync()) {
    return <String>[];
  }
  final List<String> hits = <String>[];
  for (final FileSystemEntity entity in root.listSync(recursive: true)) {
    if (entity is! File ||
        !(entity.path.endsWith('.pro') || entity.path.endsWith('proguard.txt'))) {
      continue;
    }
    for (final String raw in entity.readAsLinesSync()) {
      final String line = raw.trimLeft();
      for (final String blocker in _globalBlockers) {
        if (line.startsWith(blocker)) {
          hits.add('${entity.path.replaceAll(r'\', '/')}: $line');
        }
      }
    }
  }
  hits.sort();
  return hits;
}

void main() {
  test('release 必须用 proguard-android-optimize.txt，不是 legacy 版', () {
    final String gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(
      gradle.contains('proguard-android-optimize.txt'),
      isTrue,
      reason: 'legacy 的 proguard-android.txt 内含 -dontoptimize，会把 R8 的'
          '优化整段关掉；AGP 9 起该文件也不再受支持。',
    );
    // 注意：optimize 文件名本身不含 "proguard-android.txt" 这个子串，
    // 所以下面这条不会误伤。
    expect(
      gradle.contains('proguard-android.txt'),
      isFalse,
      reason: '有人在 release 配置里写回了旧的默认 ProGuard 文件。',
    );
  });

  test('gradle.properties 不许出现 android.enableR8.fullMode', () {
    final String props = File('android/gradle.properties').readAsStringSync();
    expect(
      props.contains('enableR8.fullMode'),
      isFalse,
      reason: 'R8 Full Mode 从 AGP 8 起默认开启；这个属性现在只能用来「关掉它」。'
          '写 =true 是误导，写 =false 会让 dex 涨 76 KB（README 二·四十九）。',
    );
  });

  test('仓库自带的 keep 规则里没有全局禁用优化选项', () {
    expect(
      findGlobalOptimizationBlockers(Directory('android')),
      isEmpty,
      reason: '全局 -dontoptimize / -dontshrink / -dontobfuscate 会让整个'
          '代码库退出优化，见官方「Keep 规则最佳实践」。',
    );
  });

  test('扫描器不是摆设：合成目录里的三种禁用项都要被点名', () {
    final Directory tmp = Directory.systemTemp.createTempSync('r8_boundary_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    File('${tmp.path}/rules.pro').writeAsStringSync(
      '# 注释里提到 -dontoptimize 不算数\n'
      '-dontoptimize\n'
      '  -dontshrink\n',
    );
    File('${tmp.path}/nested/proguard.txt')
      ..createSync(recursive: true)
      ..writeAsStringSync('-dontobfuscate\n');
    File('${tmp.path}/ok.pro').writeAsStringSync('-keep class io.flutter.** { *; }\n');

    expect(findGlobalOptimizationBlockers(tmp), hasLength(3));
  });
}
