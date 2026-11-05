import 'package:flutter/foundation.dart';

import '../config/app_config.dart';

/// 行情通道的状态（UI 只消费这 4 个值）。
///
/// 历史名字是 `WsConnectionStatus`（那时只有 WebSocket）。现在同一条状态机
/// 也描述 HTTP 轮询，所以正名成 [FeedStatus]；旧名字保留为别名，页面与测试
/// 不需要跟着改一遍。
enum FeedStatus {
  /// 正在建立第一条链路 / 第一次请求还没回来
  connecting,

  /// 已经在收行情
  connected,

  /// 已断开（前后台切换主动断开属于这一档）
  disconnected,

  /// 断了，正在自动恢复
  reconnecting,
}

/// `FeedStatus` 的旧名（WebSocket 时代的命名，仅为兼容保留）
typedef WsConnectionStatus = FeedStatus;

/// 「行情从哪来」这件事的完整契约。
///
/// 把**传输方式**抽象在这一层，是因为它比协议更靠上：
///
/// ```
///   UI ──► QuoteFeed ──► 连接管理 / 轮询节奏 / 失败切换
///                 └──► 协议（PollingSource）
/// ```
///
/// 上层的页面只认这些成员，换传输方式不需要动 UI。
abstract interface class QuoteFeed {
  /// 连接状态（UI 用 ValueListenableBuilder 监听，不 setState）
  ValueNotifier<FeedStatus> get status;

  /// 需要提示给用户的**致命**错误（订阅被拒、全部内核不可用）。
  ///
  /// 普通断线不进这里：那些会自动重连，写进去只会让界面上闪红条。
  ValueNotifier<String?> get lastError;

  /// 当前订阅标的
  List<StockConfig> get stocks;

  /// 界面上显示的来源名（轮询可能随主备切换而变）
  String get sourceLabel;

  /// 首次启动轮询
  void connect();

  /// 切到后台：主动停掉定时器，不保留任何后台活动
  void pause();

  /// 回到前台：立即恢复（不等退避）
  void resume();

  /// 手动恢复（界面上的刷新按钮 / 错误提示里的「重试」）
  void reconnectNow();

  /// 更新订阅标的（运行期可变）
  void updateStocks(List<StockConfig> next);

  /// 释放资源
  void dispose();
}
