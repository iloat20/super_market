import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:super_market/utils/frame_rate.dart';

void main() {
  testWidgets('滑动期间升 120，停手 idleDelay 后才回落 60', (WidgetTester tester) async {
    final List<String> votes = <String>[];

    Future<void> sink(int fps, {required bool fixed}) async {
      votes.add('$fps${fixed ? 'F' : 'D'}');
    }

    final ScrollFrameRateController controller = ScrollFrameRateController(
      idleDelay: const Duration(milliseconds: 800),
      sink: sink,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ScrollFrameRate(
          controller: controller,
          child: ListView.builder(
            itemCount: 60,
            itemBuilder: (BuildContext context, int i) =>
                SizedBox(height: 60, child: Text('$i')),
          ),
        ),
      ),
    );

    // 开屏先落低档：原生侧不再固定 mode，不投票就会停在系统默认档
    expect(votes, <String>['60F'], reason: '开屏应立刻投一次低档');

    final TestGesture gesture =
        await tester.startGesture(tester.getCenter(find.byType(ListView)));
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();
    expect(votes, <String>['60F', '120D'], reason: '滑动开始应升档');

    // 连续 30 帧更新：这是滚动路径上每帧都会来的通知
    for (int i = 0; i < 30; i++) {
      await gesture.moveBy(const Offset(0, -8));
      await tester.pump(const Duration(milliseconds: 8));
    }
    expect(
      votes,
      <String>['60F', '120D'],
      reason: '连续更新不能逐帧投票——那是每帧一次跨平台调用',
    );

    await gesture.up();
    await tester.pumpAndSettle();

    // 还没到 idleDelay，不能回落
    expect(
      votes,
      <String>['60F', '120D'],
      reason: '停手后要等 idleDelay，立刻回落会让连续滑动反复升降档',
    );

    await tester.pump(const Duration(milliseconds: 900));
    expect(
      votes,
      <String>['60F', '120D', '60F'],
      reason: '停手 idleDelay 之后应回落到低档',
    );
  });

  testWidgets('回落期间重新滑动：作废待执行的回落', (WidgetTester tester) async {
    final List<String> votes = <String>[];

    final ScrollFrameRateController controller = ScrollFrameRateController(
      idleDelay: const Duration(milliseconds: 800),
      sink: (int fps, {required bool fixed}) async {
        votes.add('$fps${fixed ? 'F' : 'D'}');
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ScrollFrameRate(
          controller: controller,
          child: ListView.builder(
            itemCount: 60,
            itemBuilder: (BuildContext context, int i) =>
                SizedBox(height: 60, child: Text('$i')),
          ),
        ),
      ),
    );
    expect(votes, <String>['60F']);

    // 第一次滑动，然后停手，让回落定时器排上
    TestGesture gesture =
        await tester.startGesture(tester.getCenter(find.byType(ListView)));
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(votes.last, '120D');

    // 定时器还没到，又滑了一次
    await tester.pump(const Duration(milliseconds: 300));
    gesture = await tester.startGesture(tester.getCenter(find.byType(ListView)));
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    // 此时如果旧的回落没被作废，800ms 到点会把档位打回 60——用户还在滑
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      votes,
      <String>['60F', '120D'],
      reason: '重新开始滑动必须作废上一次排下的回落',
    );

    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 900));
    expect(votes, <String>['60F', '120D', '60F'], reason: '最终仍要回落');
  });

  testWidgets('第二个滚动容器挂载：不把滑动中的档位打回 60', (WidgetTester tester) async {
    final List<String> votes = <String>[];
    final ScrollFrameRateController controller = ScrollFrameRateController(
      sink: (int fps, {required bool fixed}) async {
        votes.add('$fps${fixed ? 'F' : 'D'}');
      },
    );

    Widget list() => ScrollFrameRate(
          controller: controller,
          child: ListView.builder(
            itemCount: 60,
            itemBuilder: (BuildContext context, int i) =>
                SizedBox(height: 60, child: Text('$i')),
          ),
        );

    await tester.pumpWidget(MaterialApp(home: list()));
    expect(votes, <String>['60F']);

    final TestGesture gesture =
        await tester.startGesture(tester.getCenter(find.byType(ListView)));
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    expect(votes.last, '120D');

    // 自选弹层在这时挂载：它也是滚动容器，initState 会调 settle()
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: <Widget>[
            Expanded(child: list()),
            ScrollFrameRate(
              controller: controller,
              child: const SizedBox(height: 10),
            ),
          ],
        ),
      ),
    );
    expect(
      votes,
      <String>['60F', '120D'],
      reason: '共享控制器下，新挂载的容器不能无条件落低档——那会把别人正在'
          '滑动的档位打回 60',
    );

    await gesture.up();
    await tester.pumpAndSettle();
  });
}
