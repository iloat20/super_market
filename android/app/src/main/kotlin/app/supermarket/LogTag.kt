package app.supermarket

/**
 * 原生日志统一 tag，取值 = `applicationId`。
 *
 * `MainActivity` 的刷新率投票与 [AdpfSession] 的 hint session 都往这里打，
 * `adb logcat -s app.supermarket` 一次抓全。以前两处各写死 `super_market`，
 * 2026-11-06 包名迁到 `app.supermarket` 后没跟着改，排障时得同时记包名和
 * tag 两个词；`tool/measure_frames.sh` 也按旧 tag 过滤，改完 tag 就抓不到
 * `refresh:` 行。现在只留这一个定义点，值与 `build.gradle.kts` 的
 * `applicationId` 对齐，由 `test/log_tag_boundary_test.dart` 守着。
 *
 * ⚠️ Dart 侧 `debugPrint` / `dart:developer` 走引擎写死的 `flutter` tag，
 * 不归这个常量管（要改就得把日志全部搬过 MethodChannel，代价远大于收益）。
 * 两边一起看：`adb logcat -s app.supermarket flutter`。
 */
const val LOG_TAG = "app.supermarket"
