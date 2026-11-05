/// 行情数字格式化（纯函数，便于单测）。
///
/// 单独抽出来的原因：同一套格式化规则要被列表卡片、详情弹层、无障碍朗读
/// （Semantics）三处复用，散落各处早晚会出现「列表保留 2 位、弹层保留 3 位」
/// 这种不一致。
library;

/// 价格：A 股报价精度固定 2 位
String formatPrice(double value) => value.toStringAsFixed(2);

/// 带符号的变化额/幅：`+1.23` / `-1.23` / `0.00`
///
/// 特意处理 `-0.00`：`(-0.001).toStringAsFixed(2)` 会得到 `-0.00`，
/// 在行情里这是明显的脏数据观感，统一归零。
String formatSigned(double value, {String suffix = ''}) {
  final double rounded = double.parse(value.toStringAsFixed(2));
  if (rounded == 0) {
    return '0.00$suffix';
  }
  final String sign = rounded > 0 ? '+' : '';
  return '$sign${rounded.toStringAsFixed(2)}$suffix';
}

/// 大数压缩：`16742235` → `1674.22万`，`3774688301` → `37.75亿`
///
/// 量/额这类数字直接铺出来读不出量级，压缩成「万/亿」才符合看盘习惯。
String formatCompact(double value) {
  final double abs = value.abs();
  if (abs >= 100000000) {
    return '${(value / 100000000).toStringAsFixed(2)}亿';
  }
  if (abs >= 10000) {
    return '${(value / 10000).toStringAsFixed(2)}万';
  }
  if (value == value.roundToDouble()) {
    return value.toStringAsFixed(0);
  }
  return value.toStringAsFixed(2);
}

/// `HH:mm:ss`，null 显示占位
String formatClock(DateTime? time, {String placeholder = '—'}) {
  if (time == null) {
    return placeholder;
  }
  final DateTime local = time.toLocal();
  return '${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)}';
}

/// `MM-DD HH:mm`，用于跨日行情的绝对时间（收盘后再打开时不会误读成今天）
String formatDateTimeShort(DateTime? time, {String placeholder = '--'}) {
  if (time == null) {
    return placeholder;
  }
  final DateTime local = time.toLocal();
  return '${_two(local.month)}-${_two(local.day)} '
      '${_two(local.hour)}:${_two(local.minute)}';
}

/// 详情「更新时间」：同一天给秒，跨天给日期。
///
/// 只写 `15:35:45` 的话，早上 9 点打开 App 看到的是**上一个交易日**的收盘
/// 价，时间却像是今早的——这是真机上实际发生过的误读。跨天时补成
/// `11-04 15:35`，「这是昨天的价」不用读者自己推理。
///
/// 反过来，同一天还要保留秒：盘中一笔成交和 3 秒前的价差是能看出来在跳的。
String formatUpdateTime(
  DateTime? time,
  DateTime now, {
  String placeholder = '--',
}) {
  if (time == null) {
    return placeholder;
  }
  final DateTime local = time.toLocal();
  final DateTime today = now.toLocal();
  final bool sameDay =
      local.year == today.year &&
      local.month == today.month &&
      local.day == today.day;
  return sameDay
      ? formatClock(local, placeholder: placeholder)
      : formatDateTimeShort(local, placeholder: placeholder);
}

String _two(int value) => value.toString().padLeft(2, '0');
