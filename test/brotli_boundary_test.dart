/// 内容编码边界守门：把「传输层只用 dart:io 默认的 gzip」钉成断言。
///
/// ## 为什么需要这么一条测试
///
/// 2026-11-07 用 `tool/probe_brotli.sh` 探过 11 个真实业务端点：
/// **11 个支持 gzip（App 现在已经在自动享受）、0 个支持 br**；
/// 只声明 `br` 时全部退回明文，线上字节数从 65 361B 涨到 197 661B。
/// 而 `dart:io` 的 `_getCompressionState` 只认 `Content-Encoding: gzip`，
/// 别的编码一律 `notCompressed`——真有服务端回了 br，Dart 会把**压缩字节原样**
/// 交给 GBK 解析器（`tool/brotli_client_probe_test.dart` 用 cloudflare 实测过）。
///
/// 危险的不是「没加 br」，而是后续有人按通用教程「帮忙优化」：
/// 在 `requestHeaders()` 里加一行 `Accept-Encoding: br`，或把
/// `autoUncompress` 关掉。两者都不会让 `flutter analyze` 变红，
/// 前者让每轮报价悄悄退回明文、将来还可能喂进乱码，后者直接丢掉现有压缩。
///
/// 这条测试把「无声回退 / 静默乱码」变成「当场变红」。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 传输层里**不该出现**的编码相关写法。
///
/// 只匹配「写代码」的行：注释里讨论 `Accept-Encoding` 是文档，不算违规。
/// 故意**不收**裸 `'br'` 字面量——将来 `lib/` 里出现一个叫 `br` 的变量、
/// 缩写或颜色值是正常的，宽匹配会制造假红。真要设这个请求头，绕不开
/// `acceptEncodingHeader` / `accept-encoding` / `brotli` 三者之一。
/// 全部小写：下面用 `line.toLowerCase().contains(marker)` 比较。
/// 写成混合大小写会让 `acceptEncodingHeader` 永远命不中——自证测试抓到过一次。
const List<String> _forbidden = <String>[
  'acceptencodingheader',
  'accept-encoding',
  'brotli',
];

/// 扫 [root] 下所有 `.dart`，返回疑似手工改写内容编码的行。
List<String> findEncodingOverrides(Directory root) {
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
      final String lower = line.toLowerCase();
      for (final String marker in _forbidden) {
        if (lower.contains(marker)) {
          hits.add('${entity.path.replaceAll(r'\', '/')}: ${raw.trim()}');
          break;
        }
      }
    }
  }
  hits.sort();
  return hits;
}

void main() {
  test('运行时代码不许手工设置 Accept-Encoding / 引入 br', () {
    expect(
      findEncodingOverrides(Directory('lib')),
      isEmpty,
      reason:
          'dart:io 默认发 Accept-Encoding: gzip 并透明解压；手工设 br 会顶掉'
          '默认头（11/11 端点实测退回明文），且 SDK 没有 br 解码器，'
          '真收到 br 时会把压缩字节交给 GBK 解析器。见 README 二·五十一。',
    );
  });

  test('不许关掉 autoUncompress', () {
    final String rest = File('lib/services/rest_client.dart')
        .readAsStringSync();
    // 只看代码行：注释里解释 autoUncompress 不算数。
    final Iterable<String> codeLines = rest
        .split('\n')
        .map((String l) => l.trimLeft())
        .where(
          (String l) =>
              !l.startsWith('//') && !l.startsWith('*') && !l.startsWith('/*'),
        );
    expect(
      codeLines.where((String l) => l.contains('autoUncompress')),
      isEmpty,
      reason:
          '关掉 autoUncompress 会让所有响应变成原始 gzip 字节，'
          '解析器拿不到文本；默认值 true 才是本项目依赖的行为。',
    );
  });

  test('扫描器不是摆设：能点名违规，且放过注释与无关的 br 字面量', () {
    final Directory tmp = Directory.systemTemp.createTempSync('br_boundary_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    File('${tmp.path}/bad.dart').writeAsStringSync(
      "import 'dart:io';\n"
      '// 注释里提到 Accept-Encoding: br 不算数\n'
      "req.headers.set(HttpHeaders.acceptEncodingHeader, 'br');\n",
    );
    File('${tmp.path}/nested/also_bad.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync("req.headers.set('Accept-Encoding', 'gzip, br');\n");
    File('${tmp.path}/ok_br.dart')
        .writeAsStringSync("const String borderAbbrev = 'br';\n");
    File(
      '${tmp.path}/ok.dart',
    ).writeAsStringSync("req.headers.set(HttpHeaders.acceptHeader, '*/*');\n");

    final List<String> hits = findEncodingOverrides(tmp);
    expect(hits, hasLength(2));
    expect(
      hits.where(
        (String h) => h.contains('ok.dart') || h.contains('ok_br.dart'),
      ),
      isEmpty,
      reason: '裸 br 字面量与常规请求头不该被误判（避免宽匹配造成假红）',
    );
  });
}
