# Flutter 深度审查报告 · super_market（itick_quote）

- 审查对象：`C:/Users/Administrator/Downloads/work/milan/super_market`
- 代码基线：44 个 Dart 文件 / 9768 行；`lib/` 全量逐行阅读；`android/`（build.gradle.kts、proguard-rules.pro、AndroidManifest.xml、MainActivity.kt、gradle.properties）；`pubspec.yaml` / `pubspec.lock`；`assets/`；`build/app/outputs` 实包
- 构建产物：`build/app/outputs/flutter-apk/app-release.apk`（17,538,222 B，2026-11-05 09:40）
- 审查方式：纯静态审查 + 产物解包 + 与项目自带的真机测量台账（README:L283-L287、L1441-L1449）交叉验证。**未修改任何代码**
- 审查时间：2026-11-05

---

## 0. 一句话结论

**这不是一个"需要抢救"的项目。** 冷启动 320ms、滚动 raster p50 4.6ms@120Hz、前台 PSS 134MB、退后台 CPU 0%——四个量化目标里三个已被真机数据证明达标，代码在"边界防御 / dispose 纪律 / 首帧解耦 / R8 构建链"上的完成度明显高于同规模项目。

问题集中在**三个被现有测量覆盖不到的地方**：① 编辑订阅列表时的状态重建（唯一 P0）；② 详情弹层里"玻璃包住内容"的分层倒置（与列表卡片已修正的做法相反）；③ 交易时段内那颗永不停止旋转的太极。三者都不是"写错了"，而是**同一套正确结论没有推广到所有调用点**。

---

## 1. 量化目标达成情况

| 目标 | 要求 | 现状 | 证据 | 判定 |
|---|---|---|---|---|
| 冷启动 | ≤ 1.2s | **320ms**（3 次中位，release / OPPO Find X9） | README:L1441；`am start -W` TotalTime 354/308/320 | ✅ 达标（余量 3.7×） |
| 列表滚动帧率 | ≥ 55 FPS | raster p50 **4.6ms** / p90 5.6ms @120Hz，0~1 掉帧 / 570 帧 | README:L283-L285 | ✅ 达标（预算 8.33ms，余量 45%） |
| 内存峰值 | ≤ 180MB | 前台 PSS **134MB**，退后台 81MB | README:L1446-L1447 | ✅ 达标（余量 46MB） |
| APK 体积 | < 20MB | **17.5MB**（arm64 单 ABI） | `unzip -l`：libflutter 11.2MB / libapp 4.4MB / dex 0.4MB | ✅ 达标 |
| 后台空闲 CPU | ≤ 5% | 退后台 30s：**CPU 0%**，无轮询日志 | README:L1447 | ✅ 达标 |
| **盘中持续刷新帧率** | 60/120Hz 预算内 | **未测**（README:L1449 自认缺口） | — | ⚠️ 未验证 → 本报告 P1-3/P1-4/P1-5 正落在这一格 |
| **空闲（前台静置）CPU** | ≤ 5%（隐含） | **无有效数据** | README:L1445「静置 30s 帧数 0」与 `perf_probe.dart:19-21` 的"HWUI 统计不到 Flutter 帧"自相矛盾 | ⚠️ 采样方法存疑 → 见 P1-5 |

> 关于"静置 0 帧"这条：`tool/perf_probe.dart:19-21` 明确记录过"HWUI 统计不到 Flutter 的帧，reset 后滑动一次 Total frames rendered: 0"。而页头秒表 `_ClockTitle` 每秒 `setState`（`quote_list_page.dart:562-567`），在前台**不可能** 30 秒 0 帧。因此这条数据要么是在收盘后+退后台采的，要么就是 gfxinfo 的老问题。**它不能作为"前台空闲"的证据**——这一点直接影响 P1-5 的判定。

---

## 2. 逐条发现

> 标注约定：**【已确认】** = 代码级可直接证明；**【PROJECTED】** = 机制成立、但帧时/功耗需真机量化，不与已确认问题混排。

---

### P0-1 编辑订阅列表时，全列表的 notifier 被整体重建：价格清空 + 旧实例未 dispose

**位置**：`lib/pages/quote_list_page.dart:157-186` · `_buildNotifiersFor` / `_syncNotifiers`（调用点 `L225`）
**严重度**：P0（按你给的分级：正确性缺陷——界面会显示与事实不符的状态）
**维度**：内存 / UI
**证据**：

```dart
// L157  无条件覆盖：连"保留下来的那些标的"也换成了新的空 notifier
void _buildNotifiersFor(List<StockConfig> stocks) {
  for (final StockConfig stock in stocks) {
    _notifiers[stock.key] = ValueNotifier<Quote>(
      Quote.empty(stock.code, region: stock.region),   // ← 价格归零
    );
  }
}

// L166 先"全部重建"，再"删除多余的"
void _syncNotifiers() {
  final Set<String> wanted = _stocks.map((StockConfig s) => s.key).toSet();
  _buildNotifiersFor(_stocks);                 // ← 已存在的 key 被新实例覆盖
  ...
  _notifiers.removeWhere((String key, ValueNotifier<Quote> notifier) {
    if (wanted.contains(key)) return false;    // ← 保留的 key 直接返回
    dead.add(notifier);
    return true;
  });
```

**为什么是问题**：
1. **持有链**：`_QuoteListPageState._notifiers[key]`（长生命周期 Map）原本持有旧 `ValueNotifier<Quote>`；被覆盖后旧实例失去唯一强引用，但**没有任何人调用它的 `dispose()`**——`dead` 列表只收"被删除的标的"，保留标的的旧实例是"被顶掉的"，永远进不了 `dead`。它们当前的监听者（`ValueListenableBuilder`）会在下一帧 `didUpdateWidget` 里 `removeListener`，所以**不会造成持续泄漏**，属于"GC 可回收但违反 dispose 纪律"——真出问题的是下一条。
2. **可见症状**：`_openWatchlist`（L224-227）→ `setState(_syncNotifiers)` → 这一帧所有卡片（包括没被改动的）全部回到 `Quote.empty`，`q.hasData == false` → 价格显示 `--`、涨跌胶囊显示 `--`（`quote_tile.dart:345`、`415-416`）。要等 `_service.updateStocks(next)` 触发的立即轮询回来（实测 RTT 中位 103ms + 解析）才恢复。**用户每加/删一只股票，整屏价格闪空一次**。
3. 对本项目自己的判定标准（`quote_freshness.dart:5-14` 那段"上一个交易日的收盘价被标成实时价"的复盘）来说，"有价却显示 `--`"是同一类"说错话"，只是方向相反。

**修复方案**：

```dart
/// 让 notifier 集合与 [_stocks] 对齐：只补新的、只删旧的，已存在的一律保留。
void _syncNotifiers() {
  final Set<String> wanted = _stocks.map((StockConfig s) => s.key).toSet();

  for (final StockConfig stock in _stocks) {
    _notifiers.putIfAbsent(
      stock.key,
      () => ValueNotifier<Quote>(Quote.empty(stock.code, region: stock.region)),
    );
  }

  final List<ValueNotifier<Quote>> dead = <ValueNotifier<Quote>>[];
  _notifiers.removeWhere((String key, ValueNotifier<Quote> notifier) {
    if (wanted.contains(key)) return false;
    dead.add(notifier);
    return true;
  });
  if (dead.isNotEmpty) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final ValueNotifier<Quote> notifier in dead) {
        notifier.dispose();
      }
    });
  }
}
```

配套回归测试（红态可先失败）：

```dart
testWidgets('改订阅列表不会清空未改动标的的价格', (WidgetTester tester) async {
  // 1) 泵出页面并推一条 600519 的报价 → 断言卡片上出现具体价格
  // 2) 打开订阅弹层，添加一只新标的并确认
  // 3) 在"新标的的首轮报价回来之前"pump 一帧
  // 4) 断言 600519 的价格仍然可见（旧实现此处会变成 '--'）
});
```

**量化影响**：消除每次编辑订阅时 1 帧的全列表价格清空（3~30 张卡）与至多 N 个未 dispose 的 notifier 实例；对 30 只满配额用户，单次编辑少掉 30 个 `ValueNotifier` 的分配与 30 次 `ValueListenableBuilder` 重订阅。

---

### P1-2 缺少全局错误钩子，且存在两条已证实的未捕获异步路径

**位置**：`lib/main.dart:11-51` · `main()`（全文件 86 行，无 `FlutterError.onError` / `PlatformDispatcher.instance.onError` / `runZonedGuarded`）
**严重度**：P1
**维度**：崩溃
**证据**：

```dart
// main.dart:11
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installFrameProbe();          // PERF_LOG 未开时第一行就 return
  AppLog.tag = QuoteFeeds.label;
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);   // 未 await
  SystemChrome.setSystemUIOverlayStyle(...);                      // 未 await
  await LiquidGlassWidgets.initialize();
  final AppDependencies deps = AppDependencies.production();
  runApp(...);
}
```

两条可证的未捕获路径（不是理论推演）：

```dart
// ① quote_list_page.dart:212 / :645，watchlist_sheet.dart:213 / :236
unawaited(HapticFeedback.selectionClick());   // 平台通道抛 PlatformException 时无人接

// ② symbol_directory.dart:81 —— _readCache() 在 try 之外
final _Cache? cache = await _readCache();     // ← L81，异常直接穿出 ensureLoaded
try {                                          // ← L90 才开始兜
  final List<StockConfig> fetched = await _source.fetchSymbols(httpGet: _httpGet);
```

`_readCache()` → `FileKeyValueStore.read` → `_load()` → `await _file()`（`local_store.dart:98-102`）。`_file()` 依赖 `getApplicationSupportDirectory`（path_provider 平台通道），一旦抛 `PlatformException` / `MissingPluginException`，`_load()` 里 `local_store.dart:109` 那行在 `try`（L111 起）之前，异常原样上抛 → `ensureLoaded` 的 `try` 也在它后面（L90）→ 穿到 `_WatchlistSheetState._prepareDirectory`（`watchlist_sheet.dart:156`，无 try）→ 被 `initState` 里的 `unawaited(...)`（L88）吞成一条引擎级 unhandled error。**症状是"订阅弹层打开后本地搜索永远为空，且没有任何日志"**。

**为什么单列一条**：没有钩子时，上面两条都只在 logcat 里留一行 `Unhandled Exception`，release 包里用户和你都看不到。这不是"崩溃风险"，是**可观测性缺口**——而它会让其余所有 P1/P2 的线上复现都变成猜。

**修复方案**：

```dart
// main.dart —— 在 ensureInitialized() 之后、任何业务代码之前
import 'dart:ui' show PlatformDispatcher;

void installErrorHooks() {
  final FlutterExceptionHandler? previous = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    previous?.call(details);                    // debug 下保留红屏/console
    AppLog.e('FlutterError: ${details.exceptionAsString()}\n${details.stack}');
    // 上报：Sentry / 自建，release 才发
  };
  // 覆盖 platform-channel / 引擎侧异步错误。返回 true = 已处理，不再打默认日志
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    AppLog.e('Uncaught async: $error\n$stack');
    return true;
  };
}
```

> 不要再用 `runZonedGuarded` 作为唯一手段：它收不到 platform-channel 的异步错误（这正是 checklist 里点名的那条）。上面两个钩子是 Flutter 3.3+ 的正解。

**量化影响**：上线后 unhandled error 从"0 条可见记录"变为"可计数、可归因"；配合 P2-6 的修复可把"订阅弹层本地搜索静默失效"变成一条明确错误。

---

### P1-3 详情弹层把整块内容塞进 `BackdropFilter`，且监听器在最外层：每 3 秒一次全层重建 + 全屏级模糊重跑

**位置**：`lib/widgets/quote_detail_sheet.dart:210-221` · `_QuoteDetailSheetState.build`；`lib/widgets/glass.dart:576-580, 651` · `GlassPanel.build`
**严重度**：P1
**维度**：UI
**证据**：

```dart
// quote_detail_sheet.dart:210 —— 监听器包在玻璃**外面**
ValueListenableBuilder<Quote>(
  valueListenable: widget.quote,            // 每 3s 必变
  builder: (BuildContext context, Quote q, Widget? child) {
    return GlassPanel(                      // ← 玻璃在监听器内部重建
      radius: 30, blur: 18,
      child: SingleChildScrollView(         // ← K 线图 / 8 格指标 / 页脚全在里面
        child: Column(children: [...KlineChart, _Metrics, _StatusRow...]),

// glass.dart:576 —— 内容确实是 BackdropFilter 的子节点
child: ClipRRect(
  child: BackdropFilter(
    filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
    child: DecoratedBox(child: Stack(children: [
      ...,
      Padding(padding: padding, child: child),   // ← L651：内容没有独立图层
    ])),
```

**为什么是问题**：本项目在列表卡片上已经把这件事论证清楚并落地了——

```dart
// quote_tile.dart:59-68（原文）
// 试验过「把 RepaintBoundary 放进玻璃内部」，实测无效——玻璃的画笔会
// 把子内容一起画进自己的图层，内容一变，整块玻璃（背景捕获 + 折射
// 着色）就得重跑一遍。
// 拆成 Stack 后，玻璃只负责「背景 + 边沿光学」，内容在自己的图层里更新
```

`test/paint_isolation_test.dart:37-60` 也为卡片立了不变量（"价格文本不能在玻璃子树里"）。**但弹层没有享受这条结论**：`GlassPanel` 的 `Padding(child: child)` 让内容与 `BackdropFilter` 同层，`ValueListenableBuilder` 又在玻璃外面。结果每 3 秒：

1. 整个弹层重建（`_Header` + `_ChartSection` + 8 个 `_Metric` + `_StatusRow`，约 200 个 Widget）；
2. `KlineChart` 收到新列表 → `shouldRepaint` 为真（见 P1-4）→ 图表重绘；
3. 图表是 `BackdropFilter` 的子节点且无独立图层 → `markNeedsPaint` 一路上浮到 `BackdropFilterLayer` → **`sigma=18` 的模糊在 520×0.86 屏高的区域上重跑一次**并重新录制整块面板的 picture。

同一份代码在卡片上被判为"必须避免的最贵一步"，在这里每 3 秒发生一次。

**修复方案**（两处，都是小改）：

```dart
// ① glass.dart：给内容一个独立图层，重绘不再回灌 BackdropFilter
class GlassPanel extends StatelessWidget {
  const GlassPanel({..., this.isolateChild = true});
  final bool isolateChild;

  // build 内：
  Padding(
    padding: padding,
    child: isolateChild ? RepaintBoundary(child: child) : child,
  ),
}

// ② quote_detail_sheet.dart：把监听器下沉，玻璃只建一次
Align(
  alignment: Alignment.bottomCenter,
  child: ConstrainedBox(
    constraints: BoxConstraints(maxWidth: 520, maxHeight: MediaQuery.sizeOf(context).height * 0.86),
    child: GlassPanel(
      radius: 30, blur: 18,
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
      child: ValueListenableBuilder<Quote>(     // ← 挪到玻璃内部
        valueListenable: widget.quote,
        builder: (BuildContext context, Quote q, Widget? _) => SingleChildScrollView(
          child: Column(...),
        ),
      ),
    ),
  ),
)
```

> 注意：① 与 ② 是**互补**而不是二选一。② 省掉"重建玻璃 Widget"（便宜），① 才是省掉"重跑模糊"（贵）。只做 ② 不解决问题——子树重建后图表仍会重绘，重绘仍会顶到 `BackdropFilterLayer`。

**量化影响**（估算，需 `--profile` + `FrameTiming` 复核）：弹层在盘中打开时，每 3 秒一次的面板级 blur（约 1560×2100 px @3x）通常值 4~8ms raster；修复后这笔开销从"每次跳价"降为"仅弹层打开/尺寸变化时一次"。若弹层停留 5 分钟 = 100 次跳价，约省 0.4~0.8s 的 GPU 时间，并消除每 3 秒一次的可见微顿。

---

### P1-4 日 K 的 `RepaintBoundary` 被"每次 tick 新建列表"打穿：240~480 根蜡烛每 3 秒重新栅格化

**位置**：`lib/widgets/kline_chart.dart:914-920` · `_KlinePainter.shouldRepaint`；`lib/widgets/quote_detail_sheet.dart:236-238` · `build` 内 `patchTodayBar`；`lib/widgets/kline_chart.dart:139-151` · `patchTodayBar`
**严重度**：P1
**维度**：UI
**证据**：

```dart
// kline_chart.dart:296-314 —— 设计意图写得很清楚
// 日K 是静态图（只在换股票/翻页时变），单独成层：弹层里价格每秒
// 跳动时，重绘止步于文本层，不会连带这张图重新栅格化。
final Widget chart = CustomPaint(painter: _KlinePainter(...));
child: mode == ChartMode.daily ? RepaintBoundary(child: chart) : chart,

// kline_chart.dart:914 —— 但判据是指针相等
bool shouldRepaint(_KlinePainter old) {
  return old.mode != mode ||
      !identical(old.bars, bars) ||      // ← 每次 build 都是新 List
      !identical(old.points, points) ||
      old.prevClose != prevClose;
}

// quote_detail_sheet.dart:236 —— 每次 build 都调用，且必然返回新 List
bars: _mode == ChartMode.daily
    ? patchTodayBar(_daily?.items ?? const <Kline>[], q)
    : const <Kline>[],

// kline_chart.dart:139 —— 两个分支都 new 一个 List（只有末尾元素是新的）
return <Kline>[...bars.sublist(0, bars.length - 1), Kline(...)];   // 同日覆盖
return <Kline>[...bars, today];                                    // 追加
```

**为什么是问题**：`identical` 对"内容相同但新建的 List"永远为 false，于是 `RepaintBoundary` 的光栅缓存每 3 秒失效一次，`_paintDaily` 完整重跑：480 根蜡烛逐根 `drawLine` + `drawRRect`、两条 MA 折线（`movingAverage` 每次重算两遍 O(n)）、480 个量柱（还带一次排序，见 P2-3）、6 个 `TextPainter`。**日 K 模式下（用户正在"看历史"时）这笔开销每次都白付**，因为除了最后一根，其余 479 根一个像素都没变。

**修复方案**（主选：在弹层里按内容记忆化，同时省掉 O(n) 复制）：

```dart
// quote_detail_sheet.dart —— State 里加两个字段
List<Kline>? _barsCache;
Object? _barsCacheKey;   // (源列表 identity, 价格, 时间戳, 当日开高低量)

List<Kline> _barsFor(Quote q) {
  final List<Kline> src = _daily?.items ?? const <Kline>[];
  final Object key = (identityHashCode(src), q.price, q.timestamp,
                      q.open, q.high, q.low, q.volume);
  if (_barsCacheKey == key && _barsCache != null) return _barsCache!;
  _barsCacheKey = key;
  return _barsCache = patchTodayBar(src, q);
}
```

（次选，若不想动弹层：把 `shouldRepaint` 换成 O(1) 尾部指纹——`bars.length` + 末根 `time/close/high/low/volume` 全等即视为未变。两种都可行，但主选还能顺带省掉每 tick 一次 480 元素的 List 分配。）

**量化影响**：日 K 模式下，每次跳价省去 1 次 ~480 根的全量重栅格化（估算 3~8ms raster，真机需复核）与 1 次 480 元素 List 分配、2 次 MA 重算；弹层停留 5 分钟约省 100 次。

---

### P1-5 太极徽标在交易时段是 60fps 常驻动画，且每帧重跑一次 maskFilter 阴影

**位置**：`lib/widgets/taiji_mark.dart:119-132` · `_syncSpin`；`:143-163` · `build`；`:57-60` · `AnimationController`
**严重度**：P1（前台空闲功耗 / LTPO 降频）
**维度**：UI / 后台
**证据**：

```dart
// L57 —— 12 秒一圈，repeat() 意味着 60fps 连续出帧
_spin = AnimationController(vsync: this, duration: const Duration(seconds: 12));

// L119 —— 只要有一个订阅市场在交易（09:15–15:00 + 港股到 16:10），就一直在转
void _syncSpin() {
  if (_reduceMotion) { _spin.stop(); return; }
  if (_anyLive(widget.now())) {
    if (!_spin.isAnimating) _spin.repeat();    // ← 一整天
  } else {
    _spin.stop();
  }
}

// L143 —— 每帧重建 Transform，child 里有 BoxShadow(blurRadius: 12)
return AnimatedBuilder(
  animation: _spin,
  builder: (context, child) => Transform.rotate(angle: _spin.value * 2 * pi, child: child),
  child: Container(decoration: const BoxDecoration(shape: BoxShape.circle,
      boxShadow: <BoxShadow>[BoxShadow(color: Color(0x1A213A5C), blurRadius: 12, offset: Offset(0, 4))])),
);
```

**为什么是问题**：`child` 里带 `BoxShadow`，`BoxDecoration` 的阴影是用 `MaskFilter.blur` 画的——**每次绘制都要执行一次模糊**。`Transform` 没有独立图层，旋转会导致子树每帧重绘。于是交易时段（每天约 5.5 小时）内：60fps × 每小时 → 约 120 万次/天的 36×36 模糊 + picture 重录 + 持续 vsync 唤醒。**应用在这段时间内无法进入任何 idle 状态，LTPO 面板也无法降到 1~10Hz。**

这条恰好落在项目自己承认的测量缺口里（README:L1449「盘中刷新帧率未测」），而 README:L1445 的"静置 0 帧"与 `perf_probe.dart:19-21` 记录的 gfxinfo 缺陷冲突，不能采信。

**修复方案**（两件事一起做，收益相乘）：

```dart
// ① 给被旋转的内容一个图层：变换交给合成器，不重绘不重模糊
child: RepaintBoundary(
  child: Container(width: widget.size, height: widget.size, decoration: ..., child: const CustomPaint(painter: _TaijiPainter())),
),

// ② 把"永远在转"改成"来一条行情转一格"——语义更准（原来的注释自己写了
//    「数据本来就不动，图标还在转就是在撒谎」），出帧从 60fps 降到 ~0.33fps
void boost() {
  if (!mounted || _reduceMotion) return;
  if (!_anyLive(widget.now())) return;
  _spin.animateTo(
    _spin.value + 1 / 48,                       // 每 3s 转 7.5°，一天转满几圈
    duration: const Duration(milliseconds: 260),
    curve: Curves.easeOutCubic,
  );
}
```

`boost()` 挂在页面已有的行情回调上（`_onQuotes` 里对所有卡片批量更新之后调一次即可，无需新订阅），`Timer.periodic(30s)` 与 `repeat()` 一并删除。

**量化影响**（估算）：交易时段内 raster 出帧数从 60/s 降到 0.33/s（约 −99.5%）；按 36×36 的 mask blur + 一次 picture 录制估 0.15~0.4ms/帧，5.5 小时累计约省 200~500 秒的 GPU 时间与持续唤醒。**功耗收益远大于帧时收益**——它是"能不能让屏幕进低刷"的开关。

---

### P1-6 `_measure()` 每次绘制都 `new TextPainter` 且从不 `dispose`

**位置**：`lib/widgets/kline_chart.dart:898-912` · `_measure` / `_text`
**严重度**：P1
**维度**：内存
**证据**：

```dart
TextPainter _measure(String text, Color color) {
  final TextPainter tp = TextPainter(
    text: TextSpan(text: text, style: axisStyle.copyWith(color: color)),
    textDirection: TextDirection.ltr, maxLines: 1,
  )..layout();
  return tp;                       // ← 没有 dispose()
}

void _text(Canvas canvas, String text, Offset offset, Color color) {
  _measure(text, color).paint(canvas, offset);   // ← 用完即弃
}
```

调用点：`_priceLabel` ×3、`_timeLabels` ×3（每次 `_measure` 两次）、`_dayLabels` ×3、`_maLegend` ×2 → **单次 `paint` 约 6~11 个 `TextPainter`，每个都持有一份已 layout 的 `ui.Paragraph`（native 内存，不归 Dart GC 及时回收）**。

**为什么是问题**：`TextPainter.dispose()` 的作用就是释放底层 `Paragraph`。不 dispose 时，native 侧要等 Dart 对象的 finalizer 排队才回收。详情弹层里图表会因为 P1-4（每次跳价）和用户滚动（`SingleChildScrollView` 整屏重绘）反复 `paint`：滚动 1 秒 = 60 帧 × 10 个 paragraph ≈ 600 个/秒的 native 分配。这不是"泄漏"，是**持续的 native 内存抖动**，直接抬高 GC 压力与 RSS 尖峰——也就是 README 里承认"未测"的那项"长时内存增长"。

**修复方案**：

```dart
void _text(Canvas canvas, String text, Offset offset, Color color) {
  final TextPainter tp = TextPainter(
    text: TextSpan(text: text, style: axisStyle.copyWith(color: color)),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  try {
    tp.paint(canvas, offset);
  } finally {
    tp.dispose();          // 关键：释放底层 Paragraph
  }
}

// 需要宽度的两处（_timeLabels / _dayLabels / _maLegend）同理，改为：
// final TextPainter mp = ...; try { ... } finally { mp.dispose(); }
```

**量化影响**（估算）：滚动/跳价路径上消除约 600 个/秒的 `Paragraph` native 分配；单帧 native 峰值下降数十 KB 量级，长时运行的 RSS 曲线更平（该项需 `./tool/perf_bench.sh` 做 30 分钟长时采样才能给出确定数字，**此处不作为已测结论**）。

---

### P2-1 `_readCache()` 在 `try` 之外：本地目录读取异常直接穿透成 unhandled error

**位置**：`lib/services/symbol_directory.dart:81` · `ensureLoaded`
**严重度**：P2（与 P1-2 是同一根因的两个面：一层没兜住 + 全局没钩子）
**维度**：崩溃
**证据**：

```dart
// L81：这一行在 try 之前
final _Cache? cache = await _readCache();

if (!force && cache != null && !_isStale(cache.savedAt)) { ... return; }

try {                                                    // L90 才开始兜
  final List<StockConfig> fetched = await _source.fetchSymbols(httpGet: _httpGet);
} on SymbolFetchException catch (e) { ... }
  on Object catch (e) { ... }                            // 注释还特意写了"必须连 Error 一起拦"
```

`_readCache()`（L199-235）里 `jsonDecode` 有 `on FormatException` 兜底，类型也有 `is!` 守卫——**唯一没兜的是 `await _store.read(storageKey)` 本身**（磁盘/平台通道异常）。

**修复方案**：

```dart
Future<void> ensureLoaded({bool force = false}) async {
  if (_loaded && !force) return;
  if (!force && _lastFailureAt != null &&
      _now().difference(_lastFailureAt!) < AppConfig.symbolRetryCooldown) return;

  _Cache? cache;
  try {
    cache = await _readCache();          // 读缓存失败 == 没有缓存，不该中断整条流程
  } on Object catch (e) {
    AppLog.w('目录缓存读取失败，按无缓存处理: $e');
  }
  ...
}
```

**量化影响**：把"订阅弹层本地搜索永久为空 + 无日志"变成"降级为纯远端搜索 + 一条 W 日志"。

---

### P2-2 195KB 股票目录在主 isolate 上 `jsonDecode`，且写盘时被再编码一遍

**位置**：`lib/services/symbol_directory.dart:205`（`jsonDecode`）、`:239-248`（`_writeCache`）；`lib/services/local_store.dart:153-158`（`_writeAll` 再 `jsonEncode` 整个 Map）
**严重度**：P2
**维度**：后台 / 启动
**证据**：

```dart
// symbol_directory.dart:205 —— 5577 行 × [code, region, name]，约 195KB
final Object? decoded = jsonDecode(raw);

// :239 写缓存时先 encode 成字符串
final List<List<String>> rows = items.map((s) => <String>[s.code, s.region, s.name]).toList();
await _store.write(storageKey, jsonEncode(<String, Object>{'savedAt': ..., 'rows': rows}));

// local_store.dart:156 —— 然后整个 Map（含那 195KB 字符串，带转义）再 encode 一次
await tmp.writeAsString(jsonEncode(data), flush: true);
```

**为什么是问题**：`jsonDecode` 195KB / 5577 行的成本在中端机上通常 10~25ms，**超过一帧预算**。它发生在 `_WatchlistSheetState._prepareDirectory`（`watchlist_sheet.dart:88` 的 `unawaited`）→ 打开订阅弹层的首帧时正好撞上。写盘路径更浪费：195KB 的 JSON 字符串被当作 Map 的一个 value，再被 `jsonEncode` 转义一遍（`\"` → `\\\"`），实际编码量翻倍，约 400KB 的字符串工作在 main isolate 上做一次（30 天一次，可接受但没必要）。

**修复方案**（解码进 isolate，编码只做一次）：

```dart
// ① 解码offload：Isolate.run 一次性任务（Flutter 3.7+，无需自己管 kill）
final List<StockConfig> items = await Isolate.run(() => _decodeRows(raw));

static List<StockConfig> _decodeRows(String raw) {
  // 原 _readCache 的解析逻辑整体搬进来（纯函数，无 Flutter 依赖）
}

// ② 写盘：直接写"已编码好的 payload"，别让 KV 层再包一层 JSON
//    KeyValueStore 增加 writeRaw(key, String) / readRaw(key)，
//    文件格式改为 { "watchlist.v1": "...", "symbols.v1": "<原始 JSON>" }? 
//    —— 更简单：给 FileKeyValueStore 加一个"每 key 一文件"模式，
//    大 value 单独落盘，绕开整份 Map 的二次编码。
```

**量化影响**：打开订阅弹层的 UI 线程阻塞从 10~25ms 降到 ~0（isolate）；写盘编码量减半。

---

### P2-3 `_paintVolume` 每次绘制都复制并排序整个量数组

**位置**：`lib/widgets/kline_chart.dart:764-765` · `_paintVolume`
**严重度**：P2
**维度**：UI
**证据**：

```dart
final List<double> sorted = <double>[...volumes]..sort();       // 复制 + O(n log n)
final double maxVol = sorted[((sorted.length - 1) * 0.95).round()];
```

**为什么是问题**：分时 240 点 / 日 K 480 根，每次 `paint` 一次复制 + 一次排序（480 元素约 20~40µs，加上 480 次 double 装箱——`List<double>` 在 Dart 上是未装箱的 `Float64List` 友好类型，但 `<double>[...]` spread 会分配普通 growable list）。它本身不致命，**但它和 P1-5（TextPainter）、P1-4（每 tick 重栅格化）叠加在同一个 paint 里**，一起构成"每 3 秒一次的固定开销"。

**修复方案**：p95 只在**数据变化时**算一次，缓存进 painter 的构造参数（painter 每次 build 新建，但 build 频率远低于 paint 频率——滚动时尤其明显）：

```dart
// 在 _KlinePainter 构造时算好，paint 里直接用
_KlinePainter({...}) : _volP95 = _p95(barVolumes);
// 或者更省：既然只是"截顶基准"，用 O(n) 选择第 k 大（quickselect）代替全排序
static double _p95(List<double> v) {
  if (v.isEmpty) return 0;
  final List<double> c = List<double>.of(v, growable: false)..sort();
  return c[((c.length - 1) * 0.95).round()];
}
```

**量化影响**：每次 paint 省一次 480 元素分配 + 排序（约 20~40µs），在弹层滚动（60fps）时约 1.2~2.4ms/s。

---

### P2-4 `KlineLoader._cache` 无上限、无淘汰、无生命周期

**位置**：`lib/services/kline_loader.dart:31` · `_cache`；`:68` · `clear()`
**严重度**：P2（长时内存增长）
**维度**：内存
**证据**：

```dart
/// key = `000001@SZ|daily`，value = 数据 + 过期时间
final Map<String, _Entry<Object>> _cache = <String, _Entry<Object>>{};   // 无容量上限
...
void clear() => _cache.clear();     // 只有"手动重试"会调（quote_detail_sheet.dart:191）
```

key 里带 `count`（`<${stock.key}|daily|$n>`），而 `n` 可以是 80/160/240/320/400/480 六档。**满配额 30 只 × (1 份分时 + 6 档日线) = 210 个 key**，每份 240~480 个 `Kline`（约 48B/个）→ 最坏约 30×7×400×48B ≈ **4MB**。过期条目不会被主动清，只在同 key 再次请求时被覆盖。对一个"长时挂前台盯盘"的应用，这是 README 自称"未测"的那项风险里唯一有确定上界的一条。

**修复方案**（LRU，20 行以内）：

```dart
static const int _maxEntries = 12;   // 当前股票 + 来回切的几档足够

void _put(String key, _Entry<Object> entry) {
  _cache.remove(key);                  // 先删再插 = 移到队尾（LinkedHashMap 保序）
  _cache[key] = entry;
  while (_cache.length > _maxEntries) {
    _cache.remove(_cache.keys.first);  // 淘汰最久未用
  }
}
```

配一条单测：连续请求 20 个不同 key 后 `_cache.length == 12` 且最早的那个已被淘汰。

**量化影响**：把缓存上限从"无界（实测最坏 ~4MB）"钉到"≤12 份（~1MB）"。

---

### P2-5 订阅弹层每次 `setState` 都在 5200+ 条目录上做一次线性搜索

**位置**：`lib/widgets/watchlist_sheet.dart:246`（`build` 里调 `_merge`）、`:169-185` · `_merge`；`lib/services/symbol_directory.dart:165-195` · `search`
**严重度**：P2
**维度**：UI
**证据**：

```dart
// watchlist_sheet.dart:245-246 —— 每次 build 都算一遍
final String query = _query.text.trim();
final List<StockConfig> results = _merge(query);

// symbol_directory.dart:177 —— 四条全表扫描
for (final StockConfig s in _items) {
  if (s.code == query) { exact.add(s); }
  else if (s.code.startsWith(query)) { codePrefix.add(s); }
  else if (s.name.startsWith(query) || s.name.startsWith(upper)) { namePrefix.add(s); }
  else if (s.name.contains(query)) { nameContains.add(s); }
}
```

**为什么是问题**：`_query.addListener(_onQueryChanged)`（L87）→ `setState` → `build` → `_merge` → 5200 次 `startsWith`/`contains`。中文输入法打一个词会连续触发 `onChanged`，每次约 0.2~0.5ms（`contains` 走 UTF-16 子串匹配，中文不便宜）。单独看不致命，但它和 `ListView(shrinkWrap: true)`（P2-6）叠在同一次 `setState` 里，构成"打字时每键 ~2~4ms"的固定成本。

**修复方案**（按 query 记忆化，最简单的正确做法）：

```dart
// _WatchlistSheetState 里加缓存，keyed by (query, 目录是否刚加载完)
String _cachedQuery = '';
List<StockConfig> _cachedResults = const <StockConfig>[];

List<StockConfig> _resultsFor(String query) {
  if (query == _cachedQuery && _directoryVersionSeen == widget.directory.count) {
    return _cachedResults;
  }
  ...
}
```

（更彻底的做法是建 `Map<String, List<StockConfig>>` 的代码/拼音首字母倒排索引，但对 5200 条 + 单用户场景属于过度设计——**按 query 缓存一次就够**。）

**量化影响**：同一次输入过程中，重复 build（键盘弹起、焦点变化、`setState(_hint)`）不再重扫全表；打字路径每次省 0.2~0.5ms。

---

### P2-6 订阅弹层用 `ListView(shrinkWrap: true, children: [...])`：全量构建 + 一次无谓的全高测量

> ⚠️ **本条已撤回（2026-11-05 10:30）**：`shrinkWrap` 不是性能冗余，而是"弹层贴合内容高度"
> 的实现手段，去掉会让弹层撑满 0.82 屏（golden 当场打红）。详见 §10.4。保留原文是为了记录
> 当时的判断，不要照着改。

**位置**：`lib/widgets/watchlist_sheet.dart:358-407` · `build`
**严重度**：P2
**维度**：UI
**证据**：

```dart
Flexible(
  child: ScrollFrameRate(
    controller: appFrameRateController,
    child: ListView(
      shrinkWrap: true,                                  // ← 强制量出全部子项高度
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      children: <Widget>[                                // ← 非懒加载：全部立刻 build
        if (query.isNotEmpty) ... 搜索结果（≤12 条 + 空态 + 手输行）,
        _SectionLabel('当前订阅（${_stocks.length}/${widget.quota}）'),
        for (final StockConfig s in _stocks) _CurrentRow(...),   // ← 最多 30 行
        ...
      ],
    ),
  ),
),
```

**为什么是问题**：`shrinkWrap: true` 会让 `ListView` 先测量全部子项。满配额 30 只 + 12 条搜索结果 ≈ 45 行 × (Row + 2 Text + IconButton) ≈ 250 个 Widget **在每次按键时全部重建并重新布局**。这正是"`ListView.builder` 懒加载"要避免的形状，而这里因为外层已经是 `Flexible`（有确定约束），`shrinkWrap` 完全不必要。

**修复方案**：

```dart
Flexible(
  child: ScrollFrameRate(
    controller: appFrameRateController,
    child: ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      itemCount: 1 + _rows.length,            // _rows 是预先拼好的 List<Widget> 也行
      itemBuilder: (BuildContext context, int i) => _rows[i],
    ),
  ),
)
```

（`shrinkWrap: true` 去掉是安全的：`Flexible` 在 `Column` 里给的是有界高度，`ListView` 不需要靠 `shrinkWrap` 求高。若担心"内容不足一屏时列表贴顶"，用 `Column` 尾部补一个 `Spacer` 或 `Align` 即可，不必牺牲懒加载。）

**量化影响**：按键路径上的 build 数量从 ~250 个 Widget 降到 ~15 个（可见行）；弹层首帧构建时间预计降 60~75%（估算，需 `--profile` 复核）。

---

### P2-7 `applicationId` 仍是 `com.example.super_market`

> ✅ **已决策：维持现值（2026-11-05 10:42，用户拍板）**。包名保持 `com.example.super_market`，
> 理由写进了 `build.gradle.kts` 的注释（换 id = 断覆盖升级 + 存档不跟随；当前只有本机一个用户、
> 不进商店）。本条从待办列表移除，不再作为问题项。

**位置**：`android/app/build.gradle.kts:28` · `defaultConfig`
**严重度**：P2（分发/上架阻塞，非性能）
**维度**：APK
**证据**：

```kotlin
defaultConfig {
    // TODO: Specify your own unique Application ID ...
    applicationId = "com.example.super_market"
```

**为什么是问题**：`com.example.*` 被 Google Play 明确拒绝；即便只自用分发，它也与产物名（`itick-quote-1.0.0-plus27.apk` / `super market.apk`）、包名（`super_market`）、应用名（超级市场）四者互不一致，将来任何一次改名都会断掉"覆盖安装"路径（用户得先卸载，本地存档随 `applicationId` 一起没了）。

**修复方案**：**一次性定死，越早越便宜**。

```kotlin
namespace = "cn.iloat.supermarket"        // 与 applicationId 保持一致
defaultConfig {
    applicationId = "cn.iloat.supermarket"   // 反查确认无人占用
```

代价说明（必须提前告知）：改 `applicationId` = 换应用身份，**已装用户无法覆盖升级**，存档（`getApplicationSupportDirectory()` 下的 `*_state.json`）也不会自动迁移。若已有真实用户，要么接受"卸载重装"，要么写一段首启迁移（旧目录 → 新目录）。**如果这个包只自用，现在改的成本是 0；等有了 10 个用户再改就是 P1。**

---

### P3-1 APK 里残留 53KB 的 Kotlin 元数据

**位置**：`build/app/outputs/flutter-apk/app-release.apk`（`kotlin/**`、`kotlin-tooling-metadata.json`、`DebugProbesKt.bin`）
**严重度**：P3
**维度**：APK
**证据**（`unzip -l` 实测）：

```
30920  kotlin/kotlin.kotlin_builtins
 8625  kotlin/collections/collections.kotlin_builtins
 4859  kotlin/reflect/reflect.kotlin_builtins
 4353  kotlin/ranges/ranges.kotlin_builtins
 2882  kotlin/concurrent/atomics/atomics.kotlin_builtins
 1022  kotlin/annotation/annotation.kotlin_builtins
  596  kotlin/internal/internal.kotlin_builtins
  139  kotlin/coroutines/coroutines.kotlin_builtins
TOTAL 53396
```

这些是 Kotlin 编译器的 `.kotlin_builtins` 声明文件，运行期完全用不到（R8 不会剔除非 class 资源）。`kotlin-tooling-metadata.json` 与 `DebugProbesKt.bin` 同理。

**修复方案**：

```kotlin
// android/app/build.gradle.kts，android { } 内
packaging {
    resources {
        excludes += setOf(
            "kotlin/**",
            "kotlin-tooling-metadata.json",
            "DebugProbesKt.bin",
            "META-INF/*.version",
        )
    }
}
```

**量化影响**：APK 减约 55KB（0.3%）。**这是"顺手做"级别的收益**，列出来是因为它零风险且 `tool/verify_apk.py` 可以直接加一条断言守住。

---

### P3-2 所有日志在 release 包里仍然输出

**位置**：`lib/utils/app_log.dart:22-27` · `_write`
**严重度**：P3
**维度**：APK / 后台
**证据**：

```dart
static void i(String message) => _write('I', message);
static void w(String message) => _write('W', message);
static void e(String message) => _write('E', message);
static void d(String message) { if (kDebugMode) _write('D', message); }   // 只有 d 有门禁

static void _write(String level, String message) {
  final String now = DateTime.now().toIso8601String();
  final String time = now.length >= 23 ? now.substring(11, 23) : now;
  debugPrint('$time [$level] $tag | $message');    // ← debugPrint 在 release 仍走 print
}
```

**为什么是问题**：`debugPrint` 不是 `assert`，release 下照常打印到 logcat（有 12ms 节流）。当前调用频率低（只在状态跃迁时打，3s 轮询不刷屏），**实际影响很小**；但 `AppLog.d` 已经做了门禁、`i/w/e` 没做，这个不一致会让后来人以为"release 不打日志"，从而把敏感信息（URL、股票代码、错误详情）写进 `i()`。

**修复方案**：

```dart
static void _write(String level, String message) {
  debugPrint(...);                     // 保留：debug/profile 的可读日志
}
// 若要 release 静默：
static void i(String m) { if (!kReleaseMode) _write('I', m); }
// 若要 release 也留 W/E（推荐）：只给 i/d 加门禁，W/E 保留但去掉时间戳开销
```

**量化影响**：可忽略的 CPU；收益是"日志纪律"本身——release 包里不该有的字符串不出现在 logcat。

---

### P3-3 页头秒表每秒 `setState`：前台永久 1fps 唤醒

**位置**：`lib/pages/quote_list_page.dart:562-567` · `_ClockTitleState.startTicking`
**严重度**：P3（产品要求，仅提示成本）
**维度**：UI / 后台
**证据**：

```dart
_timer = Timer.periodic(const Duration(seconds: 1), (_) {
  final String ticked = formatClock(widget.now());
  if (ticked != _text && mounted) {
    setState(() => _text = ticked);      // ← 每秒一帧
  }
});
```

**为什么提**：`_ClockTitle` 已包在 `RepaintBoundary`（`quote_list_page.dart:439`）里，所以重绘范围只有那一行文字——这点做对了。但 `setState` 会**调度一帧**，也就是应用在前台**永远不可能 30 秒 0 帧**。这与 README:L1445 的"静置 30s 0 帧"直接冲突（见第 1 节的判定）。

**修复方案**（可选，取决于产品取舍）：非交易时段把周期放到 30s（秒数在收盘后没有信息量），或把秒表改成"分钟级 + 冒号呼吸"。**若产品上必须每秒跳，保留现状即可，但应得知：`perf_bench` 的"静置帧数"指标对前台永远不成立，不能用它证明空闲。**

**量化影响**：60 帧/分钟 → 2 帧/分钟（非交易时段）；对 LTPO 降频有实际意义。

---

## 3. 亮点（已经做对、不要动的部分）

1. **首帧与初始化彻底解耦**。`main()` 在 `runApp` 之前只做三件不阻塞的事（`installFrameProbe` 在未开 `PERF_LOG` 时第一行 return），所有读盘/建连都压进 `initState` 的 `addPostFrameCallback`（`quote_list_page.dart:105-109`）。实测首帧 → 首个报价 68ms，属于教科书级。

2. **解析层的防御是"三层"而不是"一层"**。字段数守卫（`sina_source.dart:124-133` 明确写了"33 而不是 32，否则 32 字段的变体报文会 RangeError"）→ 单字段 `_num()` 过滤 `NaN/Infinity`（`:318-327`）→ 时间戳范围钉死（`:301-314`，连"DateTime 对超界值不抛"这个坑都写在注释里）。全仓库只有 3 处 `!`，且都有前置守卫（`tencent_source.dart:204-207`、`kline_chart.dart:110-115`、`symbol_directory.dart:77`）。

3. **玻璃分层这件事，卡片上做到了极致并留下测试看守**。`quote_tile.dart:69-131` 把玻璃做成背景层、内容进 `RepaintBoundary`，`test/paint_isolation_test.dart:37-60` 用结构断言守"价格文本不能在玻璃子树里"。这是我在同类项目里极少见到的——**不变量被写成了测试，而不只是注释**。

4. **生命周期/定时器的纪律统一通过 mixin 固化**。`LifecyclePause`（`lifecycle_pause.dart:15-46`）强制 `startTicking / stopTicking` 成对，且注释写明"只 cancel 不置空 = 引用还在，等于没释放"。三处周期任务的 `stopTicking()` 全部 `cancel + null`。

5. **`Quote` 的值相等 + `ValueNotifier` 的 `==` 短路**（`models/quote.dart:189-207`）。收盘后同值报文进来不触发重建——这正是 README:L1445"收盘静置"能成立的原因。多数项目会漏掉这一步，然后靠"少建 Widget"来凑。

6. **构建链是完整的，且有产物闸门**。`minifyEnabled + shrinkResources`（`build.gradle.kts:70-73`）、单 ABI（`:88-115`，还写清了"`ndk.abiFilters` 对 AAR 里的 .so 无效"这个真坑）、`--obfuscate + --split-debug-info`（`build_apk.sh:21-24`）、`tool/verify_apk.py` 校验 ABI/R8 保留类/数据源是否真的打进去。17.5MB 的产物里 11.2MB 是引擎、4.4MB 是 AOT 代码，**没有一字节是配置失误造成的**。

---

## 4. 六维评分

| 维度 | 分数 | 依据 |
|---|---|---|
| 内存 | **85** | 唯一 P0 在 notifier 重建；KlineLoader 无上限；TextPainter 不 dispose。其余（无图片、无 Isolate、无 StreamSubscription、`addListener/removeListener` 严格成对、BuildContext 跨 async 全部有 `mounted` 检查）干净。实测 PSS 134MB 达标 |
| 崩溃 | **72** | 缺全局钩子（唯一系统性缺口），且存在两条已证的穿透路径；但解析层/边界层的 `on Object` 兜底密度非常高，`!` 只有 3 处且都有守卫。扣分全在"可观测性"，不在"防御" |
| UI | **74** | 列表侧是 A 级（玻璃分组、cacheExtent 收到 120、监听器下沉、有测试守）；弹层侧是三处倒退（玻璃包内容、日 K 重栅格化、每帧 TextPainter）；外加交易时段 60fps 常驻动画。build 侧 p50 0.8~1.2ms 说明重建量本身不是问题，**是重绘/光栅的边界没划对** |
| 启动 | **92** | 实测 320ms，`initialize()` 实测 3ms（推翻了"预热拖慢启动"的猜测），首帧前零 IO。扣分只因为"单页无路由"意味着这部分没有可复用的懒加载结构，将来加第二个页面时容易退步 |
| 后台 | **86** | 退后台主动断轮询、CPU 0%、三个周期任务全部随生命周期停表——这套纪律很完整。扣分：195KB JSON 在主 isolate 解码、前台 1fps 常驻 |
| APK | **90** | 17.5MB，四个开关全开，依赖只有 `path_provider` + `liquid_glass_widgets`（后者带来 1.4MB 未压缩 shader / APK 内 ~300KB，是视觉的必要成本）。扣分：`com.example` 包名、53KB Kotlin 元数据残留 |

**加权总分：≈ 83 / 100**

---

## 5. 优先级整改清单 Top 10

| # | 问题 | 级别 | 预计工时 | 收益 | 风险 |
|---|---|---|---|---|---|
| 1 | 订阅列表编辑清空价格 + 旧 notifier 未 dispose（P0-1） | P0 | 0.5h | 消除每次编辑 1 帧全列表 `--`；不再有"未 dispose 的 notifier" | 极低（`putIfAbsent` 语义等价） |
| 2 | 全局错误钩子（P1-2） | P1 | 1h | 线上错误从"0 条可见"变"可计数"；两条已知路径可归因 | 低（`return true` 会吞掉默认日志，需确认上报链路在位） |
| 3 | 弹层玻璃分层 + 监听器下沉（P1-3） | P1 | 1h | 每 3s 一次面板级 blur（4~8ms）降为一次性 | 低（`RepaintBoundary` 只加图层不改像素，golden 应逐字节不变——与 `paint_isolation` 那次改造同理） |
| 4 | 日 K 记忆化 / O(1) 指纹（P1-4） | P1 | 1.5h | 每次跳价省 1 次 480 根全量重栅格化 | 中（记忆化的 key 必须覆盖 open/high/low/volume，否则会画出旧影线） |
| 5 | `TextPainter` dispose（P1-6） | P1 | 0.5h | 滚动路径上 −600 个/秒 native 分配 | 极低（`finally` 保证） |
| 6 | 太极改数据驱动 + RepaintBoundary（P1-5） | P1 | 2h | 交易时段出帧 60fps → 0.33fps，LTPO 才能降频 | 中（需要把 `boost()` 接到 `_onQuotes`，属交互变更，**须先确认视觉**） |
| 7 | `_readCache` 包 try（P2-1） | P2 | 0.2h | 本地搜索不再静默失效 | 极低 |
| 8 | 目录解码进 isolate（P2-2） | P2 | 1.5h | 打开订阅弹层少 10~25ms 主线程阻塞 | 低（解析函数是纯函数，直接搬） |
| 9 | 订阅弹层去 `shrinkWrap` + 按 query 缓存（P2-5/P2-6） | P2 | 1.5h | 按键路径 build 从 ~250 Widget 降到 ~15 | 低（需确认"内容不足一屏"时的贴顶表现） |
| 10 | `KlineLoader` LRU（P2-4） | P2 | 1h | 缓存上限从无界（最坏 ~4MB）钉到 ≤1MB | 低（配单测） |

**合计约 11 小时。** 建议按 1→5 先做一批（≈4.5h，全是低风险、可被现有 214 个用例回归的改动），6 单独立项（涉及视觉，按你的规矩要先看方案）；7~10 下一批。

---

## 6. 已评估但**判定不是问题**（避免下次重复排查）

| 项 | 结论 | 依据 |
|---|---|---|
| `await LiquidGlassWidgets.initialize()` 拖慢冷启动 | **不成立** | README:L1443 实测 **3ms**（.720→.723）；冷启动 320ms 已含它 |
| 冷启动 / 内存 / 滚动帧率 / 后台 CPU 超标 | **不成立** | 四项全部实测达标（第 1 节表） |
| 图片内存 / ImageCache 未调小 | **不适用** | 全仓库 0 处 `Image` / `ImageProvider` / `cacheWidth`（grep 空）；无 assets 图片，只有 4 个 32KB 的 Inter 字重 |
| Isolate 泄漏 / `compute` 未回收 | **不适用** | 全仓库 0 处 `Isolate` / `compute`（grep 空） |
| `StreamSubscription` 未 cancel | **不适用** | 全仓库 0 个 `StreamSubscription`；状态全部走 `ValueNotifier` + `ValueListenableBuilder`（自动退订） |
| `BuildContext` 跨 async 边界 | **已做对** | `_bootstrap`(L115)、`_openWatchlist`(L220)、`_load`(L111/124)、`_loadMore`(L157)、`_prepareDirectory`(L157)、`_search`(L136) 全部有 `mounted` 检查 |
| 全局单例持有 Widget/Context | **已做对** | 全局只有 `_sharedClient`、`appFrameRateController`、`AppLog.tag`、`FileKeyValueStore._instances`（key 有限）；无一处持有 Element/State |
| `setState` 作用域过高（列表页） | **已做对** | 列表页只在订阅变更时 `setState`；行情走逐标的 `ValueNotifier`；秒表/角标/太极各自成 State |
| `const` 缺失 | **未发现成规模问题** | `flutter_lints 6` + analyze 干净；抽查 `Text`/`SizedBox`/`EdgeInsets` 字面量均已 `const`。剩余重建成本是"结构性"（P1-3 的整层重建），不是 const 能解的 |
| R8 规则不完整 | **已做对** | `proguard-rules.pro` 保留 `io.flutter.**`（含理由：flutter.jar 不带 consumer 规则）、插件、`DefaultLifecycleObserver`，保留 `SourceFile/LineNumberTable` 并重命名；`-assumenosideeffects` 只剔 `Log.v/d`，而 `MainActivity` 用的是 `Log.i`——**没有误剔** |
| 多 ABI 混包 | **已做对** | 只出 arm64；`packaging.jniLibs.excludes` 精确点掉 v7a/x86_64 的 `libdartjni.so`（不整目录剔，保留模拟器可跑）；`verify_apk.py` 守 |
| `prototypeItem` / `itemExtent` 未设 | **不建议做** | 列表可见项只有 3~5 张卡，`SliverList.separated` 的 layout 成本约 30~60µs/项；为 `prototypeItem` 要放弃 `separated` 的 12px 间距语义，收益 < 风险 |
| `BackdropFilter` 数量过多（列表） | **已做对** | `GlassBackdropGroup` 共享一次背景读取；`cacheExtent` 收到 120px；实测 raster 4.6ms 富余 45% |

---

## 7. 未验证项（明确标注，不臆测）

1. **盘中跳价时的帧率 / 详情弹层打开时的帧率**：项目自认未测（README:L1449）。本报告 P1-3/P1-4 的毫秒级收益均为按面积与 pass 数估算，**未在设备上量过**。
2. **冷启动 ≤1.2s 的"中端设备"口径**：现有数据来自 OPPO Find X9（旗舰）。按引擎 11.2MB / AOT 4.4MB 的规模推断，中端机应在 600~900ms 量级，但**这是推断，不是测量**。
3. **低端机 120Hz 预算**：`raster 4.6ms` 是 PLJ110 / 120Hz 的数字；低端机上 premium 玻璃的单卡成本可能翻倍，README:L1366 已给了降级到 `standard` 的退路。
4. **长时（30 分钟以上）RSS 曲线**：`perf_bench.sh` 有 `--trim` 但没有长时采样；P1-6/P2-4 的收益需要它才能定论。
5. **`kQuoteStaleAfter = 5min` 与港股收市竞价（16:00–16:10）的边界**：`market_session.dart:99-102` 把 16:00–16:10 算作 `trading`，而这 10 分钟里报价可能 3~5 分钟不动 → 会被 `isStale` 判成"收盘快照"并显示"快照"角标，与实际"收市竞价中"矛盾。**这是一个产品语义问题，不属于本次性能审查范围，且我没有足够证据判定它一定发生**（取决于港股源在这 10 分钟是否持续出价）→ 仅记录，未列入发现。

---

## 8. 修复复核（2026-11-05 10:00，Top 10 的 1→5）

本节是**审查之后**的改动记录与验证证据。第 1~7 节保持审查当时的状态不动，便于回溯。

### 8.1 改了什么

| 编号 | 文件 | 改动 |
|---|---|---|
| P0-1 | `lib/pages/quote_list_page.dart:176-212` | `_syncNotifiers` 改为 `putIfAbsent`：已存在的标的保留原 notifier，只有新增的才建、只有删除的才 dispose |
| P1-2 | `lib/utils/error_hooks.dart`（新增）、`lib/main.dart:17` | 新增 `installErrorHooks()`：`FlutterError.onError` + `PlatformDispatcher.instance.onError` 双钩子，返回可撤销函数；`main()` 里紧跟 `ensureInitialized()` 之后调用 |
| P1-3 | `lib/widgets/glass.dart:530-571, 666-672`、`lib/widgets/quote_detail_sheet.dart:262-276` | `GlassPanel` 新增 `isolateChild`（默认 true，在 `BackdropFilter` 与内容之间插一层 `RepaintBoundary`）；详情弹层的 `ValueListenableBuilder` 从玻璃外面挪到里面 |
| P1-4 | `lib/widgets/quote_detail_sheet.dart:93-155, 296-301` | 新增 `_patchedBars` / `_patchedPoints`：按「源列表 identity + 影响图元的报价字段」记忆化，输入没变就复用同一个 List |
| P1-6 | `lib/widgets/kline_chart.dart:731-760, 827-880, 907-935` | `_measure` 拆成 `_newPainter` / `_measureWidth` / `_text`，三处全部 `try { … } finally { tp.dispose(); }` |

**没有动** P1-5（太极改数据驱动）——它改变可见动画行为，按约定先出方案再实施。

### 8.2 红态 → 绿态（新增 4 个用例，全部先失败后通过）

| 用例 | 红态证据（修复前） | 绿态 |
|---|---|---|
| `test/watchlist_keeps_quotes_test.dart` | `Expected: exactly one matching candidate / Actual: Found 0 widgets with text "1486.00"` —— 改订阅后价格真的变成 `--` | ✅ |
| `test/detail_paint_layers_test.dart`（分层） | `identical(before, after)` 为 false —— 跳价确实重建了玻璃 | ✅ |
| `test/detail_paint_layers_test.dart`（日 K） | `identical(before.bars, after.bars)` 为 false —— 确实每 tick 新建 List | ✅ |
| `test/error_hooks_test.dart` | 编译失败：`Error when reading 'lib/utils/error_hooks.dart'` —— 模块不存在 | ✅ |

### 8.3 门禁结果

```
flutter analyze                         No issues found!
flutter test                            277 passed（原 273 + 新 4）
flutter build apk --release \
  --target-platform android-arm64 \
  --obfuscate --split-debug-info=...     √ 16.60 MB（17 407 150 B）
python tool/verify_apk.py               ✓ 全绿（单 arm64 / targetSdk 37 / R8 保留 JNI / 数据源齐）
```

- 产物与历史 **`--obfuscate` 那一版完全一致**（16.60 MB / `libapp.so` 4.25 MB），说明本次改动没有带来体积增长。注意：上一次记录的 16.73 MB / 4.38 MB 是**未加 `--obfuscate`** 的构建，两次参数不同、不可直接比较（这个坑 README 的台账里也提过）。
- `test/preview` 的 6 张 golden 全部通过 ⇒ 弹层分层改造**没有改变一个像素**（只是改了图层结构，与 `paint_isolation` 那次改造同理）。

### 8.4 真机复核（3B15AB01H4V00000 / PLJ110，盘中 09:58，release 包）

| 观察点 | 结果 |
|---|---|
| 首页 | 4 张卡实价（38.71 / 25.97 / 21.02 / 23.46），无 `--`；页头 09:58:04 + 「AH · 交易中」+ 太极正常 |
| 详情弹层（分时） | 玻璃半透明、能透出背后雾团；09:59:00 的更新时间说明**跳价路径在改动后仍然活着** |
| 详情弹层（日 K） | MA5/MA10、~80 根蜡烛、量柱、`加载更早` 全部正常；最右一根已拼上今日实时价 38.60（= 头部价），说明记忆化没有把"今日那根"缓存成旧值 |
| 运行时日志 | 无 `FATAL` / 无 `ANR` / 无 `E/flutter`；`queueBuffer fps≈90` 为 90Hz 面板正常值 |

> 说明：8.4 只证明**没有视觉/功能回归**。P1-3/P1-4 的**帧时收益仍未在设备上量化**——第 7 节的结论不变，需要 `--dart-define=PERF_LOG=true` 的 profile 包做盘中采样才能给出数字。
>
> 时序细节（如实记录）：真机复核用的是 09:57 那次构建。之后又把 `initState` 里的建表合并到 `_syncNotifiers`（删掉 `_buildNotifiersFor`，让"同一逻辑只有一份实现"），10:02 重新构建，产物字节数**完全相同**（17 407 150 B）——但设备在最后一步掉线（`no devices/emulators found`），**未能在最终这一次构建上重做装机冒烟**。这次重构只动了初始化路径，由 `smoke_test` / `public_source_ui_test` / `snapshot_watchlist_test` 三个会真实泵出整页的用例覆盖。

### 8.5 评分变化

| 维度 | 审查时 | 复核后 | 剩余扣分项 |
|---|---|---|---|
| 内存 | 85 | **91** | `KlineLoader._cache` 无上限（P2-4） |
| 崩溃 | 72 | **84** | `_readCache` 在 try 外（P2-1）、`unawaited(HapticFeedback.*)` 未 catch |
| UI | 74 | **84** | 太极 60fps 常驻（P1-5）、`_paintVolume` 每帧排序（P2-3）、弹层 `shrinkWrap`（P2-6） |
| 启动 | 92 | 92 | — |
| 后台 | 86 | **87** | 195KB 目录在主 isolate 解码（P2-2） |
| APK | 90 | 90 | `com.example` 包名（P2-7）、53KB Kotlin 元数据（P3-1） |
| **加权** | ≈83 | **≈88** | |

**下一批（P2-1 → P2-6）预计 4.5h**，全部可与现有用例回归；**P1-5（太极）需要先定视觉方案**。

---

## 9. P1-5 落地：太极从「按时段常转」改成「数据驱动转一格」（2026-11-05 10:20）

方案由你选定为 **A（数据驱动转一格）**，含公共前提 **C（图层隔离）**。

### 9.1 契约变化

| | 旧 | 新 |
|---|---|---|
| 触发条件 | 交易时段 → `AnimationController.repeat()` | **每来一条真的改变了卡片的报价** → 走一格（300ms 缓动） |
| 收盘/午休 | 定时器发现时段变了才停（最长滞后 30s） | 不需要：没有 tick 就没有动画；且 `_anyLive()` 把收盘快照的 tick 挡掉 |
| 出帧 | 交易时段约 60fps 连续（≈5.5 小时/天） | 每次 tick 300ms（≈16 帧），其余时间 **0 帧** |
| 依赖 | `Timer.periodic(30s)` + `LifecyclePause` mixin | 两者都删除；退后台由轮询 `pause()` 自然停活 |
| 旋转图层 | 直接转（每帧重跑 `BoxShadow` 的 maskFilter + `CustomPaint` 重录） | `RepaintBoundary` 包住本体，每帧只改变换矩阵 |

关键实现（`lib/widgets/taiji_mark.dart`）：

```dart
static const double turnsPerTick = 1 / 24;   // 24 格一圈：3s 一格 → 72s 一圈
static const Duration stepDuration = Duration(milliseconds: 300);

void _onTick() {
  if (!mounted || _reduceMotion) return;
  if (!_anyLive(widget.now())) return;   // 收盘/午休：数据还在来，但价格没动
  final double current = _turns;
  _from = current;                        // 从"当前位置"续走，不跳回起点
  _to = current + TaijiMark.turnsPerTick;
  _spin.forward(from: 0);
}
```

计数由页面给（`lib/pages/quote_list_page.dart`）：`_onQuotes` 里只有 `before != quote`
（即真的改了某张卡）才 `_quoteTicks.value++`。收盘后快照仍会 3s 一次进来，但
`shouldApplyQuote` 挡掉同时间戳的重复帧 → 计数不涨 → 太极不动。

### 9.2 红态 → 绿态

契约变了，所以 `header_taiji_test.dart` 与 `reduce_motion_test.dart` 的 6 条断言
按新契约重写（旧的 4 条"按排帧判断在转"整组替换）。红态验证方式：先只加
`ticks` 参数、保留旧的 `repeat()` 实现，再跑新断言——

```
交易中但没有行情：仍然一帧都不排（旧实现这里会一直转）
  Expected: false   Actual: <true>        ← 旧实现确实在无数据时持续排帧
页面推一条行情 → 太极转一格，转完就停
  Expected: false   Actual: <true>        ← 旧实现转完不停
太极：tick 驱动 + 时段判定 交易中：一个 tick 转一格，且转完不再排帧
  Expected: false   Actual: <true>        ← 同上
```

3 条按预期失败（失败原因正是要修的行为，不是编译错）。实现后：

```
flutter analyze   No issues found!
flutter test      279 passed（+2：契约重写后净增）
flutter build     √ 17 407 150 B / 16.60 MB，sha256 d1a110cc…
verify_apk.py     ✓ 全绿
```

> 体积与上一版**字节数相同**属 zipalign 对齐余量吸收（sha256 已变、`libapp.so`
> 4 457 352 B），不是"没重新打包"。上一节写的"零增长"这个说法只对字节数成立。

### 9.3 调参入口

- 想更克制：`turnsPerTick = 1 / 48`（2.4 分钟一圈）；
- 想更明显：`1 / 12`（36 秒一圈，接近旧的 12 秒观感的 1/3）；
- 觉得顿：`stepDuration` 加到 450~600ms（但与 3s 的节奏差变小，会更像"慢慢滑"）。

### 9.4 未验证（如实标注）

- **真机运动观感**：设备在 10:14 之后掉线（`no devices/emulators found`），这一版
  没能装机看。**"顿挫感是否可接受"必须你目视**——这是方案 A 唯一的真实风险。
- **帧时收益**：同上，`PERF_LOG=true` 的 profile 采样没做成。可确定的是**出帧语义**
  变了（无 tick 时 0 帧），这一点由 `hasScheduledFrame` 的单测直接证明，与设备无关。

### 9.5 评分

| 维度 | §8 复核后 | 本次 | 说明 |
|---|---|---|---|
| UI | 84 | **88** | 只剩 `_paintVolume` 每帧排序（P2-3）、弹层 `shrinkWrap`（P2-6） |
| 后台 | 87 | **90** | 交易时段不再 60fps 常驻；只剩 195KB 目录在主 isolate 解码（P2-2） |
| **加权** | ≈88 | **≈90** | |

---

## 10. P2-1 → P2-6 批次（2026-11-05 10:30）

### 10.1 结果一览

| 编号 | 结论 | 关键改动 |
|---|---|---|
| P2-1 读盘异常穿透 | ✅ 已修 | `symbol_directory.dart` `ensureLoaded` 把 `_readCache()` 包进 try，读失败降级为"无缓存" |
| P2-2 195KB 解码在主 isolate | ✅ 已修（解码部分） | 抽出顶层纯函数 `_parseCatalog`，>64KB 走 `Isolate.run`；写盘双重编码**评估后不做**（见 10.5） |
| P2-3 `_paintVolume` 每帧排序 | ✅ 已修 | 抽出 `volumeP95()`，painter 内 `_volP95 ??=` 缓存（每个实例算一次） |
| P2-4 `KlineLoader` 无上限 | ✅ 已修 | `maxCacheEntries = 12` + `_remember()`，命中也会续命（否则退化成 FIFO） |
| P2-5 每 build 全表搜索 | ✅ 已修 | `_localMatches()` 按 `(query, directory.count)` 缓存 |
| P2-6 `shrinkWrap` 非懒加载 | ❌ **撤回** | 原判断错误，`shrinkWrap` 是布局契约，见 10.4 |

### 10.2 红态证据

| 用例 | 红态 | 绿态 |
|---|---|---|
| `symbol_directory_io_test` 存档读不出来 | `Bad state: disk down` —— 异常原样穿透 `ensureLoaded` | ✅ |
| `kline_cache_test` 超过上限要淘汰 | `Expected: <14> Actual: <13>` —— 无淘汰，第 1 个仍命中缓存 | ✅ |
| `chart_volume_test` p95 | 编译失败：`Method not found: 'volumeP95'` | ✅ |
| `watchlist_search_test` 目录后到时缓存失效 | `Found 0 widgets with text "贵州茅台"` —— 只按 query 缓存时确实是死的 | ✅ |

P2-6 的结构断言（`shrinkWrap == false && delegate is SliverChildBuilderDelegate`）做过**变异验证**：把实现改回 `ListView(shrinkWrap: true, children: rows)` 后该断言立刻红（`Expected: false / Actual: <true>`），证明它不是空转的——只是它守的方向后来被证明是错的。

### 10.3 门禁

```
flutter analyze   No issues found!
flutter test      290 passed（+11）
flutter build     √ 17 407 150 B / 16.60 MB，sha256 0d52574a…
```

### 10.4 P2-6 撤回：我审错了，`shrinkWrap` 是布局契约

审查第 2 节的原话是「`shrinkWrap` 完全不必要：`Flexible` 在 `Column` 里给的是有界高度」。
**这句话是错的**——"有界"不等于"贴合"。

`Column(mainAxisSize: min)` + `Flexible` 交给 `ListView` 的约束是「最多 0.82 屏」，
而 `ListView` 默认会**吃满**这个上界。`shrinkWrap: true` 唯一的作用就是让它按内容
高度上报，弹层才贴合内容。拆掉之后（配 `ListView.builder`）：

```
preview/app_preview_test › watchlist：订阅管理（已输入「茅台」，含搜索结果）  → 变红
```

失败图（`test/preview/failures/watchlist_testImage.png`）显示得很直白：3 只订阅 +
1 条搜索结果，弹层从"刚好包住内容"撑到接近满屏，底部一大片空白。

另外 **`builder` + `shrinkWrap` 也不能兼得**：`ShrinkWrappingViewport` 为了算出
extent 仍然要 lay out 全部子项，等于一帧都没省。

所以真正的懒加载有一个前置条件——**先把弹层高度改成固定值**（而不是贴合内容），
那是产品决策，不在这次范围内。代码里已就地留了注释（`watchlist_sheet.dart` 的
`ListView` 处），避免下次有人再"优化"一遍；golden 也会当场打红。

> 顺带说明 `rows` 的抽取保留了：它只是把 30 行订阅的构造收敛到一处，行为不变，
> 也不会诱导别人以为"改成 builder 就能懒加载"。

### 10.5 P2-2 的写盘部分：评估后不做

`FileKeyValueStore._writeAll` 会把整份 map（含 195KB 的目录字符串）重新
`jsonEncode` 一次（转义后约 400KB 的字符串工作，2~5ms）。但触发时机是：

- 目录缓存写盘：30 天一次；
- 订阅列表写盘：只在用户**改订阅**时（一次会话里通常 0 次）。

要消掉它得把存档改成"每 key 一文件"或引入 blob 存储，等于一次**存档格式迁移**
（旧 `itick_quote_state.json` 里的自选必须迁移，否则用户丢列表）。为了一个
"用户可能一周触发一次、每次 2~5ms"的路径冒丢数据的风险，不划算。**只做解码
offload，写盘保持原样**，并在 `local_store.dart` 不改动。

### 10.6 P2-3 的精确范围

缓存的是 p95 这个数字；`<double>[for (final p in pts) p.volume]` 的列表构造仍在
每次 paint 发生（约 1µs 级）。没有一并缓存，是因为那个列表要按 `isValid` 过滤，
把它提到 paint 之外等于把"哪条数据算数"的规则复制到两处——**用可读性换 1µs 不划算**。

### 10.7 评分

| 维度 | §9 后 | 本次 | 剩余扣分项 |
|---|---|---|---|
| 内存 | 91 | **93** | 无已知项（KlineLoader 已有上限） |
| 崩溃 | 84 | **87** | `unawaited(HapticFeedback.*)` 未 catch（4 处） |
| UI | 88 | **89** | 弹层 `shrinkWrap`（已判定为契约，非问题）、`_paintVolume` 的列表构造 |
| 启动 | 92 | 92 | — |
| 后台 | 90 | **92** | 写盘双重编码（已判定不划算） |
| APK | 90 | 90 | `com.example` 包名、53KB Kotlin 元数据 |
| **加权** | ≈90 | **≈91** | |

---

## 11. 收尾三条（P3-1 / 触觉异常 / P3-2），2026-11-05 10:40

### 11.1 改了什么

| 编号 | 文件 | 改动 |
|---|---|---|
| P3-1 APK 残留编译器元数据 | `android/app/build.gradle.kts` `packaging.resources.excludes` | 排除 `kotlin/**`、`kotlin-tooling-metadata.json`、`DebugProbesKt.bin` |
| 触觉异常未捕获 | `lib/utils/haptics.dart`（新增）+ 4 个调用点 | 统一走 `selectionClick()` / `mediumImpact()`，内部吞掉 `MissingPluginException` 与 `PlatformException` |
| P3-2 release 仍打日志 | `lib/utils/app_log.dart` `i()` | 加 `if (!kReleaseMode)`；`w/e` 保留（真问题该留在 logcat） |
| 顺带 | `tool/verify_apk.py` | 新增"冗余元数据必须为 0"断言 |

### 11.2 红态证据

**P3-1**：用旧包跑新断言（`itick-quote-1.0.0-plus27.apk`）：

```
冗余   : ✗ 编译器元数据 54 KB（10 项）
✗ 校验未通过，1 个问题：
  1. 包里带着 kotlin/*.kotlin_builtins 等编译期资源：检查 packaging.resources.excludes
```

新包：`冗余 : ✓ 编译器元数据 0 KB（0 项）`。这条断言从此会挡住回退。

**触觉**：变异验证——把 `_guard` 换成裸 `await call()`：

```
The following PlatformException was thrown running a test:
PlatformException(no_vibrator, null, null, null)
```

即改造前的 `unawaited(HapticFeedback.*)` 就是这条路径。

### 11.3 量到的收益（修正一个说法）

| | 修复前 | 修复后 |
|---|---|---|
| APK | 17 407 150 B | **17 392 235 B**（−14 915 B） |
| 包内元数据 | 54 KB 未压缩 / 10 项 | 0 |

⚠️ 审查第 2 节写的「减约 55KB」用的是**未压缩**口径。`.kotlin_builtins` 是文本，
在 APK 里压缩后只占约 15KB —— **真实收益是 15KB，不是 55KB**。这条按实测更正。

### 11.4 门禁与装机

```
flutter analyze   No issues found!
flutter test      292 passed（+2：haptics）
flutter build     √ 17 392 235 B / 16.59 MB
verify_apk.py     ✓ 全绿（含新断言）
```

真机（PLJ110，10:40 盘中）`install -r` 成功、启动无 FATAL：页头 10:40:32 +「AH · 交易中」，
太极完整渲染且角度已随行情转过（黑鱼分界线不是竖直的），四张卡实价无 `--`。
**太极"顿挫感"是否可接受仍需你目视**——app 已装在你手机上，直接看即可。

### 11.5 仍未做（需要你拍板）

1. **`applicationId = com.example.super_market`** —— ✅ **已决定维持**（2026-11-05 10:42）。
   决定写进了 `android/app/build.gradle.kts` 的 `defaultConfig` 注释（原来那行上游
   `// TODO: Specify your own unique Application ID ...` 已替换成决策说明 + 将来要改时
   四处同步的清单），避免下次被当成遗漏再翻一遍。
2. **页头秒表每秒一帧**（P3-3）：**维持现状**（未改）。产品上要"秒"就得每秒出帧，
   这是有意取舍；哪天觉得后台功耗要紧，就把非交易时段的周期放到 30s，一行的事。
3. `libapp.so` 4.25MB / `libflutter.so` 11.76MB —— 引擎固定成本，无可优化项。

### 11.6 评分（终版）

| 维度 | 分数 |
|---|---|
| 内存 | 93 |
| 崩溃 | **90**（触觉路径已收敛，两条已知穿透路径全封闭） |
| UI | 89 |
| 启动 | 92 |
| 后台 | 92 |
| APK | **91**（元数据清零） |
| **加权** | **≈91** |

---

## 12. 改 applicationId：`com.example.super_market` → `super.market`（2026-11-05 10:46）

### 12.1 取值

原话是「super marker」，含空格；Android 的 applicationId 每段只允许字母/数字/下划线、
且至少两段，所以取了同形合法的 **`super.market`**（用户从三个候选里选的）。

- `applicationId = "super.market"`
- `namespace` **保持** `com.example.super_market`：它决定 R 类与 `MainActivity` 所在的包，
  动它就要搬 `android/app/src/main/kotlin/com/example/super_market/MainActivity.kt`
  并改 manifest 的相对类名。两者不同是 AGP 允许的，收益只是"看起来一致"。
- 因此启动组件是 `super.market/com.example.super_market.MainActivity`，
  `adb shell am start -n super.market/.MainActivity` **会失败**；改用
  `monkey -p super.market -c android.intent.category.LAUNCHER 1` 或 `resolve-activity`。

### 12.2 代价（已确认接受）

- 只能**卸载重装**：`adb uninstall com.example.super_market` → `install`。
- 存档**无法迁移**：旧数据在 `com.example.super_market` 的私有目录下，换包名 = 换 UID，
  新包跨不过沙箱（不是权限问题，加 `MANAGE_EXTERNAL_STORAGE` 也没用）。
  旧的 4 只自选与目录缓存随卸载一起消失，重装后回到 `AppConfig.stocks` 的默认三只。

### 12.3 验证

```
aapt2 dump badging → package: name='super.market' versionCode='28' versionName='1.0.0'
                     minSdk 24 / targetSdk 37
flutter build      → 17 392 239 B（+4B：manifest 里的包名字符串）
verify_apk.py      → ✓ 全绿（冗余 0 项）
真机               → uninstall Success → install Success → pid 14157 存活
                     首页 10:46:41 / 「AH · 交易中」/ 三只默认股实价，无白屏无报错
```

### 12.4 顺带记一笔

`versionCode` 仍是 28、`versionName` 仍是 1.0.0（来自 `pubspec.yaml` 的 `1.0.0+28`）。
包名换了但版本号没动，对"自用、直接装 APK"没有影响；将来若做升级检测，注意
换包名的第一个版本应当**跳号**，否则旧包留下的检查逻辑会觉得"没有更新"。

### 12.5 追加：namespace 为什么没有跟着改（2026-11-05 10:50）

试过了，**改不了**——不是配置问题，是 Java 语法：

```
* What went wrong:
Namespace 'super.market' is not a valid Java package name as 'super' is a Java keyword.
```

`namespace` 决定 R 类与 `MainActivity` 所在的包，AGP 要求它是**合法 Java 包名**，
而 `super` 是保留字。`applicationId` 不参与 Java 命名，所以它能叫 `super.market`——
两者不一致是**被迫的**，不是漏改。

已回滚到可工作组合：

| 项 | 值 |
|---|---|
| `applicationId` | `super.market`（用户选定） |
| `namespace` | `com.example.super_market`（Java 关键字限制，不能改） |
| 启动组件 | `super.market/com.example.super_market.MainActivity` |
| `MainActivity.kt` | 回到 `kotlin/com/example/super_market/`，`package com.example.super_market` |

验证：重建 17 392 239 B（与 10:46 那次一致，说明确实回到了同一份产物）；
`install -r` 成功（applicationId 未变，**数据没丢**）；`am start -n
super.market/com.example.super_market.MainActivity` 起得来，pid 15760，无 `ClassNotFoundException`、无 FATAL。

> 要让两边完全统一，唯一干净的做法是换一个**既不是关键字、又能当包名**的组合
> （例如 `supermarket.app`），但那等于再换一次 applicationId = 再卸载重装一次、
> 自选再丢一次。**等你决定要不要付这个代价**，我没有擅自做第二次。

### 12.6 最终定案：`supermarket.app`（applicationId 与 namespace 一致）

§12.5 记的是中间状态（`super.market` + `com.example.super_market`）。用户随后要求统一，
最终取 **`supermarket.app`** —— 两段都是合法 Java 标识符，两个字段终于可以写成同一个值。

| 项 | 值 |
|---|---|
| `applicationId` | `supermarket.app` |
| `namespace` | `supermarket.app` |
| `MainActivity.kt` | `kotlin/supermarket/app/MainActivity.kt`，`package supermarket.app` |
| 启动命令 | `am start -n supermarket.app/.MainActivity`（相对名可用了，不用再拼全限定名） |

命名演进（三个包都已装过，现在只剩最后一个）：

```
com.example.super_market   → 卸载
super.market               → 卸载（namespace 用不了，`super` 是关键字）
supermarket.app            → 当前
```

验证：

```
aapt2 badging   package: name='supermarket.app'  versionCode 28  minSdk 24  targetSdk 37
build           17 392 227 B / 16.59 MB
真机            uninstall super.market → install → pm list 只剩 supermarket.app
                am start -n supermarket.app/.MainActivity → 起得来，pid 18678
                首页 10:53:24 / AH·交易中 / 三只默认股实价，无白屏无崩溃
```

代价照旧：卸载重装，自选回到 `AppConfig.stocks` 的默认三只；目录缓存重新下载（后台预热，不挡输入）。

---

## 13. 默认订阅换成四只（2026-11-05 11:02）

原来"首次安装/存档丢失"时默认是平安银行/贵州茅台/五粮液，现按用户的实际自选换成：

| 名称 | 代码 | 市场 | 备注 |
|---|---|---|---|
| 格力电器 | 000651 | SZ | |
| 长鑫科技 | 688825 | SH | 科创板，2026-07-27 上市（DRAM 厂）；代码经查证，不是猜的 |
| 神火股份 | 000933 | SZ | |
| 中国宏桥 | 01378 | HK | 港股 5 位代码 |

只改 **`AppConfig.stocks`**（"没有存档"那条路）。已有存档的用户不受影响——
`WatchlistRepository.load()` 一旦读到存档就以存档为准。反过来说：想改老设备上的列表
得在界面里改，改代码没用。

### 13.1 连带改动（这是重点：一处默认值会牵动一圈夹具）

| 文件 | 为什么必须动 |
|---|---|
| `test/layout_robustness_test.dart` | 用 `AppConfig.stocks[1]` 建 tile 却断言「贵州茅台/600519」的坐标。**解耦**成局部 `_kMaotai`：布局用例关心的是"长名称+长代码"这种最宽组合，与默认列表无关 |
| `test/smoke_test.dart` | `find.text('贵州茅台')` → `AppConfig.stocks[1].name` |
| `test/snapshot_watchlist_test.dart` | "当前订阅都列出来了"和解档断言写死了三只的名字/代码 → 改成按索引取；删故一只的用例改成删末位并断言 `length - 1` |
| `test/ui_gate_regression_test.dart` | 推 `000001` 的 Infinity / 正常价。**不在订阅里就找不到卡片**，闸门根本没被测到 → 改成推 `AppConfig.stocks.first` |
| `test/watchlist_keeps_quotes_test.dart` | 同上，推的两条报价改由 `AppConfig.stocks[0..1]` 生成 |
| `test/preview/app_preview_test.dart` | 夹具 `_kQuotes` 换成四只；日 K / 分时生成器的**价格尺度**从茅台（1180→1486）降到格力（33→38.71）；`_openDetail` 改为点 `AppConfig.stocks.first` |
| `test/preview/goldens/*.png` | 6 张全部重生成 |

### 13.2 golden 重建后的目视核对（不做这步就等于把回归焊进基线）

- `page.png`：四张卡 `格力电器 38.71 -0.64%`（绿）／`长鑫科技 40.88 -2.01%`（绿）／
  `神火股份 25.97 +1.21%`（红）／`中国宏桥 21.02 +3.34%`（红），均带「快照」角标（15:05 收盘后），
  页头 `15:05:00 / AH · 已收盘`，无裁切无重叠。
- `detail-daily.png`：头部 `格力电器 38.71 -0.64%`，纵轴刻度 `40.32 / 38.21 / 36.10`——
  **与头部同量级**（这正是重标定尺度要保证的），蜡烛自 33 涨到 38.7、MA5/MA10 正常；
  八项指标自洽（振幅 `(39.19−38.52)/38.96 = 1.72%` 与显示一致）。

### 13.3 验证

```
flutter analyze   No issues found!
flutter test      292 passed（6 张 golden 更新后全绿）
真机（11:02 盘中）install -r → 四只全部实价，无 "--"
  格力电器 38.34 (-1.59%) / 长鑫科技 42.80 (-2.93%)
  神火股份 26.01 (-0.19%) / 中国宏桥 21.08 (+3.64%)
```

> 真机这四行价格同时验证了**四个代码都能被新浪/腾讯认**——尤其 688825（科创板），
> 如果代码写错，那张卡会永远停在 `--`。这是比任何单测都硬的证据。

---

## 14. 图标：从红底虎鲸改为深蓝底虎鲸（2026-11-05 11:35）

### 14.1 规格（用户给定）

深蓝底 + 几何虎鲸侧身游动，DeepSeek 式简洁/圆润/负空间/扁平科技感；必须突出
高背鳍、白色眼斑、白色腹部；主体深蓝黑、眼斑与腹部纯白、少量浅蓝高光；
不写实、无纹理、小尺寸清晰。

### 14.2 落地

| 项 | 值 |
|---|---|
| 调色板 | 底 `#1A4E96`（深蓝）/ 主体 `#0A1D38`（蓝黑）/ 白（眼斑+腹部）/ 高光 `#7FC4F8`（浅蓝，背部一道） |
| 结构 | 眼斑从"镂空透底色"改为**白色直画**（深色身体上白斑才是正解），眼球改为深色墨点；白腹 = 椭圆∩身体的交集，胸鳍深色压在白腹上 |
| 资源 | 同一生成器（`tool/icongen/IconGen.java`）出 6 个文件：432px 前景位图 + 五档 legacy 圆角方；`colors.xml` 底色 `#FF1A4E96` |

### 14.3 用户复核后的两轮修正

第一版三条反馈：尾巴突兀、整体不够简洁、虎鲸不在正中心。修正：

1. **尾巴**：上扬细桨 → **短圆尾杆**（根宽 24u、伸出 ~35u、圆端头），是身体的自然延长；细长+斜向与圆润身体语言冲突是突兀感的来源。
2. **简洁**：删掉嘴线（一个元素对可读性几乎无增益，脸靠眼斑就够了）。
3. **居中**：bbox 居中 → **按视觉重心居中**——x 以身体（不含尾）bbox 中心对准图标中心（尾巴向右伸出，按 bbox 居中会把身体拉偏左）；y 整体居中再上移 1%（细高背鳍几乎没有视觉重量，纯几何居中会让身体看着沉底）。

> 教训：图标的"居中"从来不是几何问题，是视觉重量问题；含尾巴的 bbox 居中必然偏。

### 14.4 验证

- 192px / 48px 两档生成图直接目视：虎鲸居中、短圆尾自然、白斑白腹清晰、浅蓝高光可见；48px 仍可辨鲸形。
- 门禁：构建通过（16.6MB），真机 `install -r` Success；无 Dart 改动，单测不涉图标未重跑。
- README 图标章节重写（原来还停在"红底白色 W"时代，两次改版都没跟上），`docs/preview/icon.png` 已同步；包信息表的 `com.example.super_market` 一并更正为 `supermarket.app`。

### 14.5 海蓝渐变版（用户第二轮反馈，2026-11-05 12:00）

「背鳍更高、眼斑更大更斜、白腹更明显、尾鳍分叉清楚、背景用海的蓝色」：

| 反馈 | 落地 |
|---|---|
| 背鳍更高 | 顶点 y 26 → **14**（高出背线 60u），帆形不变 |
| 眼斑更大更斜 | 25×17u → **30×21u**，倾角 -18° → **-26°**，中心上移到 (51,89) 保持与白腹 ~3u 深色间隙 |
| 白腹更明显 | 腹部椭圆 ry 22 → **26**、上移 2u：白占身高 ~40%，向尾根多延伸 |
| 尾鳍分叉清楚 | 短圆尾杆 → **宽圆双叶 + 深凹口**（叶尖 (162,52)/(157,126)，凹口深入到 x≈142）。此前"双叶读成鱼尾"的结论被推翻——错的是**细尖**，不是分叉本身；叶宽、端圆、凹口深，读作鲸尾 |
| 背景海蓝 | 纯色 `#1A4E96` → **垂直渐变 `#3380C4 → #0E3A6B`**（上亮=水面、下深=深海）。legacy 用 `GradientPaint`；自适应底色改用新增的 `drawable/ic_launcher_background.xml`（shape gradient），`colors.xml` 删除 |

验证：192px / 48px 生成图目视全要素达标（渐变可感知、分叉可辨、眼斑清晰、居中）；
构建 17 405 767 B 通过。设备 12:02 掉线，装机待设备回来补（包已就绪）。
README 图标段与包信息表已同步（背景引用从 colors.xml 改为渐变 drawable）。

> 一个维护注意点：渐变色值现在**两处定义**（IconGen.java 的 FIELD_TOP/BOTTOM
> 与 drawable/ic_launcher_background.xml），两边注释都写了"必须同步"。
> 只有一处会静默漂移——legacy 五档位图和自适应图标的底色对不上。

### 14.6 DeepSeek 化重设计（用户要求"参考 DeepSeek 风格重新设计与优化"，2026-11-05 12:10）

对照 DeepSeek 图标语言（单一主角、同色系配色、圆润曲线、克制细节）做的三处优化：

| 项 | 优化前 | 优化后 | 考量 |
|---|---|---|---|
| 配色 | `#3380C4→#0E3A6B`（偏传统的蓝，偏闷） | **`#2F9BD8→#0A2B55`**，身体 `#0A1D38→#081C38` | 同一色相（~207°）三段递进：亮青蓝（水面）→ 深靛（深海）→ 蓝黑（主体）；白是唯一高调色。顶部与身体对比 ≈4.8:1，轮廓在任何位置都立得住 |
| 尾叶尖端 | 上叶尖切线夹角 ~100°，有"钩"感 | 控制点 `(163,57)→(166,50)`，切线连续 | DeepSeek 的圆是**切线连续的圆**，不是"差不多圆"；端头圆润后分叉尾才像鲸不像鱼叉 |
| 高光弧 | 从头顶贯穿到背鳍后（stroke 4.2） | 缩到头-背鳍之间、**stroke 3.6**、更贴背线 | 长线读作"条纹"，短弧读作"光"——同样一笔，语义不同 |

**保留不动**（辨识度三锚点 + 项目特色）：高背鳍（顶点 y=14）、大斜眼斑（30×21u/-26°）、
白色腹部、分叉鲸尾、垂直海蓝渐变。

**评估后不加**：嘴线（DeepSeek 鲸有微笑线，但我们的脸已由眼斑承担；加线 = +1 元素，
违背"少即是多"）；整体旋转 8-12° 的上扬姿态（与垂直渐变的海面语义冲突，且旋转后
背鳍/尾坐标全部重算，风险大于收益）。

验证：192/48 目视——渐变科技感、尾尖圆滑、高光自然、三锚点可辨；构建
17 405 491 B。设备仍离线，装机待设备回来。

### 14.7 写实化对照（用户问"和真实的虎鲸比呢"，2026-11-05 12:33）

先做真实性对照：六大物种特征当时覆盖 4 个——缺**鞍斑**（虎鲸最强 field mark）
和**宽圆桨状胸鳍**（当前小尖叶更像海豚）；眼斑斜度 -26° 是用户审美决定（真实
约 -10~-15°），眼球居中是图标语言决定——这两处如实说明后用户拍板四项：

| 反馈 | 落地 |
|---|---|
| 胸鳍圆桨 | `flipper()` 重画：长 ~30u 宽 ~20u 的圆桨，从腹侧伸向斜后 |
| 补鞍斑 | 背鳍后方 24×11u 椭圆（-10°）∩身体，**45% 半透明白**——白的弱化层，不新增色相；48px 目视不糊，保留 |
| 去除蓝线 | `sheen()` 与 `HI` 删除（用户不要了；渐变变亮后深色身体也不再需要轮廓辅助） |
| 尾鳍还不像 | 第五版：**先收尾杆（26u→14u）再展开双叶**，展开 74u→59u（≈身体高度 60u）、叶尖压低（y 52/126→66/125）。诊断：第 4 版"像钳子"的根源是双叶直接从肥胖后躯弹出、无尾杆、展开比身体还高 |

验证：192px 六特征全齐（背鳍/眼斑/鞍斑/白腹/圆桨胸鳍/水平双叶尾）、构图居中；
48px 鞍斑为自然灰斑不糊；构建 17 404 631 B；真机 `install -r` Success。

### 14.8 写实化 v2：比例级重画（用户"不像真实的虎鲸"，2026-11-05 12:40）

特征全齐却仍"不像"的根源是**体形语言**：2:1 的胖圆 = 鲸鱼宝宝。四项比例修正：

| 项 | 旧 | 新 | 依据 |
|---|---|---|---|
| 体形 | 2:1 胖圆 | **~2.5:1 修长纺锤**，头占 30%、尾杆从背鳍基后开始收细 | 真实虎鲸 3.5:1，图标折中 |
| 白下巴 | 白腹从身体中段起（黑下巴 = 瞬间"不是虎鲸"） | 白椭圆上移前伸：`Double(14,90,132,52)`，**下颌尖就是白的** | 真实虎鲸白从 jaw tip 起 |
| 眼斑 | 30×21u（1.4:1）"熊猫斑"、-26°、眼球居中 | **22×9u（2.4:1）细长白眉、-14°、眼球在斑前下端**（真实位置） | 真实眼斑贴眼后横向延伸 |
| 背鳍 | 窄基插上 | **基部 48u ≈ 体长 40%**（真实雄鲸比例），从背线平滑升起 | — |

鞍斑同步移到新背鳍后 (122,71)；尾鳍第六版（小双叶，与修长身体成比例）。

验证：192px 修长流线 + 白下巴 + 细眉眼斑 + 宽基背鳍 + 鞍斑全齐；48px 全部可辨；
构建 17 402 539 B；真机 install -r Success。

### 14.9 生物学描述校准（用户提供真实虎鲸生物学特征作核对清单，2026-11-05 12:48）

用户给出生物学描述（圆锥头无喙 / 眼后椭圆白斑 / 纺锤背黑腹白 / 雄性直立高大背鳍 /
灰色马鞍斑 / **新月形宽大尾鳍**）作为核对清单。四处修正：

| 项 | 修正 | 依据 |
|---|---|---|
| 尾鳍 | 第七版：**新月形宽大**——外缘一条长弧上翘、凹口挖深、展开 42→52u（> 体长 1/5）；叶尖 = 新月两角，允许略锐 | "新月形宽大有力" |
| 眼斑 | 细眉（22×9）→ **椭圆 26×12**、-14°，眼球仍在前下端 | "眼后椭圆白斑"——上一版矫枉过正 |
| 背鳍 | 尖端 y 12→16（高 48u ≈ 体深 102%） | "高 1-1.8m"按体深比例校准 |
| 鞍斑 | 24×11 → 28×12 | "马鞍斑"更醒目 |

验证：192px 六项描述逐条命中（圆锥头/椭圆眼斑/纺锤背黑腹白/直立高鳍/鞍斑/新月尾）；
48px 全部可辨；构建 17 402 743 B；真机 install -r Success。

### 14.10 百科全特征对齐（用户提供完整百科描述，2026-11-05 12:52）

从描述中提取四个此前缺失/偏差的图标级特征并落地：

| 百科特征 | 落地 |
|---|---|
| 「椭圆形的鳍肢位于体全长的**前 1/4 处**，雄性鳍肢长可达体全长 **20%**」 | 胸鳍根从体长 28% 前移到 16%，长收到 ~23% |
| 「两眼的后面各有一块**梭形**的白斑」 | 眼斑改梭形 Path（两头尖中间宽，26×13u、-14°）——椭圆的"两头尖"版 |
| 「有 1 个**白色的叶状斑从尿殖区向上伸到背鳍后的体侧**」 | `belly()` 并入第二个椭圆（(100,86,34,26)）：白腹在后部向上凸一叶，顶在鞍斑正下方——侧面的黑白节奏（白叶/黑带/灰鞍斑）是"虎鲸"与"黑鱼白肚"的分界 |
| 「**马鞍形**的灰白色斑」 | 鞍斑从浮动椭圆改为**贴背线的月牙**（前缘骑背线，clip 到身体） |

嘴线/牙齿/喷水柱不进图标：色块语言装不下，且白下巴上缘本身已构成嘴的分界。

验证：192px 四特征全落地，构图居中；48px 全部可辨；构建 17 402 071 B；
真机 install -r Success。

### 14.11 流线型（用户"不够流线型"，2026-11-05 12:56）

诊断方法：沿整条轮廓找**切线断裂点**（流线 = 曲线方向连续）。三处修复：

| 断裂点 | 修复 |
|---|---|
| 背鳍前缘 vs 背线：7° → 71°（**80° 断裂**，"鳍像插上去"的根源） | 前缘 cp1 改 (72,58)，沿背线切线起步再上扬 |
| 背鳍后缘落背：63° vs 背线 10° | 落点 cp2 改 (98,54)，顺背线切线着地 |
| 尾鳍起笔：0° vs 尾杆 28° | cp1 改 (134,82) 沿尾杆方向 |

背线中段同步抬高（峰 (90,60)），背线成为一条完整长弧。

验证：192px 轮廓吻→额→鳍→背→杆→尾→腹→颌方向连续，无台阶；
preview 6 golden 全绿；构建 17 401 799 B；真机 install -r Success。

### 14.12 修长化（用户"体型太短胖了"，2026-11-05 13:00）

体形从 2.5:1 → **2.9:1**：腹线整体上收 6u（111→105）、吻端/下颌上移 2u、
背线微升（峰 59）。连带重排：

- 白腹椭圆 `(14,90,132,52)` → `(14,84,132,48)`，白下巴/白叶保持；
- 头部深色带收窄到 ~19u，眼斑缩为 **20×10** 梭形、中心 (48,77.5)——
  眼斑几乎占满色带，与真实虎鲸头部侧面一致；眼球 r 2.1 前下位；
- 背鳍基随背线微调（(64,63)/(112,65)），切线连续保持；
- 鞍斑/白叶/尾鳍衔接随新腹线核对无脱节。

验证：192px 修长流线、全部特征就位无粘连；preview 6 golden 全绿；
构建 17 401 439 B；真机 install -r Success。

### 14.13 尾鳍上叶加厚（用户"月牙上半部看不清楚"，2026-11-05 13:05）

诊断：上叶外缘与内缘之间只有 5~6u（下叶 10~12u）——48px 时 1~2px，上半部
自然消失。修复：内缘整体下压（末端 (151,87)→(150,90)），上叶厚度 ~10u，
与下叶均衡；凹口深度不受影响。

验证：192px 两叶均衡、月牙两角清楚；preview 6 golden 全绿；构建
17 401 519 B；真机 install -r Success。

### 14.14 胸鳍重画（用户"鳍肢画的不好"，2026-11-05 13:09）

诊断：旧鳍肢是四段曲线围成的小叶片——桨面仅 ~8u 宽、端头有勾、根部平贴
腹线（像贴片不像长出来的）。按桨的结构重画：**根宽 12u 埋入身体 → 中部
饱满 ~12u → 单一圆端头**，全长 ~25% 体长。

验证：192px 桨形自然、衔接如生根；preview 6 golden 全绿；构建
17 401 367 B；真机 install -r Success。

### 14.15 胸鳍位置修正（用户"位置不太对"，2026-11-05 13:12）

诊断：鳍根 (46,98) 在**眼睛正下方、贴着下巴**——真实虎鲸的鳍肢起于头部
之后、约眼后半个头位。修正：根 46→**56**（体长 21%→29%），张角 ~45° 收到
~30°（贴身向后下，去"外八"感），桨形（根宽/端圆）保持。

验证：192px 鳍肢位于头后体侧、贴身自然；preview 6 golden 全绿；构建
17 401 387 B；真机 install -r Success。

### 14.16 真实照片对齐（用户提供真实虎鲸照片，2026-11-05 13:15）

照片揭示两处与真实的偏差并修正：

| 偏差 | 修正 |
|---|---|
| 白腹从下巴均匀铺到尾杆（"白腹太多"） | 主椭圆改为**前重后轻**：`(14,84,132,48)`→`(14,81,112,50)`（中心 x 80→70、rx 66→56）——最宽在胸鳍区，向后收窄，尾杆处主白消失、只剩白叶；照片的"前宽后窄"节奏成立 |
| 胸鳍根埋在白色区域中间 | 鳍根上移到**黑白分界线**上：`(56,97)`→`(58,86)` 骑在白腹上缘（"胸鳍应该从黑色的身体和白腹连接处伸出"），端头 (88,107)，贴身角度保持 |

连带：眼斑中心 (48,77.5)→(48,75.5)——白上缘抬起后保持 ~2u 黑色间隔，不粘连。

验证：192px 色块结构与照片一致（黑背 / 前宽后窄白腹 / 黑鳍骑分界线 / 白叶-黑带-
灰鞍斑三层节奏）；preview 6 golden 全绿；构建 17 401 783 B。设备 13:16 掉线，
装机待设备回来补。

### 14.17 胸鳍方向（用户"还不对"，2026-11-05 13:25）

上轮把张角从 45° 收到 30° 是**改反了**——照片里鳍肢是**向下垂**的
（与水平 ~50-60°），不是横向收拢。v5：鳍根保持在黑白分界线 (58,86)，
桨叶向下后方垂落（端头 (85,108)→(85,105)），恢复饱满桨形。

> 复查教训：收窄"张角"前应先确认照片里的基准角度——45° 本来就更接近
> 照片，30° 的"贴身"是臆测的优雅，不是照片的事实。

验证：192px 鳍肢垂落、根骑分界线；preview 6 golden 全绿；构建
17 401 723 B。设备 13:26 仍离线，装机待补。

### 14.18 白腹三块化 + 整体拉长（用户"白腹还是太多了，虎鲸要再长一点"，2026-11-05 13:35）

| 反馈 | 修正 |
|---|---|
| 白腹还是太多 | 白腹从单椭圆改为**三块并集**（照片里的"逗号"结构）：喉胸大块 (22,83,68,38) + 沿腹线的**窄带** (12,92,116,32) + 白叶 (102,84,34,20)，全部 ∩ 身体——最宽处砍 ~30%，向后只剩细带，尾杆处仅白叶 |
| 虎鲸要再长一点 | 新增 **ELONG=1.09 横向拉伸**，作用于全部图形（身体/鳍/色块一致生效），渲染比例 2.9:1 → **~3.15:1**；`ELONG=1.0` 可关闭。眼斑/眼球坐标同步走拉伸映射（`ELONG*(x-16)+16`），bbox 与居中亦然 |

验证：192px 修长流线 + 逗号形白腹节奏；preview 6 golden 全绿；构建
17 400 875 B。设备 13:36 仍离线，装机待补。

### 14.19 眼睛放大 + 白腹回归单旋转椭圆（用户"眼睛不对，白腹的感觉也不对"，2026-11-05 13:45）

| 反馈 | 诊断 | 修正 |
|---|---|---|
| 眼睛不对 | 写实化时缩过头：20×10 细梭 + r2.1 小黑点，远看像"划痕" | 眼斑 **24×11** 梭形、中心 (48,75)（与背线/白上缘各留 2.4/3u）；**眼球 r 2.5** 在斑前下端 |
| 白腹感觉不对 | 三块拼接有**接缝**——喉胸块右缘塌得太快，白区读作"白团+细线" | 回归**单一旋转椭圆**（中心 (60,105) rx60 ry20、**+6°** 前高后低=照片分界线走向）+ 白叶 (104,86,32,18)；上缘连续无台阶 |

验证：192px 眼斑/眼球清晰、白腹平滑连贯（喉高→后低→白叶）；preview 6 golden
全绿；构建 17 400 715 B。设备仍离线，装机待补。

> 节奏教训：三块拼的"分段实现"败给了"一条平滑分界线"——**形状的连续性
> 本身就是特征**，拼接感是不自然感的来源。

### 14.20 负空间重构（用户给出参考 logo："模仿这个照片"，2026-11-05 13:50）

用户给的参考图是**单色负空间语言**：蓝色圆底 + 同族色鲸，眼/腹/嘴全部镂空。
这与前十轮的"多色分层"（渐变底+深色身体+白斑白叶+灰鞍斑）是两种语言，按参考图重构：

| 维度 | 旧（多色分层） | 新（负空间） |
|---|---|---|
| 墨色 | 渐变底 + 深蓝黑 + 白（斑/腹/叶）+ 灰鞍斑（5 种） | **双色**：海蓝渐变 + 深蓝黑 #071831 |
| 眼斑 | 白梭形 + 深眼球 | **镂空梭形透底色** + 深眼球画回 |
| 腹部 | 白旋转椭圆 + 白叶 | **镂空月牙透底色**（含叶形上凸） |
| 嘴线 | 无 | 负空间细弧（stroke 2.4） |
| 鞍斑 | 灰月牙 | **删除**（单墨语言放不下灰阶） |
| legacy 底 | 渐变圆角方 | **渐变圆**（参考图 roundel） |
| foreground | 白墨直接画 | 负空间 **DstOut 镂空**（透自适应底） |

渐变提亮保证镂空可读：`#2F9BD8→#0A2B55` → **`#33A0E0→#1A5495`**（drawable 同步）——
负空间对比 = 底色对比，底部太深会让腹月牙消失。

保留：修长纺锤（ELONG 1.09）、宽基背鳍、垂落胸鳍（骑腹月牙上缘=原黑白分界线）、
均衡新月尾、切线连续轮廓、视觉重心居中。

验证：192px 双色负空间、眼部清晰、构图居中；48px 可辨；preview 6 golden 全绿；
构建 17 404 263 B。设备仍离线，装机待补。

### 14.21 白底定稿（用户"背景色用白色"，2026-11-05 14:00）

负空间语言的最后一块：**背景白**。至此配色结构与参考 logo 完全一致——
白圆底 + 海蓝鲸（#2F86D6，白底对比 ~3.8:1）+ 白色负空间（眼斑/腹月牙/嘴线）。

| 项 | 改动 |
|---|---|
| legacy | 渐变圆 → **白圆**；负空间从"回填渐变"改为**白墨** |
| foreground | DstOut 镂空不变（透 adaptive 白底） |
| adaptive 背景 | 渐变 drawable **删除**，改 `@android:color/white` |
| 鲸色 | #071831 蓝黑 → **#2F86D6 海蓝**（参考图的"蓝鲸"） |
| 渐变 | 全部退场（FIELD 常量/GradientPaint/背景 drawable） |

验证：192px 白底蓝鲸清爽、镂空清晰；48px 可辨；preview 6 golden 全绿；
构建 17 399 191 B；verify_apk 全绿。设备仍离线，装机待补。

### 14.22 居中与眼斑修正（用户"鲸要在中间，眼睛旁边的蓝色突出了一点"，2026-11-05 14:20）

| 反馈 | 诊断 | 修正 |
|---|---|---|
| 眼睛旁蓝色突出 | 眼斑镂空上缘 (68.8) 与前额轮廓 (~69) **相切穿透**——镂空在额头咬掉一小块，剩余蓝色读作"突出" | 眼斑中心 (48,75)→(48,77)、半高 5.5→4.75：与背线/白腹各留 ~3u/2.7u；白腹主椭圆同步下移 1u（105→106） |
| 鲸要在中间 | 居中策略还是"身体居中、尾巴甩出"——ELONG 拉长后尾甩得更远，观感偏左 | x 改**整条鲸（含尾）bbox 居中**；y 保持整体居中+上移 2% |

验证：192px 鲸居中、额头轮廓完整无缺口；preview 6 golden 全绿；构建
17 399 335 B；verify_apk 全绿。设备仍离线，装机待补。

### 14.23 背鳍收小（用户"背鳍是不是太大了"，2026-11-05 14:45）

对照照片测量确认：旧鳍高 48u ≈ 体深 107%（真实 44-78%）、基宽 48u ≈ 体长 40%
（真实 ~20-25%）——都超了。收小：

- 基 64..112（48u）→ **72..106（34u，26% 体长）**，中心仍在背部中部（56%）
- 高 48u → **39u ≈ 体深 88%**（略高于真实上限，给图标留存在感）
- 前缘/后缘切线连续保持

验证：192px 比例协调、轮廓流畅；preview 6 golden 全绿；构建 17 398 667 B；
verify_apk 全绿。设备仍离线，装机待补。

### 14.24 再拉长 + 左移（用户"往左移一点，虎鲸再长一点"，2026-11-05 15:00）

| 反馈 | 修正 |
|---|---|
| 虎鲸再长一点 | ELONG 1.09 → **1.13**（渲染比例 ~3.15 → **~3.3:1**） |
| 往左移一点 | 整鲸居中后整体**左移画布 2.5%**——尾鳍向右甩出使数学居中读作偏右 |

连带：foreground 占比 0.62 → **0.60**——拉长后鲸宽（0.62）已越过自适应安全圆
（0.611），微调避开圆形遮罩裁边。

验证：192px 修长、左移平衡、尾鳍离圆边有安全余量；preview 6 golden 全绿；
构建 17 398 251 B；verify_apk 全绿。设备仍离线，装机待补（前文一处"Success"系笔误，以此为准）。

### 14.25 左移加档（用户"再往左移一点"，2026-11-05 15:15）

左移量 2.5% → **4%**（`size * 0.04`）。吻端/尾鳍与圆边均保持安全距离。
构建 17 398 295 B；真机 install -r **Success**。

### 14.26 左移再加档（用户"再左移一点"，2026-11-05 15:20）

左移量 4% → **5.5%**（`size * 0.055`）。吻端与圆边安全距离保持。
构建 17 398 283 B；真机 install -r **Success**。

### 14.27 鲸色改黑（用户"把蓝色变成黑色"，2026-11-05 15:25）

鲸色 #2F86D6 → **纯黑 #000000**（`WHALE = Color.BLACK`）。白底对比 21:1，
参考 logo 的单墨权重。负空间结构不变。
构建 17 393 107 B；真机 install -r **Success**。
