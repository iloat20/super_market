import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// liquid_glass_widgets 版本守门（docs/dep-liquid-glass.md 第四节 SOP）。
///
/// 哲学与 `tool/verify_apk.py` 钉 EXPECT_TARGET_SDK 相同：**谁动了它，
/// 必须当场暴露**。这是台账钉子、不是行为修复——建立时就是绿的，
/// 没有红态可留；「漂移必红」由第二条合成用例作等价证据。
///
/// 看到第一条测试红（比如跑过 `flutter pub upgrade`）意味着：玻璃包换了
/// 版本，而 premium 档的折射/rim/色散只有真机能验（flutter_tester 无
/// Impeller）。按 docs/dep-liquid-glass.md 第四节走完升级 SOP（含真机
/// 玻璃走查）后，改下面的常量并更新台账「版本履历」，测试才重新变绿。
const String _pinnedLiquidGlass = '1.17.0';

/// 从 pubspec.lock 的行里定点解析某包的锁定版本；找不到返回 null。
///
/// 不为这个钉子引入 yaml 解析依赖（它是传递依赖，直接 import 会触
/// depend_on_referenced_packages lint）。解析规则：锁定 `  <包名>:`（2 空格
/// 缩进的包键）之后的第一个 `    version:`（4 空格缩进的字段）。包的字段
/// 块（dependency/description/name/sha256/url/source）里没有嵌套 version，
/// 下一个包的 version 也不会先于它出现——首个命中即目标。
String? _lockedVersion(List<String> lines, String package) {
  final int keyAt = lines.indexWhere(
    (String line) => line == '  $package:',
  );
  if (keyAt < 0) {
    return null;
  }
  for (int i = keyAt + 1; i < lines.length; i++) {
    final String line = lines[i];
    // 2 空格缩进的新包键：还没读到 version 就到了下一个包，视为结构异常
    if (line.length > 2 &&
        !line.startsWith('    ') &&
        line.trim().endsWith(':')) {
      return null;
    }
    if (line.startsWith('    version:')) {
      final List<String> parts = line.split('"');
      return parts.length > 1 ? parts[1] : line.substring('    version:'.length).trim();
    }
  }
  return null;
}

void main() {
  test('liquid_glass_widgets 锁定在台账钉住的版本', () {
    final String? version = _lockedVersion(
      File('pubspec.lock').readAsLinesSync(),
      'liquid_glass_widgets',
    );
    expect(version, isNotNull, reason: '玻璃包从 lock 里消失了——依赖被移除？');
    expect(
      version,
      _pinnedLiquidGlass,
      reason: '玻璃包版本漂移（$_pinnedLiquidGlass → $version）。'
          '按 docs/dep-liquid-glass.md 第四节走完升级 SOP（含真机玻璃走查），'
          '再把 _pinnedLiquidGlass 改为新版本。',
    );
  });

  // 红态等价证据：合成一份「升到 1.18.0」的 lock，解析出的版本不等于钉子
  // ——证明任何漂移都会让第一条测试当场变红，守门不是摆设。
  test('合成漂移：lock 里版本变了必须能被解析出来（守门必红）', () {
    const String driftedLock = '''
packages:
  liquid_glass_widgets:
    dependency: "direct main"
    description:
      name: liquid_glass_widgets
      sha256: "0000"
      url: "https://pub.dev"
    source: hosted
    version: "1.18.0"
  some_other_package:
    dependency: transitive
    description:
      name: some_other_package
    source: hosted
    version: "9.9.9"
''';
    final String? version = _lockedVersion(
      driftedLock.split('\n'),
      'liquid_glass_widgets',
    );
    expect(version, '1.18.0');
    expect(version, isNot(_pinnedLiquidGlass),
        reason: '漂移版本 ≠ 钉子 → 第一条测试会红，SOP 被强制触发');
  });

  test('包被移除 / 结构异常时解析为 null（第一条测试的「依赖被移除」分支）', () {
    const String noGlass = '''
packages:
  some_other_package:
    dependency: transitive
    version: "9.9.9"
''';
    expect(_lockedVersion(noGlass.split('\n'), 'liquid_glass_widgets'), isNull);
  });
}
