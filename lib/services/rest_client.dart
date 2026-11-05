import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../config/app_config.dart';
import '../utils/app_log.dart';

/// 一次 HTTP GET 的原始结果。
///
/// 这里只有**传输层**的事实：状态码与响应体。信封怎么拆、`code:0` 算不算成功、
/// 429 的文案怎么写，都属于具体数据源（见 `source/` 目录），
/// 因为换个供应商这些规则全都不一样。
class HttpJsonResponse {
  const HttpJsonResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  bool get isOk => statusCode >= 200 && statusCode < 300;

  /// 免费档限流。
  ///
  /// 实测（2026-11，iTick）：同一分钟内第 5 个请求起返回
  /// `{"error_msg":"{\"code\":429,\"msg\":\"request limit exceeded\"}"}`，
  /// HTTP 状态码也是 429。注意错误信息被**多包了一层字符串**，
  /// 直接 jsonDecode 顶层拿不到 code/msg —— 这里统一按文本判断。
  bool get isRateLimited =>
      statusCode == 429 || body.contains('request limit exceeded');
}

/// 可注入的 GET，签名保持极简：测试里塞假实现即可，不碰真实网络。
typedef HttpGetJson = Future<HttpJsonResponse> Function(
  Uri uri,
  Map<String, String> headers,
);

/// 一次 HTTP GET 的**原始字节**结果。
///
/// 为什么不能复用 [HttpJsonResponse]：那个的 `body` 已经是 `String`，而
/// 解码成 String 的这一步本身就带着字符集假设。新浪 / 腾讯的行情是 **GBK**，
/// 用 `utf8.decoder` 解会直接抛 `FormatException`；用 `latin1` 解又会让汉字
/// 变乱码。**只有原始字节是不带假设的**，所以把字节原样交出去，
/// 由知道协议的那一层（`PollingSource` 的具体实现）决定怎么读。
class HttpRawResponse {
  const HttpRawResponse({required this.statusCode, required this.body})
    : truncated = false;

  const HttpRawResponse.truncated({
    required this.statusCode,
    required this.body,
  }) : truncated = true;

  final int statusCode;
  final List<int> body;

  /// 是否因为超过体积上限被截断（正常报价响应只有几百字节，不该发生）
  final bool truncated;

  /// 这个响应能否**安全交给解析层**。
  ///
  /// HTTP 2xx 只是必要条件：截断响应的状态码同样是 200，但 body 是残缺的
  /// （多半是代理塞回来的大 HTML 错误页）。交给解析层会解析出「部分成功」
  /// ——报价报文逐行独立时尤其危险：前半段照样出价，后半段静默消失，
  /// 界面还显示已连接。所以截断一律判不可用，由各消费点按失败处理。
  bool get isOk => !truncated && statusCode >= 200 && statusCode < 300;

  bool get isRateLimited => statusCode == 429;

  /// 给日志 / 界面用的一句失败原因。
  ///
  /// 截断响应的 [statusCode] 仍是 200，只写「HTTP 200」会把排查引向错误
  /// 方向（服务端其实正常，是响应体被我们自己削掉了）。
  String get failureLabel => truncated
      ? '响应超过 ${_maxRawBytes ~/ 1024}KB 被截断'
      : 'HTTP $statusCode';

  int get byteLength => body.length;
}

/// 可注入的 GET（原始字节版）
typedef HttpGetBytes = Future<HttpRawResponse> Function(
  Uri uri,
  Map<String, String> headers,
);

/// 单次响应的体积上限。
///
/// 行情响应通常 < 2KB。设上限不是为了省内存，而是防「代理返回了一个
/// 几百 KB 的 HTML 错误页」这种事把一次轮询卡住——轮询是有节奏的，
/// 一次卡 30s 会让后面所有轮询排队。
const int _maxRawBytes = 512 * 1024;

/// 共享的 `HttpClient`（**复用 TCP / TLS 连接**）。
///
/// 为什么不「每次请求新建一个再 close」——这是实测出来的，不是洁癖：
///
/// | 场景 | 每次新建 | 复用 |
/// | --- | --- | --- |
/// | 拉全量目录（56 页 × 6 并发） | **26.7s** | **4.0s** |
/// | 3s 轮询一次报价 | 每轮多付一次握手 | 连接已就绪 |
///
/// 56 个请求就是 56 次 DNS + TCP + TLS 握手，光握手吃掉二十秒。
/// 同样的参数换 Python 的复用连接只要 4.0s，差距全在客户端这边。
///
/// 复用带来的唯一新风险是「拿到一条服务端已经关掉的空闲连接」。
/// 请求抛异常时把池标记为待重建（[resetSharedHttpClient] 是测试用的立即
/// 清场版），下一个新请求进来时重建；轮询层本来就有失败重试，
/// 最坏也只是多等一轮。
/// 请求抛异常时只把池标记为「待重建」，**立即关闭会把并发在途的好请求
/// 一起击落**（目录 6 并发抓取时一个坏请求会放大成一批失败）。
/// 池真正被丢弃的时机是下一个新请求进来时——那时旧池上已没有会受伤的人。
HttpClient? _sharedClient;
bool _sharedClientDirty = false;

HttpClient get _httpClient {
  if (_sharedClientDirty) {
    _sharedClient?.close(force: true);
    _sharedClient = null;
    _sharedClientDirty = false;
  }
  return _sharedClient ??= HttpClient()
    ..connectionTimeout = AppConfig.restTimeout
    // 空闲 15s 就回收：轮询间隔 3s，正常情况下连接一直是热的；
    // 切后台几分钟回来时连接早该换了，别拿一条很可能已死的。
    ..idleTimeout = const Duration(seconds: 15)
    // 与 AppConfig.catalogConcurrency（6）留一点余量
    ..maxConnectionsPerHost = 8;
}

/// 丢掉当前连接池，下次请求重新建连（测试用：立即清场）。
@visibleForTesting
void resetSharedHttpClient() {
  _sharedClientDirty = false;
  _sharedClient?.close(force: true);
  _sharedClient = null;
}

/// 默认实现：`dart:io` 的 HttpClient，**不解码**，只收字节。
///
/// 注意 `Accept` 头：不能写 `application/json`（新浪会当成浏览器以外的
/// 调用方，行为未验证），用 `*/*` 最安全。
Future<HttpRawResponse> defaultHttpGetBytes(
  Uri uri,
  Map<String, String> headers,
) async {
  try {
    final HttpClientRequest req = await _httpClient
        .getUrl(uri)
        .timeout(AppConfig.restTimeout);
    req.headers.set(HttpHeaders.acceptHeader, '*/*');
    headers.forEach(req.headers.set);
    final HttpClientResponse res = await req.close().timeout(
      AppConfig.restTimeout,
    );

    final List<int> bytes = <int>[];
    bool truncated = false;
    await for (final List<int> chunk in res.timeout(AppConfig.restTimeout)) {
      bytes.addAll(chunk);
      if (bytes.length > _maxRawBytes) {
        truncated = true;
        bytes.removeRange(_maxRawBytes, bytes.length);
        break;
      }
    }
    return truncated
        ? HttpRawResponse.truncated(statusCode: res.statusCode, body: bytes)
        : HttpRawResponse(statusCode: res.statusCode, body: bytes);
  } on Exception catch (e) {
    AppLog.e('HTTP 请求失败 $uri: $e');
    _sharedClientDirty = true; // 池里可能有坏连接：下个新请求前重建
    rethrow;
  }
}

/// 响应信封的拆解结果：要么拿到 `data`，要么拿到一句能看懂的失败原因。
///
/// 为什么这个类型留在传输层而不是塞进某个源的内部：调用方（快照、目录）
/// 需要按 `isOk` / `rateLimited` 做分支，这个形状是跨源通用的。
class RestResult {
  const RestResult.ok(this.data) : error = null, rateLimited = false;

  const RestResult.failed(String this.error, {this.rateLimited = false})
    : data = null;

  final Object? data;
  final String? error;
  final bool rateLimited;

  bool get isOk => error == null;
}

/// 默认实现：`dart:io` 的 HttpClient。
///
/// 不引入 `http` 包：本项目只跑 Android，`dart:io` 够用，
/// 少一个依赖就少一处将来要跟着升级的东西。
Future<HttpJsonResponse> defaultHttpGet(
  Uri uri,
  Map<String, String> headers,
) async {
  try {
    final HttpClientRequest req = await _httpClient
        .getUrl(uri)
        .timeout(AppConfig.restTimeout);
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    headers.forEach(req.headers.set);
    final HttpClientResponse res = await req.close().timeout(
      AppConfig.restTimeout,
    );
    final String body = await res
        .transform(utf8.decoder)
        .join()
        .timeout(AppConfig.restTimeout);
    return HttpJsonResponse(statusCode: res.statusCode, body: body);
  } on Exception catch (e) {
    AppLog.e('REST 请求失败 $uri: $e');
    _sharedClientDirty = true; // 池里可能有坏连接：下个新请求前重建
    rethrow;
  }
}
