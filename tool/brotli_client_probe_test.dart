// 客户端侧探针：dart:io 的 HttpClient 到底怎么处理 gzip / br。
//
// `tool/probe_brotli.sh` 回答「服务端支不支持 br」，这个探针回答另一半：
// 「就算服务端支持，dart:io 会不会帮我们解压」。两者都是真网实测，
// 结论对应 README 二·五十一「补充候选：Brotli 压缩」。
//
// SDK 源码侧的证据（本机 3.47.9 / dart-sdk/lib/_http/）：
//   http_impl.dart:2311  request.headers..add(acceptEncodingHeader, "gzip")
//   http_impl.dart:615   _getCompressionState 只认 content-encoding == "gzip"
//   http_impl.dart:720   只有 gzip.decoder 被挂到响应流上
//   http.dart:1329       "Automatic un-compression is only performed if ... gzip"
//
// 用法（先去掉代理，否则 dart:io 会走不通）：
//   unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY
//   flutter test tool/brotli_client_probe_test.dart
//
// 手动探针，不进 CI，也不在 `flutter test` 的默认扫描范围内（默认只扫 test/）。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

const String _ua = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36';

class _ProbeResult {
  const _ProbeResult(this.status, this.encoding, this.bytes);

  final int status;
  final String encoding;
  final Uint8List bytes;
}

Future<_ProbeResult> _get(
  Uri uri, {
  String? acceptEncoding,
  String? referer,
}) async {
  final HttpClient client = HttpClient(); // autoUncompress 默认 true，与生产一致
  try {
    final HttpClientRequest req = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 12));
    req.headers.set(HttpHeaders.userAgentHeader, _ua);
    if (referer != null) {
      req.headers.set(HttpHeaders.refererHeader, referer);
    }
    if (acceptEncoding != null) {
      // 注意是 set：生产的 rest_client.dart 也是 headers.forEach(req.headers.set)
      req.headers.set(HttpHeaders.acceptEncodingHeader, acceptEncoding);
    }
    final HttpClientResponse res = await req.close().timeout(
      const Duration(seconds: 12),
    );
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in res) {
      builder.add(chunk);
    }
    return _ProbeResult(
      res.statusCode,
      res.headers.value(HttpHeaders.contentEncodingHeader) ?? '-',
      builder.takeBytes(),
    );
  } finally {
    client.close(force: true);
  }
}

String _prefix(Uint8List bytes) {
  final int n = bytes.length < 24 ? bytes.length : 24;
  // 只留可打印 ASCII：行情是 GBK（高字节打成 `.`），br 是二进制（控制字节
  // 也打成 `.`）。直接 latin1 解码会把 NUL 和控制符写进测试日志，
  // 让 grep 把整个日志判成 binary。
  final StringBuffer buf = StringBuffer();
  for (int i = 0; i < n; i++) {
    final int b = bytes[i];
    buf.write(b >= 0x20 && b <= 0x7e ? String.fromCharCode(b) : '.');
  }
  return buf.toString();
}

void main() {
  const String sina = 'https://hq.sinajs.cn/list=sz000651,sz000933';

  test('默认请求：dart:io 自动发 gzip 并透明解压', () async {
    final _ProbeResult r = await _get(
      Uri.parse(sina),
      referer: 'https://finance.sina.com.cn',
    );
    // ignore: avoid_print
    print(
      '默认     → HTTP ${r.status} CE=${r.encoding} '
      '收到 ${r.bytes.length}B，前缀=${_prefix(r.bytes)}',
    );
    expect(r.status, 200);
    expect(r.encoding, 'gzip');
    // 透明解压后拿到的是 GBK 文本，不是 gzip 魔数 1f 8b。
    expect(_prefix(r.bytes), startsWith('var hq_str_'));
  });

  test('手动加 br：顶掉默认 gzip，服务端退回明文传输', () async {
    final _ProbeResult r = await _get(
      Uri.parse(sina),
      referer: 'https://finance.sina.com.cn',
      acceptEncoding: 'br',
    );
    // 注意：这里打印的是**解压后**的报文长度，两种请求自然相同；
    // 线上字节数的差值由 `tool/probe_brotli.sh` 的 size_download 给出。
    // CE=- 才说明这一趟压根没压缩（默认那趟 CE=gzip）。
    // ignore: avoid_print
    print(
      'set br   → HTTP ${r.status} CE=${r.encoding} '
      '报文 ${r.bytes.length}B，前缀=${_prefix(r.bytes)}',
    );
    expect(r.status, 200);
    expect(r.encoding, '-');
    expect(_prefix(r.bytes), startsWith('var hq_str_'));
  });

  test('对照：服务端真回 br 时，dart:io 把压缩字节原样交给调用方', () async {
    final _ProbeResult r = await _get(
      Uri.parse('https://www.cloudflare.com/'),
      acceptEncoding: 'br',
    );
    // ignore: avoid_print
    print(
      '对照 br  → HTTP ${r.status} CE=${r.encoding} '
      '收到 ${r.bytes.length}B，前缀=${_prefix(r.bytes)}',
    );
    expect(r.status, 200);
    expect(r.encoding, 'br');
    // 未解压：HTML 应该以 '<' 开头，这里不是 → GBK/UTF8 解析器必然拿到乱码。
    expect(_prefix(r.bytes), isNot(startsWith('<')));
  });
}
