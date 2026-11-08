package app.supermarket

import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.Display
import android.view.Surface
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 刷新率控制：**按需投票**，不是一直钉最高档。
 *
 * Flutter 侧不限制帧率——引擎跟着 Choreographer 的 vsync 走，屏幕多少 Hz 就
 * 按多少 Hz 的目标时间画。所以「能不能 120」取决于三件事：
 *   1. 屏幕有没有这个 mode（`Display.supportedModes`）；
 *   2. 系统 / OEM 的刷新率策略允不允许本应用升档（很多机型只给白名单应用
 *      或游戏开满）；
 *   3. 应用有没有提出请求。
 *
 * 这里做第 3 件：Android 11（API 30）起用 `Window.setFrameRate` 投票，
 * Dart 侧 `ScrollFrameRateController` 只在滑动期间投 120、停下 800ms 后投 60。
 *
 * ⚠️ **为什么不两份机制并用**：早先的版本在 `onCreate` 里把
 * `preferredDisplayModeId` 固定成最高档。那是「钉住显示模式」，和
 * `setFrameRate` 是两套信号，同时存在会互相覆盖——到底听谁的取决于 ROM
 * 实现，无法在测试里复现。所以 API 30 以上只走投票，固定 mode 只留给
 * 没有 `setFrameRate` 的旧系统兜底。
 *
 * ⚠️ 投票也只是**请求**。要以实测为准：`logcat -s app.supermarket` 看
 * `refresh: 投票 ... -> ...` 这行，再 `dumpsys display` 看当前 mode。
 */
class MainActivity : FlutterActivity() {
    /**
     * ADPF 会话（`adpf.start` / `adpf.report` / `adpf.stop`）。
     * 懒加载：只有 Dart 侧真的调 start 才会去扫线程、建会话。
     */
    private val adpf by lazy { AdpfSession(applicationContext) }

    override fun onCreate(savedInstanceState: Bundle?) {
        // API 30 以下没有 setFrameRate，只能退回固定 mode 兜住最高档
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            pinHighestRefreshRate()
        }
        super.onCreate(savedInstanceState)
        logModes()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                // 任何分支抛异常都不能让 result 悬空：否则 Dart 侧 await
                // 永不完成，异常还会变成一条 unhandled async error。
                try {
                    when (call.method) {
                        "setFrameRate" -> {
                            // StandardMessageCodec 可能把整数编成 Long；强转 Int 会抛 CCE
                            val fps = (call.argument<Number>("fps") ?: 0).toInt()
                            val fixed = call.argument<Boolean>("fixed") ?: false
                            result.success(applyFrameRate(fps, fixed))
                        }
                        "adpf.start" -> {
                            val target = (call.argument<Number>("targetNanos") ?: 0).toLong()
                            result.success(adpf.start(target))
                        }
                        "adpf.report" -> {
                            val error = adpf.report(
                                (call.argument<Number>("workNanos") ?: 0).toLong(),
                                (call.argument<Number>("targetNanos") ?: 0).toLong(),
                            )
                            if (error == null) {
                                result.success(null)
                            } else {
                                result.error("ADPF_REPORT_FAILED", error, null)
                            }
                        }
                        "adpf.stop" -> {
                            adpf.stop()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    Log.e(LOG_TAG, "perf: ${call.method} 处理失败：$e")
                    result.error("PERF_HANDLER_ERROR", e.message, null)
                }
            }
    }

    /**
     * 就 [fps] 就近挑一个 mode（同分辨率内），把票投出去。
     *
     * @param fixed true = `FIXED_SOURCE`，要求系统**不得**用重帧凑数（回落用）；
     *              false = `DEFAULT`，允许系统按倍数自由选择（升档用，撑不住时
     *              退成 60 重帧比强撑 120 的 judder 好看）。
     * @return 实际投票的刷新率（取整）；0 表示没投出去。
     */
    private fun applyFrameRate(fps: Int, fixed: Boolean): Int {
        if (fps <= 0) return 0
        val display = display() ?: return 0
        val mode = pickMode(display, fps) ?: return 0
        val target = mode.refreshRate

        // ⚠️ 这个 API 在 `Surface` 上，不在 `Window` 上（`Window` 只有
        // `preferredRefreshRate` 这种一次性偏好）。所以必须拿到 Flutter 正在
        // 呈现的那块 Surface —— 即 FlutterSurfaceView 的 holder.surface。
        val surface = flutterSurface()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && surface != null) {
            val compatibility = if (fixed) {
                Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE
            } else {
                Surface.FRAME_RATE_COMPATIBILITY_DEFAULT
            }
            surface.setFrameRate(target, compatibility)
        } else {
            // 兜底：API < 30，或拿不到有效 Surface（TextureView 模式、还没 attach）
            @Suppress("DEPRECATION")
            window.attributes = window.attributes.apply { preferredRefreshRate = target }
        }

        Log.i(LOG_TAG, "refresh: 投票 ${fps}Hz fixed=$fixed -> ${target}Hz (modeId=${mode.modeId})")
        return Math.round(target)
    }

    /** Flutter 的呈现面（`FlutterSurfaceView` 继承 `SurfaceView`）。 */
    private fun flutterSurface(): Surface? {
        val sv = findSurfaceView(window.decorView) ?: return null
        val surface = sv.holder.surface
        return if (surface != null && surface.isValid) surface else null
    }

    private fun findSurfaceView(view: View): SurfaceView? = when (view) {
        is SurfaceView -> view
        is ViewGroup -> (0 until view.childCount)
            .firstNotNullOfOrNull { findSurfaceView(view.getChildAt(it)) }
        else -> null
    }

    /**
     * 只在**当前分辨率**内挑。为什么不 `maxByOrNull { refreshRate }`：不少
     * LTPO 面板把 120Hz 放在低一档分辨率上（1440p@90 / 1080p@120 并存），
     * 盲选最高刷新率会顺手把分辨率降下来——刷新率上去了，字变糊了。
     */
    private fun pickMode(display: Display, fps: Int): Display.Mode? {
        val modes = display.supportedModes ?: return null
        if (modes.isEmpty()) return null
        val current = display.mode
        val sameResolution = modes.filter {
            it.physicalWidth == current.physicalWidth &&
                it.physicalHeight == current.physicalHeight
        }
        val pool = sameResolution.ifEmpty { modes.toList() }
        // 先找「不低于请求值」里的最低一档（120 请求打到 90 面板上就落回 90），
        // 找不到才退到最高档。
        return pool.filter { it.refreshRate >= fps - 0.5f }.minByOrNull { it.refreshRate }
            ?: pool.maxByOrNull { it.refreshRate }
    }

    private fun display(): Display? =
        getSystemService(DisplayManager::class.java)?.getDisplay(Display.DEFAULT_DISPLAY)

    private fun logModes() {
        val display = display() ?: return
        val current = display.mode
        Log.i(
            LOG_TAG,
            "refresh: 当前=${current.refreshRate}Hz " +
                "(${current.physicalWidth}x${current.physicalHeight}, modeId=${current.modeId}); " +
                "全部档位=" + display.supportedModes.joinToString {
                    "${it.physicalWidth}x${it.physicalHeight}@${it.refreshRate}"
                },
        )
    }

    /** API 30 以下的兜底：没有 setFrameRate，只能把 window 固定到最高 mode。 */
    private fun pinHighestRefreshRate() {
        val display = display() ?: return
        val best = pickMode(display, Int.MAX_VALUE / 2) ?: return
        window.attributes = window.attributes.apply {
            preferredDisplayModeId = best.modeId
            preferredRefreshRate = best.refreshRate
        }
        Log.i(LOG_TAG, "refresh: 固定 mode ${best.refreshRate}Hz (modeId=${best.modeId})")
    }

    private companion object {
        const val CHANNEL = "itick/perf"
    }
}
