/// 原生日志 tag 守门：一个 App 只准有一个原生 tag，且必须等于 applicationId。
///
/// ## 为什么需要这么一条测试
///
/// 2026-11-06 包名从 `supermarket.app` 迁到 `app.supermarket` 时，Kotlin 侧的
/// `Log.i("super_market", ...)` 没跟着改；后来接 ADPF 又照抄了一遍旧 tag
/// （`AdpfSession.kt`）。结果 `adb logcat | grep app.supermarket` 抓不到原生日志，
/// 而 `tool/measure_frames.sh`、README 的验法、Android 17 对齐文档都还写着
/// `-s super_market`——排障时要记包名和 tag 两个词，改一处漏三处。
///
/// 这条测试把「再次漂移」变成当场变红：tag 常量只有一个定义点，所有 `Log.*`
/// 必须引用它，且值必须与 `applicationId` 相等；脚本与当前文档不许再提旧 tag。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _kotlinDir = 'android/app/src/main/kotlin/app/supermarket';
const String _gradle = 'android/app/build.gradle.kts';

String _read(String path) => File(path).readAsStringSync();

/// 从 build.gradle.kts 读唯一真相源，避免测试里再抄一遍包名。
String applicationId() {
  final Match? hit = RegExp(r'applicationId\s*=\s*"([^"]+)"')
      .firstMatch(_read(_gradle));
  if (hit == null) {
    fail('$_gradle 里找不到 applicationId，无法确定日志 tag 应该是什么');
  }
  return hit.group(1)!;
}

List<File> kotlinSources() => Directory(_kotlinDir)
    .listSync()
    .whereType<File>()
    .where((File f) => f.path.endsWith('.kt'))
    .toList();

void main() {
  test('原生 tag 只有一个定义点，且等于 applicationId', () {
    final String id = applicationId();
    final String logTag = _read('$_kotlinDir/LogTag.kt');
    expect(logTag, contains('const val LOG_TAG = "$id"'));
    expect(
      RegExp(r'const val LOG_TAG').allMatches(logTag).length,
      1,
      reason: 'tag 只准在 LogTag.kt 定义一次，别的文件一律引用',
    );
  });

  test('所有 Log.* 都用 LOG_TAG，源码里没有写死的旧 tag', () {
    final List<File> files = kotlinSources();
    expect(files.length, greaterThanOrEqualTo(3), reason: '扫描本身不能是空转');
    for (final File f in files) {
      final String src = f.readAsStringSync();
      final String name = f.path.replaceAll(r'\', '/').split('/').last;
      expect(
        src.contains('"super_market"'),
        isFalse,
        reason: '$name 里还有旧 tag 字面量，统一走 LOG_TAG',
      );
      for (final Match m in RegExp(r'Log\.[idwe]\(\s*([^,\n]+)').allMatches(src)) {
        expect(
          m.group(1)!.trim(),
          'LOG_TAG',
          reason: '$name 的 ${m.group(0)} 没有用统一常量',
        );
      }
    }
  });

  test('抓日志的脚本与当前文档不再指向旧 tag', () {
    final String script = _read('tool/measure_frames.sh');
    expect(script.contains('super_market'), isFalse,
        reason: '脚本还按旧 tag 过滤，改完 tag 就抓不到 refresh: 行了');
    expect(script.contains('-s "\$PKG"'), isTrue,
        reason: 'tag 与 applicationId 相同，直接复用 PKG 才不会再漂');

    final String readme = _read('README.md');
    final String row = readme.split('\n').firstWhere(
          (String l) => l.startsWith('| 日志 tag |'),
          orElse: () => '',
        );
    expect(row, contains('app.supermarket'));
    expect(row.contains('super_market'), isFalse);

    expect(
      _read('docs/ANDROID17-ALIGNMENT-2026-11-07.md')
          .contains('logcat -s super_market'),
      isFalse,
    );
  });
}
