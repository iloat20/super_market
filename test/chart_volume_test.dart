import 'package:flutter_test/flutter_test.dart';

import 'package:super_market/widgets/kline_chart.dart';

/// 量柱的截顶基准（p95）。
///
/// 原来这个数字是**每次 paint** 现算：复制一份 volumes、全量排序、取第 95 位。
/// 分时 240 点、日 K 480 根，滚动时一帧一次，纯属白给。现在提到 painter 构造期
/// 算一次，公式本身不能变（改了整张图的量柱高度都会变），所以先把它锁死。
void main() {
  test('空表给 0（没有量就不画柱）', () {
    expect(volumeP95(const <double>[]), 0);
  });

  test('单值就是它自己', () {
    expect(volumeP95(const <double>[7]), 7);
  });

  test('1..100 取第 95 位（索引 round(99*0.95)=94 → 95.0）', () {
    final List<double> v = <double>[for (int i = 1; i <= 100; i++) i.toDouble()];
    expect(volumeP95(v), 95);
  });

  test('单个极端值被截顶，不会把其余柱压平', () {
    // 这是它存在的理由：换源/复牌/新股首日会有一根异常大的量，
    // 用 max 归一化会把其余 100 根压成 1px 的线
    final List<double> v = <double>[for (int i = 0; i < 100; i++) 1000, 1e9];
    expect(volumeP95(v), 1000);
  });

  test('不改动入参顺序（调用方直接传的是数据源列表）', () {
    final List<double> v = <double>[3, 1, 2];
    volumeP95(v);
    expect(v, <double>[3, 1, 2]);
  });
}
