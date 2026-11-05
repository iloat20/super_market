import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/pages/quote_list_page.dart';
import 'package:super_market/services/local_store.dart';
import 'fake_feed.dart';
import 'package:super_market/services/watchlist_repository.dart';
import 'package:super_market/widgets/glass.dart';
import 'package:super_market/widgets/quote_tile.dart';

/// 页头与列表的接缝（用户：「不要下滑刷新」「上滑时页头的分界线很明显」）。
///
/// 这两件事在结构上是同一个问题的两面：
/// 1. `RefreshIndicator` 是列表顶部那个转圈的来源；
/// 2. 「分界线」有两条——页头自己那块玻璃的 28 圆角轮廓，以及列表 viewport
///    在页头下沿把卡片硬裁出来的水平切线。
///
/// 解法：页头不放材质（直接露出背景），列表撑满整屏、靠内容 padding 让开
/// 页头，再用 [HeaderFade]（背景顶部原样重画 + 渐隐）让滑上来的卡片沉下去。
void main() {
  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: QuoteListPage(
          serviceBuilder: NoopFeed.builder,
          watchlistRepository: WatchlistRepository(MemoryKeyValueStore()),
          clock: () => DateTime(2026, 11, 4, 10, 0),
        ),
      ),
    );
    // 不用 pumpAndSettle：页头秒表每秒跳一格，settle 不会收敛
    await tester.pump();
  }

  testWidgets('列表顶部没有下拉刷新', (WidgetTester tester) async {
    await pumpPage(tester);

    expect(
      find.byType(RefreshIndicator),
      findsNothing,
      reason: '下拉那一把不会让数据变新：轮询链每 3s 一次全量快照，断线自己退避重连',
    );
  });

  testWidgets('列表撑满整屏，靠内容留白让开页头', (WidgetTester tester) async {
    await pumpPage(tester);

    final Finder scroll = find.byType(CustomScrollView);
    expect(scroll, findsOneWidget);

    // 关键不变量：viewport 顶到页面最上面。一旦这里被恢复成
    // `Padding(top: header)`，卡片就会在页头下沿被裁出一条硬线——
    // 而这是「分界线」两条来源之一。
    expect(
      tester.getTopLeft(scroll).dy,
      0,
      reason: 'viewport 被推到页头下面 = 卡片滑不上去 = 裁切线又回来了',
    );

    // 让开页头改为内容层的留白，第一张卡必须落在渐隐区（[HeaderFade]）之外，
    // 否则卡片顶端会被盖掉一截，比卡身灰一档
    final Finder firstCard = find.byType(QuoteTile).first;
    expect(
      tester.getTopLeft(firstCard).dy,
      greaterThanOrEqualTo(headerBlockHeight),
      reason: '第一张卡踩进渐隐区 = 卡片顶端发灰',
    );
  });

  testWidgets('渐隐层贴着屏幕顶部，补齐到页头留白', (WidgetTester tester) async {
    await pumpPage(tester);

    final Finder fade = find.byType(HeaderFade);
    expect(fade, findsOneWidget);
    expect(tester.getTopLeft(fade).dy, 0);
    // 测试环境状态栏为 0，于是正好等于列表留白
    expect(tester.getSize(fade).height, headerBlockHeight);
  });

  testWidgets('渐隐只压不透明度：内容是背景本身，不是近似色', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 359,
            height: headerBlockHeight,
            child: HeaderFade(canvasHeight: 789),
          ),
        ),
      ),
    );

    // 内容是 AuroraBackground 本身：采样出来的近似色在别的画幅上会差 4 阶，
    // 下沿就是一条灰线（见 HeaderFade 的类注释）
    expect(
      find.descendant(
        of: find.byType(HeaderFade),
        matching: find.byType(AuroraBackground),
      ),
      findsOneWidget,
      reason: '换成纯色/渐变色填充 = 换画幅就出现色带',
    );

    // 渐隐走 dstIn（只乘 alpha，不动颜色）
    final ShaderMask mask = tester.widget<ShaderMask>(
      find.descendant(
        of: find.byType(HeaderFade),
        matching: find.byType(ShaderMask),
      ),
    );
    expect(mask.blendMode, BlendMode.dstIn);

    // 不透明段要盖住页头内容的底边（top 8 + padding 10 + 太极 48 + 10 = 76），
    // 否则卡片会从页头文字之间透出来
    final HeaderFade fade = tester.widget<HeaderFade>(find.byType(HeaderFade));
    expect(
      fade.solidHeight,
      greaterThanOrEqualTo(76),
      reason: '不透明段没盖住页头内容 = 卡片在时间和角标旁边透出来',
    );
    expect(
      fade.height,
      greaterThanOrEqualTo(fade.solidHeight + 24),
      reason: '渐隐段太短 = 卡片像是被一刀切掉，只是切得软一点',
    );
  });

  /// 这条是本层最硬的保证：盖上去之后，顶部像素必须和**没有这一层**时一样。
  ///
  /// 只要有人把它换成「采样出来的近似色」，或者改了 [AuroraBackground] 的
  /// 画布尺寸，某些采样点就会开始漂——那就是用户说的「分界线」回来了。
  /// 所以跑两种画幅：真机竖屏（359×789）和预览用的 390×844。
  for (final Size canvas in <Size>[
    const Size(359, 789),
    const Size(390, 844),
  ]) {
    testWidgets('盖上去之后顶部像素零色差（${canvas.width.toInt()}×'
        '${canvas.height.toInt()}）', (WidgetTester tester) async {
      Future<ui.Image> render({required bool withFade}) async {
        final GlobalKey key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: RepaintBoundary(
                key: key,
                child: SizedBox(
                  width: canvas.width,
                  height: canvas.height,
                  child: Stack(
                    children: <Widget>[
                      const Positioned.fill(child: AuroraBackground()),
                      if (withFade)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: headerBlockHeight,
                          child: HeaderFade(canvasHeight: canvas.height),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final RenderRepaintBoundary boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        late ui.Image image;
        await tester.runAsync(() async {
          image = await boundary.toImage();
        });
        return image;
      }

      final ui.Image plain = await render(withFade: false);
      final ui.Image faded = await render(withFade: true);

      await tester.runAsync(() async {
        final ByteData a = (await plain.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final ByteData b = (await faded.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final int width = plain.width;
        final double scale = plain.width / canvas.width;

        // 单像素不可比：Impeller 给渐变加了抖动（dither）来压 banding，
        // 同一块离屏 layer 里的抖动图案差 ±2~3 阶，属于噪声不是色差。
        // 取 7×7 的局部均值，噪声被平均掉，剩下的才是系统性偏移。
        List<double> mean(ByteData data, int cx, int cy) {
          double r = 0, g = 0, b = 0;
          int n = 0;
          for (int dy = -3; dy <= 3; dy++) {
            for (int dx = -3; dx <= 3; dx++) {
              final int i4 = ((cy + dy) * width + (cx + dx)) * 4;
              r += data.getUint8(i4);
              g += data.getUint8(i4 + 1);
              b += data.getUint8(i4 + 2);
              n++;
            }
          }
          return <double>[r / n, g / n, b / n];
        }

        // 只在渐隐层覆盖的范围内比：那一段盖上去之后必须看不出变化
        for (final double y in <double>[4, 30, 60, 76, 100, 110]) {
          for (final double x in <double>[
            12,
            canvas.width / 2,
            canvas.width - 12,
          ]) {
            final int cx = (x * scale).round();
            final int cy = (y * scale).round();
            final List<double> ma = mean(a, cx, cy);
            final List<double> mb = mean(b, cx, cy);
            for (int c = 0; c < 3; c++) {
              final double delta = (ma[c] - mb[c]).abs();
              expect(
                delta,
                // 容差 3 阶：离屏 layer 里渐变会被编码成 8bit 纹理，
                // 往返之后整块有 1~2.5 阶的稳定偏移（实测），不是噪声。
                // 它不构成分界线的理由在下面「接缝」那段断言里：本层末端
                // alpha 归零，112 处显示的仍是背景本身，跳转变为 0。
                // 而「采样近似色」方案是 4~5 阶的整块偏移，这里过不去。
                lessThan(3.0),
                reason:
                    '($x, $y) 处盖上去后平均差了 ${delta.toStringAsFixed(2)} 阶：'
                    '渐隐层必须画背景本身，不能用近似色',
              );
            }
          }
        }
        // 接缝：y=110 是本层覆盖的最后一小段（alpha≈0.06），y=114 已经在层外。
        // 这两行之间若有跳变，就是用户说的那条线。整块的 1~2 阶偏移不算，
        // 因为它随 alpha 一起衰减，到边缘时**已经归零**。
        final int midX = (canvas.width / 2 * scale).round();
        final List<double> seamAbove = mean(b, midX, (110 * scale).round());
        final List<double> seamBelow = mean(b, midX, (114 * scale).round());
        for (int c = 0; c < 3; c++) {
          expect(
            (seamAbove[c] - seamBelow[c]).abs(),
            lessThan(1.5),
            reason: '渐隐层下沿出现跳变：这就是要消灭的那条分界线',
          );
        }
      });
    });
  }
}
