package com.zzh.goodshare

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * UI 主 isolate → Binder isolate 的**双向调用**进程内桥（W6-a 端侧算力消费）。
 *
 * 为什么需要：`IMcpCallback`（goodhub 反向请求的唯一管道）注册在 [McpBinderService]
 * 持有的 headless FlutterEngine（Binder isolate），而 W6 端侧异步调用从 UI 主 isolate
 * 发起（详情页即时摘要）。两个独立 FlutterEngine 在 Dart 层无共享内存，但**同一个
 * Android 进程**（service 未声明 android:process），故经进程内单例做 MethodChannel
 * 一跳转发——与 §3.12 通知桥 [McpCallbackHub] 同构，区别：本桥是请求/响应（等回程），
 * 不是 fire-and-forget。
 *
 * 线程：`invokeMethod` 必须引擎主线程（@UiThread）执行；调用方可能在任意线程，
 * 一律 post 主 looper。
 *
 * 超时：95s > Dart 侧 _serverRequest 90s 上限——本侧超时只防 UI 调用永久挂起
 * （Dart 侧 90s 超时已先自行了结并回错误帧）。
 *
 * **禁阻塞主线程**（2026-11-07 联调实证教训）：宿主冷态模型装载可达数十秒，
 * 若在 main looper 上 future.get(95s) 等待，UI 线程全程冻结（调试桥 HTTP /
 * 动画全部无响应直至 95s 释放）。实现为 orTimeout + whenComplete 异步等，
 * 结果就绪时 post 回主 looper 再经 result 投递（MethodChannel.Result 须
 * 主线程投递）。
 */
object McpBinderBridge {

    @Volatile
    private var channel: MethodChannel? = null

    private const val TAG = "McpBinderBridge"

    private val mainHandler = Handler(Looper.getMainLooper())

    /** [McpBinderService] 引擎就绪 / 销毁时注册 / 摘除（销毁传 null）。 */
    fun attach(ch: MethodChannel?) {
        Log.i(TAG, "attach ready=${ch != null}")
        channel = ch
    }

    /** Binder isolate 引擎是否就绪（false = 宿主未连入或服务未拉起）。 */
    val isReady: Boolean
        get() = channel != null

    /**
     * 转发一次双向调用到 Binder isolate：结果字符串经 [result] 原样回传（Dart 侧
     * 解析联合态）；桥未就绪 / 超时 / Dart 侧异常均以 `error` 投递（调用方降级）。
     */
    fun invoke(method: String, args: Any?, result: MethodChannel.Result) {
        val ch = channel
        if (ch == null) {
            Log.w(TAG, "invoke $method → NOT_READY（channel 未 attach：服务未拉起/引擎未就绪/已摘除）")
            result.error("bridge_not_ready", "MCP Binder 引擎未就绪（GoodHub 未连入或服务未拉起）", null)
            return
        }
        Log.i(TAG, "invoke $method → 转发 Binder isolate")
        mainHandler.post {
            val future = CompletableFuture<Any?>()
            try {
                ch.invokeMethod(
                    method,
                    args,
                    object : MethodChannel.Result {
                        override fun success(value: Any?) {
                            future.complete(value)
                        }

                        override fun error(code: String, message: String?, details: Any?) {
                            future.completeExceptionally(Exception("$code $message".trim()))
                        }

                        override fun notImplemented() {
                            future.completeExceptionally(Exception("Dart 未实现: $method"))
                        }
                    },
                )
            } catch (e: Exception) {
                future.completeExceptionally(e)
            }
            // 非阻塞等待：orTimeout + whenComplete；结果就绪（宿主回程 / 超时 /
            // 异常）后 post 回主 looper 再投递——主线程零占用，宿主冷装载期间
            // UI 与调试桥保持响应。
            future.orTimeout(95, TimeUnit.SECONDS).whenComplete { value, ex ->
                Log.i(
                    TAG,
                    "invoke 回程 ex=${ex?.message ?: "ok"} content=${(value as? String)?.take(400) ?: value}",
                )
                mainHandler.post {
                    if (ex == null) {
                        result.success(value)
                    } else if (ex is TimeoutException) {
                        result.error("bridge_timeout", "端侧反向请求超时（95s）", null)
                    } else {
                        result.error("bridge_error", ex.message ?: "bridge 调用失败", null)
                    }
                }
            }
        }
    }
}
