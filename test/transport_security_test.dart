import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/services/rest_client.dart';

/// 传输层"只走 TLS"的守门测试（ROADMAP §4.3）。
///
/// 为什么需要这一层：`network_security_config.xml` 是**给原生 HTTP 栈**看的，
/// 而本 App 的行情请求走 `dart:io` 的 HttpClient（自带 BoringSSL + 裸 socket），
/// 不经过 Android 的 NetworkSecurityPolicy。所以"只走 TLS"真正能被强制的
/// 位置只有传输层本身——就是这里断言的那个函数。
///
/// 四类断言：
/// 1. 闸门本身：https 放行、其余 scheme 一律抛；
/// 2. 静态扫描：`lib/` 下不允许出现 `http://` 字面量（防止将来加源时写错）；
/// 3. 配置层：Manifest 真的挂上了 networkSecurityConfig；
/// 4. 配置内容：那份 XML 真的禁了明文（不是挂了个空文件）。
void main() {
  group('requireHttps 闸门', () {
    test('https 放行，且返回同一实例（不复制、不改写）', () {
      final Uri uri = Uri.parse('https://hq.sinajs.cn/list=sz000001');
      expect(identical(requireHttps(uri), uri), isTrue);
    });

    test('http 一律拒绝', () {
      expect(
        () => requireHttps(Uri.parse('http://hq.sinajs.cn/list=sz000001')),
        throwsA(
          isA<ArgumentError>().having(
            (ArgumentError e) => e.message,
            'message',
            contains('只允许 https'),
          ),
        ),
      );
    });

    test('非 http(s) 的 scheme 也拒绝（ws / ftp / file 都不是 TLS）', () {
      for (final String raw in <String>[
        'ws://qt.gtimg.cn/q=sz000001',
        'ftp://example.com/a',
        'file:///etc/hosts',
      ]) {
        expect(
          () => requireHttps(Uri.parse(raw)),
          throwsA(isA<ArgumentError>()),
          reason: '$raw 不应被放行',
        );
      }
    });

    test('解析失败的相对 Uri（没有 scheme）拒绝', () {
      expect(() => requireHttps(Uri.parse('/list=sz000001')), throwsA(
        isA<ArgumentError>(),
      ));
    });
  });

  group('lib/ 下不允许明文 URL 字面量', () {
    test('全部 Dart 源码里没有 http:// 字面量', () {
      final List<String> offenders = _scanCleartextLiterals(Directory('lib'));
      expect(
        offenders,
        isEmpty,
        reason: '发现明文 URL：\n${offenders.join('\n')}\n'
            '行情源必须用 Uri.https(...)；确需明文请先改这条守门测试并说明理由。',
      );
    });

    // 红态等价证据：把同一套扫描逻辑喂给一段含 http:// 的合成代码，
    // 必须能抓出来——证明上一条测试不是"永远绿"的摆设。
    test('合成反例：扫描器能抓到 http://（守门必红）', () {
      final List<String> hit = _scanLines(<String>[
        "Uri.parse('https://ok.example.com');",
        "Uri.parse('http://bad.example.com');",
        '/// 文档里提到 http:// 不算违规（整行注释）',
        '// 同样不算',
      ]);
      expect(hit.length, 1);
      expect(hit.single, contains('bad.example.com'));
    });
  });

  group('Android 侧配置', () {
    test('Manifest 挂上了 networkSecurityConfig', () {
      final String manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(
        manifest,
        contains('android:networkSecurityConfig="@xml/network_security_config"'),
        reason: '配置写了但没挂到 <application>，等于没写',
      );
    });

    test('network_security_config.xml 明确禁止明文', () {
      final File config = File(
        'android/app/src/main/res/xml/network_security_config.xml',
      );
      expect(config.existsSync(), isTrue, reason: '配置文件不存在');

      // 去掉 XML 注释再判断：注释里写 "cleartextTrafficPermitted" 不该被当成生效配置
      final String body = config
          .readAsStringSync()
          .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');

      expect(
        RegExp(r'cleartextTrafficPermitted\s*=\s*"false"').hasMatch(body),
        isTrue,
        reason: '没有显式声明 cleartextTrafficPermitted="false"',
      );
      expect(
        RegExp(r'cleartextTrafficPermitted\s*=\s*"true"').hasMatch(body),
        isFalse,
        reason: '有任何一个域开了明文，就不是"只走 TLS"',
      );
    });
  });
}

/// 扫描目录下所有 Dart 文件，返回含明文 `http://` 的行（跳过整行注释）。
List<String> _scanCleartextLiterals(Directory dir) {
  final List<String> hits = <String>[];
  for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) {
      continue;
    }
    final List<String> lines = entity.readAsLinesSync();
    for (final String hit in _scanLines(lines)) {
      hits.add('${entity.path}: $hit');
    }
  }
  return hits;
}

/// 单文件级扫描规则：整行 `//` 注释豁免（文档里讨论明文是合法的），
/// 其余出现 `http://` 即违规。抽成独立函数是为了能用合成输入验证它。
List<String> _scanLines(List<String> lines) {
  final RegExp cleartext = RegExp(r'http://');
  return <String>[
    for (final String line in lines)
      if (!line.trimLeft().startsWith('//') && cleartext.hasMatch(line))
        line.trim(),
  ];
}
