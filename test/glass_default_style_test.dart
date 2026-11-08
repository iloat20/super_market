import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 1.17.0 的 breaking change：上游默认玻璃风格改成 `GlassStyle.ios27`。
///
/// 本工程一直显式写 `GlassThemeData.ios27()`（见 `lib/main.dart`），
/// 所以升级时「默认风格翻篇」本身不影响我们。这两条断言守的是另一半：
/// 上游默认与显式主题**必须保持同一个风格**，否则「有 GlassTheme」和
/// 「无 GlassTheme」两条路径会分叉（预览、测试外壳、将来新页面）。
void main() {
  test('包默认玻璃风格就是 ios27（默认构造与 fallback 一致）', () {
    expect(const GlassThemeData().style, GlassStyle.ios27);
    expect(GlassThemeData.fallback().style, GlassStyle.ios27);
    expect(const GlassThemeData.ios27().style, GlassStyle.ios27);
  });

  test('显式 ios27 主题额外把全局 quality 钉在 premium，fallback 不钉', () {
    // 这是 `main.dart` 保留显式主题、不改用新默认的原因：
    // fallback 的 variant.quality 为 null，各组件会按自己的默认取档。
    expect(const GlassThemeData.ios27().light.quality, GlassQuality.premium);
    expect(GlassThemeData.fallback().light.quality, isNull);
  });
}
