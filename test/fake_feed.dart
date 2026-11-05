import 'package:flutter/foundation.dart';
import 'package:super_market/config/app_config.dart';
import 'package:super_market/models/quote.dart';
import 'package:super_market/services/quote_feed.dart';

/// 不联网的空转 feed：widget 测试用它替代真实通道，
/// 保证「不建连、不轮询、不留 timer」。
class NoopFeed implements QuoteFeed {
  NoopFeed(this.onQuotes);

  final void Function(List<Quote>) onQuotes;

  @override
  final ValueNotifier<FeedStatus> status =
      ValueNotifier<FeedStatus>(FeedStatus.disconnected);

  @override
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  bool _disposed = false;

  @override
  List<StockConfig> get stocks => AppConfig.stocks;

  @override
  String get sourceLabel => 'Noop';

  @override
  void connect() {}

  @override
  void pause() {}

  @override
  void resume() {}

  @override
  void reconnectNow() {}

  @override
  void updateStocks(List<StockConfig> next) {}

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    status.dispose();
    lastError.dispose();
  }

  /// 页面测试的 serviceBuilder 直接传这个
  static QuoteFeed builder(ValueChanged<List<Quote>> onQuotes) =>
      NoopFeed(onQuotes);
}
