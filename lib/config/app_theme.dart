import 'package:flutter/material.dart';

/// 应用外观的唯一来源。
///
/// 为什么单独抽成一个函数：Widget Previews 必须和真机用**同一份** ThemeData。
/// 预览里若自己复制一段主题，圆角、字体、种子色迟早和装到手机上的不一致——
/// 那种预览比没有更糟，因为它会让你相信一个不存在的效果。
///
/// 与真机的对应关系：
/// - `fontFamily: 'Inter'`：拉丁/数字走 Inter（SF Pro 的开源近似，OFL 可分发），
///   中文逐字符回退系统字体（引擎自动完成）；
/// - `scaffoldBackgroundColor: transparent`：页面自己画背景（`AuroraBackground`），
///   Scaffold 不能盖一层不透明底；
/// - `splashFactory: NoSplash`：液态玻璃卡片不要 Material 的水波纹。
ThemeData buildSuperMarketTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorSchemeSeed: const Color(0xFFE03A2F),
    fontFamily: 'Inter',
    scaffoldBackgroundColor: Colors.transparent,
    splashFactory: NoSplash.splashFactory,
  );
}
