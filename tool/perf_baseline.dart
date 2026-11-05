import 'dart:convert';
import 'dart:io';

/// 把 `lib/utils/perf_probe.dart` 打出的 `[perf]` 行解析成可归档、可判定的记录。
///
/// 背景：项目里两组历史性能数字条件互斥（PLJ110 / 90Hz / profile 的滚动帧，
/// 与 OPPO Find X9 / release 的冷启动内存），README 里还出现过跨 90Hz→120Hz
/// 的「−61%」对比。这类数字不能合并，更不能当成「更优」的证据。
///
/// 本工具不产出任何新的性能数字，只做三件事：
/// 1. 解析 `[perf]` 采样窗口；
/// 2. 按**官方帧预算**判定（预算由探针按 `1000/hz` 动态算出，见 B47/B49）；
/// 3. 输出带完整采集条件的 JSON，并以 `baselineKey` 标明哪些记录才可比。
///
/// 判定阈值只来自帧预算，**jank 数量只记录不判定**——没有同条件基线时，
/// 不设任何自定阈值，也不声称「更优」。

const String _kNote =
    '判定只依据官方帧预算 1000/hz；jank 仅记录不判定；无同条件基线不得声称更优';

final RegExp _perfPattern = RegExp(
  r'\[perf\]\s+hz=(\d+(?:\.\d+)?)\s+budget=(\d+(?:\.\d+)?)\s+n=(\d+)\s+'
  r'build\(p50=(\d+(?:\.\d+)?)\s+p90=(\d+(?:\.\d+)?)\s+max=(\d+(?:\.\d+)?)\)'
  r'\s+jank=(\d+)\s+'
  r'raster\(p50=(\d+(?:\.\d+)?)\s+p90=(\d+(?:\.\d+)?)\s+max=(\d+(?:\.\d+)?)\)'
  r'\s+jank=(\d+)',
);

/// 一个 40 帧采样窗口。
class PerfSample {
  const PerfSample({
    required this.hz,
    required this.budgetMs,
    required this.n,
    required this.buildP50,
    required this.buildP90,
    required this.buildMax,
    required this.buildJank,
    required this.rasterP50,
    required this.rasterP90,
    required this.rasterMax,
    required this.rasterJank,
  });

  final double hz;
  final double budgetMs;
  final int n;
  final double buildP50;
  final double buildP90;
  final double buildMax;
  final int buildJank;
  final double rasterP50;
  final double rasterP90;
  final double rasterMax;
  final int rasterJank;

  Map<String, Object?> toJson() => <String, Object?>{
        'hz': hz,
        'budgetMs': budgetMs,
        'n': n,
        'build': <String, Object?>{
          'p50': buildP50,
          'p90': buildP90,
          'max': buildMax,
          'jank': buildJank,
        },
        'raster': <String, Object?>{
          'p50': rasterP50,
          'p90': rasterP90,
          'max': rasterMax,
          'jank': rasterJank,
        },
      };
}

/// 解析单行；logcat 前缀（时间 / pid / tag）会被自动跳过。
PerfSample? parsePerfLine(String line) {
  final int start = line.indexOf('[perf]');
  if (start < 0) {
    return null;
  }
  final RegExpMatch? m = _perfPattern.firstMatch(line.substring(start));
  if (m == null) {
    return null;
  }
  double d(int i) => double.parse(m.group(i)!);
  int i(int idx) => int.parse(m.group(idx)!);
  return PerfSample(
    hz: d(1),
    budgetMs: d(2),
    n: i(3),
    buildP50: d(4),
    buildP90: d(5),
    buildMax: d(6),
    buildJank: i(7),
    rasterP50: d(8),
    rasterP90: d(9),
    rasterMax: d(10),
    rasterJank: i(11),
  );
}

List<PerfSample> parsePerfLines(String text) => text
    .split('\n')
    .map(parsePerfLine)
    .whereType<PerfSample>()
    .toList(growable: false);

/// 采集条件。三项缺一不可：缺条件的数字不能被当成基线。
class PerfConditions {
  const PerfConditions({
    required this.device,
    required this.build,
    required this.scenario,
  });

  final String device;
  final String build;
  final String scenario;

  bool get isComplete =>
      device.trim().isNotEmpty &&
      build.trim().isNotEmpty &&
      scenario.trim().isNotEmpty;

  List<String> get missing => <String>[
        if (device.trim().isEmpty) 'device',
        if (build.trim().isEmpty) 'build',
        if (scenario.trim().isEmpty) 'scenario',
      ];

  String get baseKey =>
      '${device.trim()}|${build.trim()}|${scenario.trim()}';

  Map<String, Object?> toJson() => <String, Object?>{
        'device': device.trim(),
        'build': build.trim(),
        'scenario': scenario.trim(),
      };
}

enum BaselineStatus { pass, fail, incomplete, notMeasurable }

String _statusName(BaselineStatus s) => switch (s) {
      BaselineStatus.pass => 'pass',
      BaselineStatus.fail => 'fail',
      BaselineStatus.incomplete => 'incomplete',
      BaselineStatus.notMeasurable => 'not_measurable',
    };

class BaselineReport {
  const BaselineReport._({
    required this.status,
    required this.reasons,
    required this.samples,
    required this.baselineKey,
    required this.conditions,
  });

  final BaselineStatus status;
  final List<String> reasons;
  final List<PerfSample> samples;
  final String? baselineKey;
  final PerfConditions conditions;

  /// 0 = 通过；1 = 判定失败 / 条件不全；2 = 不可测（没采到样本）。
  int get exitCode => switch (status) {
        BaselineStatus.pass => 0,
        BaselineStatus.notMeasurable => 2,
        BaselineStatus.fail || BaselineStatus.incomplete => 1,
      };

  Map<String, Object?> toJson() => <String, Object?>{
        'status': _statusName(status),
        'baselineKey': baselineKey,
        'conditions': conditions.toJson(),
        'reasons': reasons,
        'sampleCount': samples.length,
        'samples': samples.map((PerfSample s) => s.toJson()).toList(),
        'note': _kNote,
      };
}

/// 判定入口。纯函数，方便单测覆盖，不碰 IO / exit。
BaselineReport evaluate({
  required String logText,
  required PerfConditions conditions,
}) {
  final List<PerfSample> samples = parsePerfLines(logText);

  if (!conditions.isComplete) {
    return BaselineReport._(
      status: BaselineStatus.incomplete,
      reasons: <String>['采集条件不全，缺 ${conditions.missing.join(', ')}；'
          '这条记录不能作为基线'],
      samples: samples,
      baselineKey: null,
      conditions: conditions,
    );
  }

  if (samples.isEmpty) {
    return BaselineReport._(
      status: BaselineStatus.notMeasurable,
      reasons: <String>[
        '没有采集到任何 [perf] 样本：列表可能不足一屏（滑动没产生帧），'
            '或 profile 包没带 --dart-define=PERF_LOG=true。不可测，不是合格。',
      ],
      samples: samples,
      baselineKey: null,
      conditions: conditions,
    );
  }

  // 同一次采集只能有一个刷新率档：各档帧预算不同，合并即失真。
  final Set<int> hzBuckets =
      samples.map((PerfSample s) => s.hz.round()).toSet();
  if (hzBuckets.length > 1) {
    final List<int> sorted = hzBuckets.toList()..sort();
    return BaselineReport._(
      status: BaselineStatus.fail,
      reasons: <String>[
        '同一次采集出现多个刷新率档（${sorted.join('/')}Hz）：'
            '各档帧预算不同，样本不可合并成一条基线',
      ],
      samples: samples,
      baselineKey: null,
      conditions: conditions,
    );
  }

  // 判定只依据官方帧预算（B47 的 60/120fps、B49 的 16ms@60Hz）；预算本身由
  // perf_probe.dart 按 1000/hz 动态算出，这里再核对一次自洽性，防止把 90Hz
  // 的窗口贴到 120Hz 档上。
  // build / jank 只记录不判定：本项目 build 长期约 1ms，且没有同条件基线，
  // 不引入无依据的阈值，也不据此声称「更优」。
  final List<String> reasons = <String>[];
  for (final PerfSample s in samples) {
    final double expectedBudget = 1000.0 / s.hz;
    if ((s.budgetMs - expectedBudget).abs() > 0.05) {
      reasons.add(
        '预算与刷新率不自洽：hz=${s.hz.toStringAsFixed(0)} '
        'budget=${s.budgetMs.toStringAsFixed(2)}ms，'
        '按 1000/hz 应为 ${expectedBudget.toStringAsFixed(2)}ms，疑似跨档串数据',
      );
      continue;
    }
    if (s.rasterP90 >= s.budgetMs) {
      reasons.add(
        'raster p90 ${s.rasterP90.toStringAsFixed(1)}ms ≥ 帧预算 '
        '${s.budgetMs.toStringAsFixed(2)}ms（1000/hz），判不合格',
      );
    }
  }

  return BaselineReport._(
    status: reasons.isEmpty ? BaselineStatus.pass : BaselineStatus.fail,
    reasons: reasons,
    samples: samples,
    baselineKey: '${conditions.baseKey}|${hzBuckets.single}',
    conditions: conditions,
  );
}

Map<String, String> _parseArgs(List<String> args) {
  final Map<String, String> out = <String, String>{};
  for (int i = 0; i < args.length; i++) {
    final String a = args[i];
    if (!a.startsWith('--')) {
      continue;
    }
    final String key = a.substring(2);
    final int eq = key.indexOf('=');
    if (eq >= 0) {
      out[key.substring(0, eq)] = key.substring(eq + 1);
    } else if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
      out[key] = args[++i];
    } else {
      out[key] = 'true';
    }
  }
  return out;
}

Future<void> main(List<String> args) async {
  final Map<String, String> opts = _parseArgs(args);
  if (opts.containsKey('help')) {
    stdout.writeln('用法：dart tool/perf_baseline.dart '
        '--device <机型> --build <profile|release> --scenario <场景> '
        '[--input <logcat文件>]');
    stdout.writeln('不传 --input 时从 stdin 读；输出 JSON 到 stdout。');
    stdout.writeln('退出码：0=通过 1=失败/条件不全 2=不可测');
    return;
  }

  final PerfConditions conditions = PerfConditions(
    device: opts['device'] ?? '',
    build: opts['build'] ?? '',
    scenario: opts['scenario'] ?? '',
  );
  final String? input = opts['input'];
  final String text = input != null
      ? File(input).readAsStringSync()
      : await stdin.transform(utf8.decoder).join();

  final BaselineReport report = evaluate(
    logText: text,
    conditions: conditions,
  );
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(report.toJson()));
  exit(report.exitCode);
}
