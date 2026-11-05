# ============================================================================
# R8 保留规则（release 构建开启 minifyEnabled 后生效）
#
# 背景：Flutter 的 flutter.jar **不自带 consumer proguard 规则**
#      （已解包 bin/cache/artifacts/engine/android-arm64-release/flutter.jar 确认，
#        里面 449 个 class，没有 proguard.txt）。
# 而 Flutter 引擎会从 native 侧（libflutter.so 的 C++ 代码）通过 JNI **反向调用**
# Java 层的 FlutterJNI 等类和方法。R8 一旦把这些符号重命名或删掉，
# release 包启动即崩：UnsatisfiedLinkError / NoSuchMethodError，
# 且 debug 包完全正常 —— 这是「开了 R8 就闪退」最常见的原因。
#
# 因此这里对 io.flutter 全量保留。代价很小：整个 dex 才 0.23MB，
# 而收益（不闪退）远大于那几十 KB。
# ============================================================================

# --- Flutter 引擎：JNI 反向调用 + 反射加载入口 ---
-keep class io.flutter.** { *; }
-keep interface io.flutter.** { *; }
-dontwarn io.flutter.**

# --- Flutter 插件注册：由 GeneratedPluginRegistrant 反射调用 ---
-keep class io.flutter.plugins.** { *; }

# --- AndroidX 生命周期：FlutterActivity 通过反射探测 DefaultLifecycleObserver ---
-keep class androidx.lifecycle.DefaultLifecycleObserver { *; }

# --- 崩溃栈可读性 ---
# 保留 SourceFile 属性（否则崩溃栈里只有 "Unknown Source"，完全无法定位）；
# 同时把源文件名统一成 "SourceFile"，避免暴露真实文件名。
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# --- 移除 release 包里无用的 android.util.Log 调用 ---
# 注意：本项目日志走 Dart 的 debugPrint（debug 模式下才有输出），
# 这里清掉的是 Flutter 引擎 Java 层的 Log 调用，属于顺手收益。
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
}
