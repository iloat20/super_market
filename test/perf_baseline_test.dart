import 'package:flutter_test/flutter_test.dart';

import '../tool/perf_baseline.dart';

/// A14：性能基线的「可判定 / 可归档 / 防跨条件合并」。
///
/// 样本全部来自 README 里**已有的历史实测日志**（`README.md:304` 的 120Hz
/// 正常窗口、`:218-224` 的 90Hz 全掉帧窗口），没有新造性能数字。
/// 本文件不测「更快/更慢」，只测：
/// - 解析能否吃掉 logcat 前缀；
/// - 判定是否只依据官方帧预算 `1000/hz`；
/// - 不同条件是否生成不同 baselineKey（防止把两组互斥数据合并对比）。

const String _kOk = '[perf] hz=120 budget=8.33 n=40 '
    'build(p50=0.8 p90=1.2 max=2.6) jank=0 '
    'raster(p50=4.5 p90=5.3 max=5.8) jank=0';

const String _kOverBudget = '[perf] hz=90 budget=11.11 n=40 '
    'build(p50=1.0 p90=2.0 max=3.3) jank=0 '
    'raster(p50=11.7 p90=12.2 max=13.0) jank=40';

const String _kBudgetMismatch = '[perf] hz=120 budget=11.11 n=40 '
    'build(p50=0.8 p90=1.2 max=2.6) jank=0 '
    'raster(p50=4.5 p90=5.3 max=5.8) jank=0';

const String _k60Hz = '[perf] hz=60 budget=16.67 n=40 '
    'build(p50=0.8 p90=1.2 max=2.6) jank=0 '
    'raster(p50=4.5 p90=5.3 max=5.8) jank=0';

const PerfConditions _kConditions = PerfConditions(
  device: 'PLJ110',
  build: 'profile',
  scenario: 'scroll-3stocks',
);

BaselineReport _run(String log, [PerfConditions conditions = _kConditions]) =>
    evaluate(logText: log, conditions: conditions);

void main() {
  test('解析：logcat 前缀被跳过，无关行不产生样本', () {
    final String log = [
      '11-04 20:00:00.000 1234-1234 I/flutter: 其它日志',
      '11-04 20:00:01.000 1234-1234 I/flutter: $_kOk',
      'garbage',
    ].join('\n');
    final List<PerfSample> samples = parsePerfLines(log);
    expect(samples, hasLength(1));
    expect(samples.single.hz, 120);
    expect(samples.single.budgetMs, 8.33);
    expect(samples.single.n, 40);
    expect(samples.single.rasterP90, 5.3);
    expect(samples.single.rasterJank, 0);
  });

  test('合格窗口：pass / 退出码 0 / baselineKey 带完整条件', () {
    final BaselineReport r = _run(_kOk);
    expect(r.status, BaselineStatus.pass, reason: r.reasons.join('; '));
    expect(r.exitCode, 0);
    expect(r.baselineKey, 'PLJ110|profile|scroll-3stocks|120');
  });

  test('raster p90 超过动态帧预算 → fail', () {
    final BaselineReport r = _run(_kOverBudget);
    expect(r.status, BaselineStatus.fail,
        reason: '11.7ms 的 raster 在 90Hz 下越线，不能判合格');
    expect(r.reasons.join(' '), contains('预算'));
    expect(r.exitCode, 1);
  });

  test('budget 与 hz 不自洽 → fail（防跨刷新率串数据）', () {
    final BaselineReport r = _run(_kBudgetMismatch);
    expect(r.status, BaselineStatus.fail,
        reason: 'hz=120 却写 90Hz 的 11.11 预算，属跨档串数据');
    expect(r.reasons.join(' '), contains('不自洽'));
  });

  test('同一次采集出现多个刷新率 → fail 且不给 baselineKey', () {
    final BaselineReport r = _run('$_kOk\n$_k60Hz');
    expect(r.status, BaselineStatus.fail,
        reason: '60/120 两档样本不可合并成一条基线');
    expect(r.baselineKey, isNull);
    expect(r.reasons.join(' '), contains('刷新率'));
  });

  test('采集条件缺失 → incomplete，不能作为基线', () {
    final BaselineReport r = _run(
      _kOk,
      const PerfConditions(device: '', build: 'profile', scenario: ''),
    );
    expect(r.status, BaselineStatus.incomplete);
    expect(r.baselineKey, isNull);
    expect(r.reasons.join(' '), contains('device'));
    expect(r.exitCode, 1);
  });

  test('没有 [perf] 样本 → not_measurable（不可测 ≠ 合格）', () {
    final BaselineReport r = _run('只有一堆无关日志');
    expect(r.status, BaselineStatus.notMeasurable);
    expect(r.exitCode, 2);
    expect(r.reasons.join(' '), contains('不足一屏'));
  });

  test('baselineKey 随条件变化，防止跨条件合并', () {
    final String a = _run(_kOk).baselineKey!;
    final String b = _run(
      _kOk,
      const PerfConditions(
        device: 'OPPO Find X9',
        build: 'release',
        scenario: 'scroll-3stocks',
      ),
    ).baselineKey!;
    expect(a, isNot(b),
        reason: '不同设备/构建的记录绝不能共享一个基线键');
  });

  test('JSON 归档带完整条件与判定说明', () {
    final Map<String, Object?> json = _run(_kOk).toJson();
    expect(json['status'], 'pass');
    expect(json['sampleCount'], 1);
    expect((json['conditions'] as Map)['device'], 'PLJ110');
    expect(json['note'], contains('不得声称更优'));
  });
}
