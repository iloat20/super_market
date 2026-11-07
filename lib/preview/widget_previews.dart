/// 组件预览（Flutter 3.47 起 Widget Previews 转正）。
///
/// ## 为什么这个文件值得存在
///
/// 本项目的像素验证原本只有一条路：跑 `flutter test` 里的 golden。那条路很硬
/// （能抓 1px 偏差），但很慢——改一个卡片的圆角要等整棵 App 树建完。预览把
/// 回路缩到"存盘即见"，golden 则退回它该干的活：**像素级回归**。
///
/// ## 两条约定
///
/// 1. **外观必须复用真机的那一份**：主题来自 `buildSuperMarketTheme()`、玻璃
///    主题来自 `GlassThemeData.ios27()`、背景来自 `AuroraBackground()`。预览里
///    另起一套样式等于给自己看一张假图。
/// 2. **时间必须钉死**：`QuoteTile` / `MarketSessionBadge` 都接受注入时钟，
///    就是为了这个——用真实墙钟的话，08:30 预览出「盘前」、09:20 出「集合竞价」，
///    图会自己失效。
///
/// 启动：`flutter widget-preview start`（IDE 侧栏也有同名面板）。
library;

import 'package:flutter/widget_previews.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:material_ui/material_ui.dart';

import '../config/app_config.dart';
import '../config/app_theme.dart';
import '../models/quote.dart';
import '../widgets/glass.dart';
import '../widgets/market_session_badge.dart';
import '../widgets/quote_tile.dart';

/// 预览里钉死的时刻：A 股盘中（10:19:57）。
final DateTime _t = DateTime(2026, 11, 6, 10, 19, 57);

/// 2026-02-17（周二，春节）：工作日但交易所休市。
///
/// 角标必须写「休市」——二·三十八 之前这里会显示「交易中」。
final DateTime _cnNewYear = DateTime(2026, 2, 17, 10, 0);

const StockConfig _gl = StockConfig(code: '000651', name: '格力电器', region: 'SZ');

Quote _quote({
  required double price,
  required double change,
  required double percent,
  TradingStatus status = TradingStatus.normal,
}) {
  return Quote(
    code: _gl.code,
    region: _gl.region,
    price: price,
    change: change,
    changePercent: percent,
    previousClose: price - change,
    open: price - change * 0.5,
    high: price + 0.2,
    low: price - 0.3,
    volume: 18830152,
    turnover: 735423898,
    tradingStatus: status,
    timestamp: _t,
  );
}

/// 预览外壳：和 `main.dart` 的层级保持一致（wrap 在 MaterialApp 之外），
/// 背景放 `AuroraBackground`，与真机同一份背景（当前是单一实色，
/// 色号见 `GlassPalette.background`）；预览里若
/// 自己填一个近似的白，看到的就不是装到手机上的那张图。
///
/// 必须是公开符号：`@Preview` 的注解参数只接受字面量和公开符号，
/// 私有函数会被 `invalid_widget_preview_private_argument` 拦下。
Widget previewShell(Widget child) {
  return LiquidGlassWidgets.wrap(
    theme: const GlassThemeData.ios27(),
    brightnessResolver: Theme.maybeBrightnessOf,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildSuperMarketTheme(),
      builder: (BuildContext context, Widget? inner) {
        return Material(type: MaterialType.transparency, child: inner);
      },
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            const AuroraBackground(),
            Padding(padding: const EdgeInsets.all(20), child: child),
          ],
        ),
      ),
    ),
  );
}

/// 上涨：红（A 股口径）。
@Preview(
  group: '行情卡片',
  name: '上涨',
  size: Size(393, double.infinity),
  wrapper: previewShell,
)
Widget quoteTileUp() {
  return QuoteTile(
    stock: _gl,
    quote: ValueNotifier<Quote>(
      _quote(price: 39.17, change: 0.47, percent: 1.21),
    ),
    now: () => _t,
  );
}

/// 下跌：绿。
@Preview(
  group: '行情卡片',
  name: '下跌',
  size: Size(393, double.infinity),
  wrapper: previewShell,
)
Widget quoteTileDown() {
  return QuoteTile(
    stock: _gl,
    quote: ValueNotifier<Quote>(
      _quote(price: 38.23, change: -0.47, percent: -1.21),
    ),
    now: () => _t,
  );
}

/// 停牌：验证角标文字与配色（`TradingStatus.suspended`）。
@Preview(
  group: '行情卡片',
  name: '停牌',
  size: Size(393, double.infinity),
  wrapper: previewShell,
)
Widget quoteTileSuspended() {
  return QuoteTile(
    stock: _gl,
    quote: ValueNotifier<Quote>(
      _quote(
        price: 39.17,
        change: 0,
        percent: 0,
        status: TradingStatus.suspended,
      ),
    ),
    now: () => _t,
  );
}

/// 大字号：1.3× 字体下的溢出防护。
///
/// 卡片里的价格与涨跌胶囊套了 `FittedBox`、名称/代码有省略号，这条预览就是
/// 用来看"这层防护到底还成不成立"——真机上得把系统字体调大才看得到。
@Preview(
  group: '行情卡片',
  name: '大字号 1.3×',
  size: Size(393, double.infinity),
  textScaleFactor: 1.3,
  wrapper: previewShell,
)
Widget quoteTileLargeText() {
  return QuoteTile(
    stock: _gl,
    quote: ValueNotifier<Quote>(
      _quote(price: 1234.56, change: 12.34, percent: 1.01),
    ),
    now: () => _t,
  );
}

/// 交易时段角标：盘中。同一条链路上还有盘前 / 集合竞价 / 收盘，
/// 时钟可注入，所以每个时刻都能单独钉一张图。
@Preview(
  group: '角标',
  name: '盘中',
  size: Size(240, double.infinity),
  wrapper: previewShell,
)
Widget marketSessionBadgeLive() {
  return Align(
    alignment: Alignment.centerLeft,
    child: MarketSessionBadge(
      now: () => _t,
      regions: const <String>['SZ', 'SH'],
    ),
  );
}

/// 交易时段角标：法定节假日。2026-02-17 是周二（春节），旧逻辑会写「交易中」。
@Preview(
  group: '角标',
  name: '节假日休市',
  size: Size(240, double.infinity),
  wrapper: previewShell,
)
Widget marketSessionBadgeHoliday() {
  return Align(
    alignment: Alignment.centerLeft,
    child: MarketSessionBadge(
      now: () => _cnNewYear,
      regions: const <String>['SZ', 'SH'],
    ),
  );
}
