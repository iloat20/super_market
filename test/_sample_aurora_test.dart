import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_market/widgets/glass.dart';

void main() {
  testWidgets('采样背景顶部色', (WidgetTester tester) async {
    const double w = 390;
    const double h = 844;

    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: key,
            child: const SizedBox(
              width: w,
              height: h,
              child: AuroraBackground(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final RenderRepaintBoundary boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;

    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage();
      final ByteData data =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final int width = image.width;
      String hex(int x, int y) {
        final int i = (y * width + x) * 4;
        final int r = data.getUint8(i);
        final int g = data.getUint8(i + 1);
        final int b = data.getUint8(i + 2);
        return '#${r.toRadixString(16).padLeft(2, '0')}'
            '${g.toRadixString(16).padLeft(2, '0')}'
            '${b.toRadixString(16).padLeft(2, '0')}';
      }

      for (final int y in <int>[4, 30, 60, 76, 100, 112]) {
        // ignore: avoid_print
        print('y=$y  L=${hex(12, y)}  C=${hex(195, y)}  R=${hex(378, y)}');
      }
    });
  });
}
