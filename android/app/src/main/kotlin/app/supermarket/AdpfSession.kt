package app.supermarket

import android.content.Context
import android.os.Build
import android.os.PerformanceHintManager
import android.util.Log
import java.io.File

/**
 * ADPF（Android Dynamic Performance Framework）会话。
 *
 * 干什么：把 Flutter 的 UI 线程（`1.ui`）与光栅线程（`1.raster`）登记成一条
 * `PerformanceHintManager.Session`，把每帧实际工作时长报给系统。系统据此决定
 * 何时把 CPU 频率拉起来——默认的调频策略看不到 Flutter 的帧截止时间，从空闲唤醒
 * （滑动开始、轮询回包刷新）时容易"频率还没上去，帧已经过去了"。
 *
 * ## 为什么在应用层做
 *
 * Flutter 3.47.9 的引擎里没有 ADPF：`libflutter.so` 里 `APerformanceHint` /
 * `PerformanceHintManager` 命中 0 处（`tool/android_engine_caps.sh` 可复跑），
 * 上游 flutter/flutter#192582 仍未合并。所以在引擎接上之前只能自己报。
 *
 * ## 为什么不写成 MethodChannel + 每帧一次
 *
 * 每帧一次要走 Binder，120Hz 下每秒 120 次 IPC。Dart 侧攒 8 帧或 200ms 报一次
 * 平均值（见 `lib/utils/adpf.dart`），这里只负责把值交出去。
 *
 * ## 兼容性
 *
 * `PerformanceHintManager` 是 API 31 才有的，且它返回的会话类型是**嵌套类**
 * `PerformanceHintManager.Session`（不是某些文档里写的 `PerformanceHintSession`；
 * 以 `platforms/android-37.0/android.jar` 里的签名为准）。所有对它的引用都关在
 * [Impl] 里，只有确认 API ≥ 31 才实例化——`AdpfSession` 这个壳本身在旧系统上
 * 可以安全加载（否则字段类型会在类加载期触发 NoClassDefFoundError）。
 */
class AdpfSession(private val context: Context) {

    private var impl: Impl? = null

    /** @return 会话是否真的建起来了；false 表示调用方不该再做任何回报。 */
    fun start(targetNanos: Long): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        if (targetNanos <= 0) return false
        val created = impl ?: Impl(context).also { impl = it }
        return created.start(targetNanos)
    }

    /** @return null 表示成功；非 null 是必须回传给 Dart 的错误描述。 */
    fun report(workNanos: Long, targetNanos: Long): String? {
        val impl = this.impl ?: return "session-not-started"
        return impl.report(workNanos, targetNanos)
    }

    fun stop() {
        impl?.stop()
    }

    private class Impl(private val context: Context) {
        private val manager: PerformanceHintManager? =
            context.getSystemService(PerformanceHintManager::class.java)
        private var session: PerformanceHintManager.Session? = null
        private var lastTarget = 0L

        fun start(targetNanos: Long): Boolean {
            stop()
            val m = manager ?: run {
                log("取不到 PerformanceHintManager，跳过")
                return false
            }
            val tids = flutterThreadIds()
            if (tids.isEmpty()) {
                log("扫不到 ui/raster 线程，跳过")
                return false
            }
            val created = runCatching { m.createHintSession(tids, targetNanos) }
                .onFailure { log("createHintSession 失败：$it") }
                .getOrNull() ?: return false
            session = created
            lastTarget = targetNanos
            log(
                "会话已建立 tids=${tids.joinToString(",")} " +
                    "target=${targetNanos / 1000}µs"
            )
            return true
        }

        /** @return null 表示成功；非 null 是要回传给 Dart 的错误描述。 */
        fun report(workNanos: Long, targetNanos: Long): String? {
            val s = session ?: return "session-closed"
            if (workNanos <= 0) return null
            // 目标时长跟着刷新率变（60/90/120 档），变化时才发 Binder 调用
            if (targetNanos > 0 && targetNanos != lastTarget) {
                if (runCatching { s.updateTargetWorkDuration(targetNanos) }.isSuccess) {
                    lastTarget = targetNanos
                }
            }
            val result = runCatching { s.reportActualWorkDuration(workNanos) }
            if (result.isFailure) {
                // 会话被系统回收（EPIPE）时继续调用只会刷日志，直接关掉等下次重启。
                // 失败必须回传：Dart 侧的 catchError / 失败计数 / 自愈全靠这一条。
                log("reportActualWorkDuration 失败，关闭会话：${result.exceptionOrNull()}")
                stop()
                return "report-failed: ${result.exceptionOrNull()?.message}"
            }
            return null
        }

        fun stop() {
            session?.let { runCatching { it.close() } }
            session = null
            lastTarget = 0L
        }

        /**
         * 扫 `/proc/self/task/<tid>/comm` 找引擎的两个工作线程。
         *
         * 为什么不从 Java 拿：raster 是原生线程，不在 `Thread.getAllStackTraces()`
         * 里；`/proc` 是唯一不需要改引擎就能拿到 tid 的路。线程名是引擎的实现
         * 细节（`<engineId>.ui` / `<engineId>.raster`），扫不到就安静跳过，
         * 不做任何假定。
         */
        private fun flutterThreadIds(): IntArray {
            val tasks = File("/proc/self/task").listFiles() ?: return IntArray(0)
            val ids = ArrayList<Int>(4)
            for (task in tasks) {
                val tid = task.name.toIntOrNull() ?: continue
                val name = runCatching { File(task, "comm").readText().trim() }
                    .getOrNull() ?: continue
                if (name.endsWith(".ui") || name.endsWith(".raster")) {
                    ids.add(tid)
                }
            }
            return ids.toIntArray()
        }

        private fun log(message: String) = Log.i(LOG_TAG, "adpf: $message")
    }
}
