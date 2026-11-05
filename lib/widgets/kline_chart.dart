import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/kline.dart';
import '../models/quote.dart';
import 'glass.dart';

/// 详情页那块走势图的两种形态。
enum ChartMode {
  intraday('分时'),
  daily('日K');

  const ChartMode(this.label);

  final String label;
}

/// 「今开/最高/最低」相对昨收的方向词（A10）。
///
/// 为什么要有它：`_relative()` 只返回颜色，红绿是**唯一**的方向信息——
/// 红绿色盲、强光下的屏幕、灰度截图里，三种情况都会把它读丢。方向词是
/// 颜色之外的第二条通道，且是可见文字，不依赖读屏。
///
/// 返回 null 表示「这一格没有可比对象」（价格缺失或昨收为 0），此时
/// 不显示任何字样，避免出现「0.00 与昨收持平」这种假信息。
String? noteFor(double value, double prevClose) {
  if (value <= 0 || prevClose <= 0) {
    return null;
  }
  if (value > prevClose) {
    return '高于昨收';
  }
  if (value < prevClose) {
    return '低于昨收';
  }
  return '与昨收持平';
}

/// 把「今天」这一根拼进日线序列。
///
/// 为什么必须拼：**新浪的日线不含当日**（实测 2026-11-03 盘中拿到的最新一根
/// 是 11-02），而头部的大数字一直在跳。不拼的话会出现「价格涨了 1%，
/// 图上的最后一根还是昨天」这种自相矛盾的画面。
///
/// 为什么不是无脑追加：腾讯的日线**含**当日，同一根再追加一次就会出现
/// 两根 11-03。所以先比日期——同一天就覆盖，不同天才追加。
///
/// 实时报价里 `open/high/low/price` 正好是当日那根的四个价，`volume` 是
/// 当日累计量，直接可用；成交量单位为股，与 K 线一致。
List<Kline> patchTodayBar(List<Kline> bars, Quote quote) {
  if (!quote.hasData || quote.timestamp == null) {
    return bars;
  }
  final Kline today = Kline(
    time: DateTime(
      quote.timestamp!.year,
      quote.timestamp!.month,
      quote.timestamp!.day,
    ),
    open: quote.open > 0 ? quote.open : quote.price,
    high: quote.high > 0 ? quote.high : quote.price,
    low: quote.low > 0 ? quote.low : quote.price,
    close: quote.price,
    volume: quote.volume,
  );
  if (!today.isValid) {
    return bars;
  }
  if (bars.isEmpty) {
    return <Kline>[today];
  }

  final DateTime lastDay = DateTime(
    bars.last.time.year,
    bars.last.time.month,
    bars.last.time.day,
  );
  if (lastDay == today.time) {
    // 同一天：用实时值覆盖（接口给的当日 bar 可能是几分钟前的快照）
    return <Kline>[
      ...bars.sublist(0, bars.length - 1),
      Kline(
        time: today.time,
        open: bars.last.open, // 开盘价以 K 线为准，报价的开盘价偶尔为 0
        high: math.max(bars.last.high, today.high),
        low: today.low < bars.last.low ? today.low : bars.last.low,
        close: today.close,
        volume: today.volume > 0 ? today.volume : bars.last.volume,
      ),
    ];
  }
  return <Kline>[...bars, today];
}

/// 用最新价补分时线的最后一个点。
///
/// 分时数据是 1 分钟粒度，天然滞后最多 60 秒；详情页每 3 秒就在刷新报价，
/// 不补的话「头部 1451.01、线尾 1446.00」会同时出现在一块玻璃上。
///
/// 只在**同一天**且报价更新时才动最后一个点；跨天（比如昨天收盘后打开）
/// 一律不动，否则会把昨天的线画成今天的价。
List<IntradayPoint> patchLatestPrice(List<IntradayPoint> points, Quote quote) {
  if (points.isEmpty || !quote.hasData || quote.timestamp == null) {
    return points;
  }
  final IntradayPoint last = points.last;
  final DateTime qt = quote.timestamp!;
  if (qt.year != last.time.year ||
      qt.month != last.time.month ||
      qt.day != last.time.day) {
    return points;
  }
  return <IntradayPoint>[
    ...points.sublist(0, points.length - 1),
    IntradayPoint(
      time: last.time,
      price: quote.price,
      avgPrice: last.avgPrice,
      volume: last.volume,
    ),
  ];
}

/// 简单移动平均（SMA）。
///
/// 前 `period - 1` 个位置返回 `null`：样本凑不满一个窗口时就该空着，而不是
/// 拿半个窗口凑一条「看着能连上」的假均线——图上多一条凭空出现的线，比
/// 少一条线糟得多。
///
/// 用滑动窗口累加而不是每根重新求和：日 K 可以要到 480 根，O(n·period)
/// 在每帧重绘里是白给的浪费。
List<double?> movingAverage(List<double> values, int period) {
  if (values.isEmpty) {
    return const <double?>[];
  }
  if (period <= 1) {
    return <double?>[...values];
  }
  final List<double?> out = List<double?>.filled(values.length, null);
  double sum = 0;
  for (int i = 0; i < values.length; i++) {
    sum += values[i];
    if (i >= period) {
      sum -= values[i - period];
    }
    if (i >= period - 1) {
      out[i] = sum / period;
    }
  }
  return out;
}

/// 量柱的截顶基准：第 95 百分位。
///
/// 为什么取 p95 而不是 max：只要有一根异常大的量（换源导致单位不一致、
/// 复牌当天、新股首日），用 max 归一化会把其余所有柱子压成 1~2px 的一条线，
/// 整个量图就废了。取 p95 让那 5% 的极端值"截顶"，其余柱子的相对高度仍然可信。
///
/// 为什么抽成顶层函数：原来这段是**每次 paint 现算**（复制 + 全量排序），
/// 240/480 根的量表在滚动时一帧一次。现在由 `_KlinePainter` 缓存，
/// 而缓存的前提是这个公式可以被单测钉死——改一个下标，整张图的量柱高度都会变。
double volumeP95(List<double> volumes) {
  if (volumes.isEmpty) {
    return 0;
  }
  final List<double> sorted = List<double>.of(volumes)..sort();
  return sorted[((sorted.length - 1) * 0.95).round()];
}

/// 一个交易日的连续竞价总分钟数。
///
/// A 股 `09:30–11:30 / 13:00–15:00` = 240；港股 `09:30–12:00 / 13:00–16:00`
/// = 330。收市竞价（16:00–16:10）不占轴——分时点通常到 16:00 为止。
/// 美股 `09:30–16:00` 连续 = 390，没有午休。
int tradingMinutesOf({required bool hk, bool us = false}) =>
    us ? 390 : (hk ? 330 : 240);

/// 分时图的时间轴位置：把两段连续竞价压成 `0..total`。
///
/// 为什么不能按点的序号等距排：上午 10:45 只有 75 个点，按序号排会铺满整张
/// 图，看上去像「全天已经走完」，而实际上只走了三分之一。午休那 90/60 分钟
/// 本身不该占宽度，所以两段直接接起来（午休夹在上午收盘那一刻）。
///
/// 美股没有午休：位置就是「开盘以来的分钟数」，输入是**美东挂钟**
/// （数据源的分时时刻就是它）。
int tradingMinute(DateTime t, {bool hk = false, bool us = false}) {
  const int open = 9 * 60 + 30;
  final int total = tradingMinutesOf(hk: hk, us: us);
  final int m = t.hour * 60 + t.minute;
  if (us) {
    if (m <= open) {
      return 0;
    }
    final int idx = m - open;
    return idx > total ? total : idx;
  }
  final int morningEnd = hk ? 12 * 60 : 11 * 60 + 30;
  const int afternoonStart = 13 * 60;
  final int morningLen = morningEnd - open; // A 股 120 / 港股 150
  if (m <= open) {
    return 0;
  }
  if (m <= morningEnd) {
    return m - open;
  }
  if (m < afternoonStart) {
    return morningLen; // 午休：夹在上午收盘那一刻
  }
  final int idx = morningLen + (m - afternoonStart);
  return idx > total ? total : idx;
}

/// 走势图（分时 / 日 K）。自绘，不引第三方图表库。
///
/// 为什么不引 `fl_chart`：这个图只有一条折线 + 一组柱子，而库本身会把
/// APK 撑大 2MB 左右，还会带进来一套和液态玻璃完全不同的默认主题。
/// `CustomPainter` 大约 200 行，换来「每个像素都说得清为什么这么画」。
class KlineChart extends StatelessWidget {
  const KlineChart({
    super.key,
    required this.mode,
    this.bars = const <Kline>[],
    this.points = const <IntradayPoint>[],
    this.prevClose = 0,
    this.region = '',
  });

  final ChartMode mode;
  final List<Kline> bars;
  final List<IntradayPoint> points;

  /// 市场代码（`HK` = 港股，`US` = 美股）。分时轴的总分钟数与刻度文字按它
  /// 切换；缺省按 A 股画，已有调用方不必传。
  final String region;

  /// 昨收：分时图的基准线，也是涨跌配色的判据
  final double prevClose;

  /// 图高：价 130 + 间隔 8 + 量 28 + 时间轴 16
  static const double height = 182;

  @override
  Widget build(BuildContext context) {
    // 刻度文字必须**继承主题字体**。
    // 不继承的话，`TextPainter` 会落到默认 family；在 `flutter_test` 里那个
    // family 是 Ahem——每个字符都渲染成一个等宽实心方块，标签宽度还会算错
    // （"1502.5" 从 27px 变成 54px，直接溢出到卡片外）。这个问题只有肉眼看
    // 截图才发现得了，用例永远是绿的。
    final TextStyle axisStyle = DefaultTextStyle.of(context).style.copyWith(
      fontSize: 9.5,
      fontWeight: FontWeight.w500,
      height: 1.1,
      color: GlassPalette.inkSoft,
    );
    final Widget chart = CustomPaint(
      painter: _KlinePainter(
        mode: mode,
        bars: bars,
        points: points,
        prevClose: prevClose,
        axisStyle: axisStyle,
        hk: region == 'HK',
        us: region == 'US',
      ),
    );

    // 日K 是静态图（只在换股票/翻页时变），单独成层：弹层里价格每秒
    // 跳动时，重绘止步于文本层，不会连带这张图重新栅格化。
    // 分时图反过来——它本来就跟着 tick 变，包边界只会让栅格缓存反复
    // 失效，白白多一份「宽×高×4B」的缓存（用户视角是内存涨、帧更抖）。
    // 自绘图对读屏完全不可见（刻度、图例都在 TextPainter 里）。补一句
    // 概述语义；ExcludeSemantics 挡住装饰节点，避免语义树里塞进一堆空节点。
    final double last = mode == ChartMode.intraday
        ? (points.isEmpty ? prevClose : points.last.price)
        : (bars.isEmpty ? prevClose : bars.last.close);
    return Semantics(
      label: '${mode.label}走势图，最新 ${last.toStringAsFixed(2)}，'
          '昨收 ${prevClose.toStringAsFixed(2)}',
      child: ExcludeSemantics(
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: mode == ChartMode.daily
              ? RepaintBoundary(child: chart)
              : chart,
        ),
      ),
    );
  }
}

class _KlinePainter extends CustomPainter {
  _KlinePainter({
    required this.mode,
    required this.bars,
    required this.points,
    required this.prevClose,
    required this.axisStyle,
    required this.hk,
    required this.us,
  });

  final ChartMode mode;
  final List<Kline> bars;
  final List<IntradayPoint> points;
  final double prevClose;

  /// 刻度文字的样式（由 Widget 从主题继承后传进来）
  final TextStyle axisStyle;

  /// 是否港股（分时轴 330 分钟、刻度文字不同）
  final bool hk;

  /// 是否美股（分时轴 390 分钟、连续无午休、刻度到 16:00）
  final bool us;

  /// 量柱满格基准（见 [volumeP95]）。首次 paint 时算一次，之后整 lifetime 复用：
  /// 同一份数据在滚动时会被反复 paint，而 `volumes` 在这些帧之间没有变化。
  double? _volP95;

  int get _minutes => tradingMinutesOf(hk: hk, us: us);

  /// 右侧价格刻度留白。画在图里会压住最后一根蜡烛/线的尾巴，所以留出来。
  static const double _gutter = 46;
  // 130 + 8 + 28 + 16 = 182，与 KlineChart.height 必须一致
  static const double _priceHeight = 130;
  static const double _gap = 8;
  static const double _volumeHeight = 28;

  static const Color _avgLine = Color(0xFFE0A32E);

  /// 日 K 均线：MA5 琥珀（沿用分时均价线的颜色语言，都是"快"的那条），
  /// MA10 蓝紫。两只都不抢红绿——红绿在这个 App 里只表示涨跌。
  static const Color _maFast = Color(0xCCE0A32E);
  static const Color _maSlow = Color(0xCC7C8CE0);

  bool get _isIntraday => mode == ChartMode.intraday;

  @override
  void paint(Canvas canvas, Size size) {
    final double plotW = math.max(0, size.width - _gutter);
    if (plotW <= 0) {
      return;
    }
    final Rect priceRect = Rect.fromLTWH(0, 0, plotW, _priceHeight);
    final Rect volRect = Rect.fromLTWH(
      0,
      _priceHeight + _gap,
      plotW,
      _volumeHeight,
    );

    if (_isIntraday) {
      _paintIntraday(canvas, priceRect, volRect, size);
    } else {
      _paintDaily(canvas, priceRect, volRect, size);
    }
  }

  // ==================== 分时 ====================

  void _paintIntraday(Canvas canvas, Rect price, Rect vol, Size size) {
    final List<IntradayPoint> pts = points
        .where((IntradayPoint p) => p.isValid)
        .toList();
    if (pts.length < 2) {
      _paintEmpty(canvas, size);
      return;
    }

    // 纵轴以昨收为中心上下对称：这样"涨 2%"和"跌 2%"在图上的高度一样，
    // 一眼能看出强弱。用 min/max 直接铺满会让 0.3% 的波动看起来像暴涨。
    double hi = pts.first.price;
    double lo = pts.first.price;
    for (final IntradayPoint p in pts) {
      hi = math.max(hi, p.price);
      lo = math.min(lo, p.price);
    }
    final double base = prevClose > 0 ? prevClose : (hi + lo) / 2;
    double span = math.max(hi - base, base - lo);
    if (span <= 0) {
      span = math.max(base * 0.005, 0.01);
    }
    span *= 1.12; // 上下留一点呼吸

    double y(double price0) {
      final double t = (price0 - (base - span)) / (span * 2);
      return price.bottom - t * price.height;
    }

    double x(DateTime t) {
      final double r = tradingMinute(t, hk: hk, us: us) / _minutes;
      return r * price.width;
    }

    // 淡网格：分时原来一条网格都没有，三个价格刻度就是三个悬空数字。
    // 画在 base±span/2 这两个**有价格含义**的位置（不是随便三等分）：
    // 它们正好是「涨半个振幅 / 跌半个振幅」，读图时能对上数。
    final Paint gridPaint = Paint()
      ..color = const Color(0x0D0F172A)
      ..strokeWidth = 0.7;
    for (final double gy in <double>[
      price.top + price.height * 0.25,
      price.top + price.height * 0.75,
    ]) {
      canvas.drawLine(Offset(0, gy), Offset(price.width, gy), gridPaint);
    }

    // 昨收基准线：再淡一档。它只是参照，不该和走势抢视线
    final double baseY = y(base);
    _dashedLine(
      canvas,
      Offset(0, baseY),
      Offset(price.width, baseY),
      const Color(0x3D0F172A),
    );

    final Color lineColor = pts.last.price >= base
        ? GlassPalette.up
        : GlassPalette.down;

    // 面积填充 + 折线：先取点，再平滑成曲线
    final List<Offset> ptsXY = <Offset>[
      for (final IntradayPoint p in pts) Offset(x(p.time), y(p.price)),
    ];
    final Path line = _smoothThrough(ptsXY);

    // 三段渐变而不是两段：两段的中段（0.22 → 0.02）衰减太快，图上会出现
    // 一条看得出位置的"分界线"
    final Path fill = Path.from(line)
      ..lineTo(ptsXY.last.dx, price.bottom)
      ..lineTo(ptsXY.first.dx, price.bottom)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            lineColor.withValues(alpha: 0.30),
            lineColor.withValues(alpha: 0.10),
            lineColor.withValues(alpha: 0.0),
          ],
          stops: const <double>[0, 0.55, 1],
        ).createShader(price),
    );

    // 宽而淡的一层兜底 + 主色线：单画 1.7px 实线在浅玻璃上又细又硬，
    // 垫一层 4.2px / 13% 的同色线，边缘就有了"发光"过渡
    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = lineColor.withValues(alpha: 0.13),
    );
    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.7
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = lineColor,
    );

    // 均价线：同样平滑，但细一档、压到 80%，避免和主色线抢主导
    final List<IntradayPoint> withAvg = pts
        .where((IntradayPoint p) => p.avgPrice > 0)
        .toList();
    if (withAvg.length >= 2) {
      final Path avg = _smoothThrough(<Offset>[
        for (final IntradayPoint p in withAvg) Offset(x(p.time), y(p.avgPrice)),
      ]);
      canvas.drawPath(
        avg,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.05
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = _avgLine.withValues(alpha: 0.80),
      );
    }

    // 末点：光晕 + 实心 + 白芯，明确"价格现在就在这里"。
    // 原来只有一颗 2.2px 的实心圆，在 1.7px 的线上几乎分不出来。
    final Offset endPt = ptsXY.last;
    canvas.drawCircle(
      endPt,
      5.6,
      Paint()..color = lineColor.withValues(alpha: 0.16),
    );
    canvas.drawCircle(endPt, 2.6, Paint()..color = lineColor);
    canvas.drawCircle(endPt, 1.1, Paint()..color = const Color(0xD9FFFFFF));

    // 分时的量柱用**单色**：逐分钟涨跌着色只会变成一排红绿噪点，
    // 而量柱在这一眼里的作用是"什么时候放量"，不是"这一分钟涨还是跌"。
    _paintVolume(
      canvas,
      vol,
      <double>[for (final IntradayPoint p in pts) p.volume],
      // x 用与折线同一套 tradingMinute（按时刻），而不是数组序号：
      // 点序列一旦不连续（缺成交分钟、港股收市竞价的尾部点），序号定位
      // 会和折线错位、甚至越界画进右侧刻度留白
      (int i) => tradingMinute(pts[i].time, hk: hk, us: us) / _minutes * vol.width,
      vol.width / _minutes,
      (int i) => lineColor,
      // 渐变把柱底压到 45%，整体观感约等于原来的 0.7 倍。0.34 直接照搬会
      // 比改之前还淡，所以往上补一档到 0.46
      opacity: 0.46,
    );

    // 刻度
    _priceLabel(canvas, price, size, base + span, price.top);
    _priceLabel(canvas, price, size, base, baseY);
    _priceLabel(canvas, price, size, base - span, price.bottom);
    _timeLabels(canvas, size, vol.bottom, plotWidth: price.width, hk: hk, us: us);
  }

  // ==================== 日 K ====================

  void _paintDaily(Canvas canvas, Rect price, Rect vol, Size size) {
    final List<Kline> bars0 = bars.where((Kline k) => k.isValid).toList();
    if (bars0.isEmpty) {
      _paintEmpty(canvas, size);
      return;
    }

    double hi = bars0.first.high;
    double lo = bars0.first.low;
    for (final Kline k in bars0) {
      hi = math.max(hi, k.high);
      lo = math.min(lo, k.low);
    }
    final double span = math.max(hi - lo, hi * 0.01);
    // 顶部留 10%（原来 6%）：MA 图例画在价格区左上角，6% 的高度不够它站住，
    // 会压到最高的那根影线头上
    hi += span * 0.10;
    lo -= span * 0.06;

    double y(double v) => price.bottom - (v - lo) / (hi - lo) * price.height;

    final double slot = price.width / bars0.length;
    // 上限 9px 防止根数很少时变成一排大方块。
    //
    // 下限不能是固定值：240 根时 slot 只有 1.46px，而旧的下限写死 1.6px，
    // 实体比槽还宽，相邻两根直接压在一起——count 取到 240 根时图会糊成
    // 一片。所以下限取 max(slot*0.8, …) 反过来夹住自己：bodyW 永远 ≤ slot。
    final double bodyW = math.min(
      math.max(slot * 0.62, 1.0),
      math.min(9.0, slot * 0.8),
    );

    // 三条极轻的网格线，给眼睛一个参照
    final Paint gridPaint = Paint()
      ..color = const Color(0x0D0F172A)
      ..strokeWidth = 0.7;
    for (int i = 1; i <= 3; i++) {
      final double gy = price.top + price.height * i / 4;
      canvas.drawLine(Offset(0, gy), Offset(price.width, gy), gridPaint);
    }

    // 均线画在蜡烛**下面**：蜡烛是主角，均线是参照。反过来会让实体边缘
    // 被一条彩色线横穿，根数多的时候整张图像蒙了层网点。
    final List<double> closes = <double>[for (final Kline k in bars0) k.close];
    final List<double?> ma5 = movingAverage(closes, 5);
    final List<double?> ma10 = movingAverage(closes, 10);
    double maX(int i) => slot * i + slot / 2;
    _paintMa(canvas, ma5, maX, y, _maFast);
    _paintMa(canvas, ma10, maX, y, _maSlow);

    for (int i = 0; i < bars0.length; i++) {
      final Kline k = bars0[i];
      final double cx = slot * i + slot / 2;
      final Color color = k.isUp ? GlassPalette.up : GlassPalette.down;
      final Paint paint = Paint()..color = color;

      // 影线
      canvas.drawLine(
        Offset(cx, y(k.high)),
        Offset(cx, y(k.low)),
        paint..strokeWidth = 0.85,
      );

      // 实体：开盘=收盘时画 1px 横线（十字星），别画成一个 0 高的矩形
      final double oy = y(k.open);
      final double cy = y(k.close);
      if ((oy - cy).abs() < 1) {
        canvas.drawLine(
          Offset(cx - bodyW / 2, oy),
          Offset(cx + bodyW / 2, oy),
          paint..strokeWidth = 1,
        );
      } else {
        // 圆角实体：槽宽只有 1~2px 时圆角没有意义（半径按宽度回夹），
        // 宽的时候（根数少、单根 9px）才有那种"饱满"的蜡烛观感
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(
              cx - bodyW / 2,
              math.min(oy, cy),
              cx + bodyW / 2,
              math.max(oy, cy),
            ),
            Radius.circular(math.min(1.2, bodyW * 0.35)),
          ),
          paint,
        );
      }
    }

    // 图例：只有真的画了那条线才给标签。数据不足 10 根时写个 MA10
    // 却看不到线，是最容易被当成"图坏了"的一种误导。
    double legendX = 0;
    if (_hasLine(ma5)) {
      legendX = _maLegend(canvas, 'MA5', _maFast, legendX);
    }
    if (_hasLine(ma10)) {
      _maLegend(canvas, 'MA10', _maSlow, legendX);
    }

    _paintVolume(
      canvas,
      vol,
      <double>[for (final Kline k in bars0) k.volume],
      (int i) => slot * i + slot / 2 - bodyW / 2,
      bodyW,
      (int i) => bars0[i].isUp ? GlassPalette.up : GlassPalette.down,
      opacity: 0.52,
    );

    _priceLabel(canvas, price, size, hi, price.top);
    _priceLabel(canvas, price, size, (hi + lo) / 2, price.center.dy);
    _priceLabel(canvas, price, size, lo, price.bottom);
    _dayLabels(canvas, size, vol.bottom, bars0, slot);
  }

  // ==================== 公共部件 ====================

  /// 把一串点连成平滑曲线（二次贝塞尔 + 中点分段）。
  ///
  /// 为什么不用 Catmull-Rom 三次样条：样条在急涨急跌处会**过冲**，而图线上
  /// 冲出去的那一截会被读成「价格到过那里」——那是假的价格。这里的每段曲线
  /// 以「两个相邻点的中点」为终点、原数据点为控制点，曲线始终落在相邻点的
  /// 凸包内，不会画出数据里没有的极值。
  Path _smoothThrough(List<Offset> pts) {
    final Path path = Path();
    if (pts.isEmpty) {
      return path;
    }
    path.moveTo(pts.first.dx, pts.first.dy);
    if (pts.length < 3) {
      for (int i = 1; i < pts.length; i++) {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
      return path;
    }
    for (int i = 1; i < pts.length - 1; i++) {
      final Offset mid = Offset(
        (pts[i].dx + pts[i + 1].dx) / 2,
        (pts[i].dy + pts[i + 1].dy) / 2,
      );
      path.quadraticBezierTo(pts[i].dx, pts[i].dy, mid.dx, mid.dy);
    }
    path.lineTo(pts.last.dx, pts.last.dy);
    return path;
  }

  /// 画一条均线。`null` 位置跳过（样本不足 period 的头部）。
  void _paintMa(
    Canvas canvas,
    List<double?> values,
    double Function(int index) xOf,
    double Function(double value) yOf,
    Color color,
  ) {
    final List<Offset> pts = <Offset>[];
    for (int i = 0; i < values.length; i++) {
      final double? v = values[i];
      if (v == null) {
        continue;
      }
      pts.add(Offset(xOf(i), yOf(v)));
    }
    if (pts.length < 2) {
      return;
    }
    canvas.drawPath(
      _smoothThrough(pts),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.15
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  bool _hasLine(List<double?> values) =>
      values.where((double? v) => v != null).length >= 2;

  /// 图例：一小段色条 + 标签。返回下一个图例的起始 x。
  ///
  /// 不画在三行时间轴里，是因为那里右侧已经被最后一个日期占住；价格区顶部
  /// 的 10% 留白本来就是为了它。
  double _maLegend(Canvas canvas, String label, Color color, double x) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x, 4.5, 7, 2),
        const Radius.circular(1),
      ),
      Paint()..color = color,
    );
    final TextPainter p = TextPainter(
      text: TextSpan(
        text: label,
        style: axisStyle.copyWith(fontSize: 8.5, color: color),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    try {
      p.paint(canvas, Offset(x + 10, 0));
      return x + 10 + p.width + 10;
    } finally {
      p.dispose();
    }
  }

  void _paintVolume(
    Canvas canvas,
    Rect area,
    List<double> volumes,
    double Function(int index) xOf,
    double barWidth,
    Color Function(int index) colorOf, {
    double opacity = 0.55,
  }) {
    // 满格基准的算法见 [volumeP95]。这里**每个 painter 实例只算一次**：
    // 同一个 painter 会在滚动时被反复 paint，而 volumes 在这些帧之间是同一份。
    final double maxVol = _volP95 ??= volumeP95(volumes);
    if (maxVol <= 0) {
      return;
    }
    // 量的下限画 1px：完全不画会让"这一分钟没成交"和"图坏了"分不清
    //
    // 竖向渐变（柱顶实、柱底散）而不是整片同透明度：后者看着像一排栅栏。
    // shader 按颜色缓存——日K 只有红绿两种、分时只有一种，每帧最多建 2~3 个，
    // 而不是每根柱子建一个（240 根就是 240 次梯度分配）。
    final Map<int, Shader> shaders = <int, Shader>{};
    final double barW = math.max(barWidth * 0.86, 0.8);
    for (int i = 0; i < volumes.length; i++) {
      final double h = (volumes[i] / maxVol * area.height).clamp(
        1.0,
        area.height,
      );
      final Color c = colorOf(i);
      final Shader shader = shaders.putIfAbsent(
        c.toARGB32(),
        () => LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            c.withValues(alpha: opacity),
            c.withValues(alpha: opacity * 0.45),
          ],
        ).createShader(area),
      );
      canvas.drawRect(
        Rect.fromLTWH(xOf(i), area.bottom - h, barW, h),
        Paint()..shader = shader,
      );
    }
  }

  void _priceLabel(
    Canvas canvas,
    Rect price,
    Size size,
    double value,
    double y,
  ) {
    if (value <= 0) {
      return;
    }
    final String text = value >= 1000
        ? value.toStringAsFixed(1)
        : value.toStringAsFixed(2);
    // 顶部/底部两个刻度往里收 6px，否则文字会被裁掉一半
    // 上下各留 1px，避免第一个/最后一个刻度被绘图区裁掉
    final double ty = (y - 4.5).clamp(0.0, _priceHeight - 9);
    _text(canvas, text, Offset(price.width + 6, ty), GlassPalette.inkSoft);
  }

  /// 分时的时间轴：09:30 / 11:30·13:00 / 15:00。
  ///
  /// 中间那个刻度写「11:30/13:00」而不是两个独立刻度——午休不占宽度，
  /// 两段是连续画在一起的，分开标会让人以为中间漏了一段。
  /// 美股连续无午休，中缝就是全程中点 12:45；刻度是**美东挂钟**
  /// （数据源的分时时刻就是它，与 A/H 用本地钟的口径各自自洽）。
  void _timeLabels(
    Canvas canvas,
    Size size,
    double top, {
    required double plotWidth,
    required bool hk,
    required bool us,
  }) {
    _text(canvas, '09:30', Offset(0, top + 1), GlassPalette.inkSoft);
    final String mid = us
        ? '12:45'
        : hk
        ? '12:00/13:00'
        : '11:30/13:00';
    final double midW = _measureWidth(mid, GlassPalette.inkSoft);
    _text(
      canvas,
      mid,
      Offset(plotWidth / 2 - midW / 2, top + 1),
      GlassPalette.inkSoft,
    );
    final String end = us || hk ? '16:00' : '15:00';
    final double endW = _measureWidth(end, GlassPalette.inkSoft);
    _text(
      canvas,
      end,
      Offset(plotWidth - endW, top + 1),
      GlassPalette.inkSoft,
    );
  }

  /// 日 K 的时间轴：首/中/末三根各自「月-日」。
  void _dayLabels(
    Canvas canvas,
    Size size,
    double top,
    List<Kline> bars0,
    double slot,
  ) {
    final int last = bars0.length - 1;
    final List<int> idx = <int>[0, last ~/ 2, last];
    for (final int i in idx) {
      final DateTime t = bars0[i].time;
      final String label =
          '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
      final double w = _measureWidth(label, GlassPalette.inkSoft);
      final double cx = slot * i + slot / 2;
      final double dx = (cx - w / 2).clamp(0.0, size.width - w);
      _text(canvas, label, Offset(dx, top + 1), GlassPalette.inkSoft);
    }
  }

  void _paintEmpty(Canvas canvas, Size size) {
    // 没有数据时不画一条假线，留空 + 一条极淡的中轴
    canvas.drawLine(
      const Offset(0, _priceHeight / 2),
      Offset(size.width - _gutter, _priceHeight / 2),
      Paint()
        ..color = const Color(0x140F172A)
        ..strokeWidth = 1,
    );
  }

  void _dashedLine(Canvas canvas, Offset a, Offset b, Color color) {
    const double dash = 4;
    const double gap = 4;
    final Paint p = Paint()
      ..color = color
      ..strokeWidth = 0.9;
    double x = a.dx;
    while (x < b.dx) {
      canvas.drawLine(
        Offset(x, a.dy),
        Offset(math.min(x + dash, b.dx), b.dy),
        p,
      );
      x += dash + gap;
    }
  }

  /// 造一个已完成 layout 的 TextPainter。
  ///
  /// 调用方**必须** `dispose()`：它持有一份已 layout 的 `ui.Paragraph`
  /// （native 内存），不释放就要等 finalizer 排队。弹层里这张图会随跳价与
  /// 滚动反复重绘，一秒能产生数百个 paragraph，不 dispose 就是持续的内存抖动。
  TextPainter _newPainter(String text, Color color) => TextPainter(
    text: TextSpan(
      text: text,
      style: axisStyle.copyWith(color: color),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();

  /// 量一行文字的宽度，量完立即释放。
  double _measureWidth(String text, Color color) {
    final TextPainter tp = _newPainter(text, color);
    try {
      return tp.width;
    } finally {
      tp.dispose();
    }
  }

  void _text(Canvas canvas, String text, Offset offset, Color color) {
    final TextPainter tp = _newPainter(text, color);
    try {
      tp.paint(canvas, offset);
    } finally {
      tp.dispose();
    }
  }

  @override
  bool shouldRepaint(_KlinePainter old) {
    // U-01（review-2026-11-05）：比较集必须是「全部影响绘制的字段」。
    // axisStyle/hk/us 曾漏比——刻度样式（字体族等）或区域口径变化时返回
    // false，图会停留在旧样式直到下一次数据更新。
    // 注意：图表刻意是**缩放不变**的（axisStyle 用 copyWith 把 fontSize
    // 钉在 9.5），系统字体缩放不构成「axisStyle 变化」，不应触发重绘；
    // 该语义由 kline_chart_test 的「字体缩放变化 → 刻意不重绘」用例钉住。
    return old.mode != mode ||
        !identical(old.bars, bars) ||
        !identical(old.points, points) ||
        old.prevClose != prevClose ||
        old.axisStyle != axisStyle ||
        old.hk != hk ||
        old.us != us;
  }
}
