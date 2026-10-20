package com.zzh.goodshare

import android.os.Handler
import android.os.Looper
import com.zzh.goodhub.mcp.IMcpCallback
import com.zzh.goodhub.mcp.plugin.GoodHubPluginService
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugins.GeneratedPluginRegistrant
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeoutException
import java.util.concurrent.TimeUnit

/**
 * goodshare 本地 Binder 插件服务（server 端，goodhub 契约 thirdconnect.md §1.2.2）。
 *
 * 2026-10-20 迁移：从「手搓 AIDL + 手写 IMcpChannel.Stub」改为继承官方 SDK
 * [GoodHubPluginService]（由 SDK 承载 AIDL 语义 + 基类 onBind），仅重写三个接管口子把请求
 * 路由到 goodshare 自己的 Dart 通道：
 *  - [handleJsonRpc]：全部 JSON-RPC（initialize/tools/list/tools/call）转 MethodChannel 给 Dart
 *    的 [McpServer.handleJsonRpc]，阻塞等回包（Binder 线程非主线程，不 ANR）。
 *  - [onHostCallback]：宿主 registerCallback 时把回调汇集进 [McpCallbackHub]（供 MainActivity 侧
 *    task_queued 通知桥）+ 通知 Dart hostCallbackReady。
 *  - [onHostAnswerReverse]：宿主对反向请求的应答回程，post 到 MethodChannel `answerReverse`。
 *
 * AIDL 契约现在唯一来自 SDK 的 :contract AAR（com.zzh.goodhub.mcp.IMcpChannel/IMcpCallback），
 * goodshare 侧自拷副本已删除，跨仓手抄历史清零。DESCRIPTOR / 方法签名 / 发现约定四常量全部
 * 冻结，与 SDK 仓一致（改包名 = 存量插件 bind 全败，且运行期才暴露）。
 *
 * 线程：[handleJsonRpc] 由 goodhub 在 Binder 线程触发（非主线程），直接阻塞等待 Dart 回传
 * 不触发 ANR（§1.2.3）；首调前经 [ready] 信号解除引擎未就绪竞态。
 */
class McpBinderService : GoodHubPluginService(SERVER_ID, SERVER_TITLE) {

    private var flutterEngine: FlutterEngine? = null
    @Volatile
    private var channel: MethodChannel? = null

    /** 引擎主线程 Handler：MethodChannel.invokeMethod 必须在其上执行（@UiThread），
     *  handleJsonRpc/onHostCallback/onHostAnswerReverse 均在 Binder 线程触发，须 post 过来。 */
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Dart 后台 entrypoint 就绪信号：注册完 MethodChannel 处理器后放行 call。 */
    private val ready = CompletableFuture<Boolean>()

    override fun onCreate() {
        super.onCreate()
        initEngine()
    }

    private fun initEngine() {
        if (flutterEngine != null) return
        // 独立 headless 引擎（不挂 UI renderer）；与主 isolate 共用 App 进程，随 Binder 拉起。
        // FlutterEngine 构造器内部已通过 FlutterInjector 初始化 FlutterLoader（含资源抽取），
        // 故路径须取「引擎所用的同一个 loader」，绝不可 new FlutterLoader()——新实例未 init →
        // findAppBundlePath 读 flutterApplicationInfo=null → NPE（随调随起全新进程必现）。
        val engine = FlutterEngine(this)
        GeneratedPluginRegistrant.registerWith(engine) // sqflite/path_provider 等插件注入
        flutterEngine = engine
        val loader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) {
            // 兜底：若引擎构造未触发初始化（跨 Flutter 版本差异），显式与 FlutterActivity 同款配对。
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)
        }
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "ready" -> {
                    ready.complete(true)
                    result.success(null)
                }
                "pushEvent" -> {
                    // Dart → 宿主：progress / 反向请求帧，经 SDK 基类持有的 IMcpCallback.onEvent
                    // 推给 goodhub。emitEvent 内部走基类 pushEvent（已持有宿主回调），goodshare
                    // 不再自建一份；McpCallbackHub 仍独立持一份供 MainActivity 侧通知桥（见 onHostCallback）。
                    val json = call.arguments as? String
                    if (json != null) {
                        try {
                            emitEvent(json)
                        } catch (_: Exception) {
                            // 回调断连由宿主 DeathRecipient 感知，此处静默。
                        }
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                "package:goodshare/mcp_binder_entrypoint.dart",
                ENTRYPOINT,
            ),
        )
    }

    /**
     * 接管全部 JSON-RPC 路由（initialize/tools/list/tools/call）。基类 [GoodHubPluginService]
     * 默认走反射派发器（@McpTool），但 goodshare 工具在 Dart，须全部转 MethodChannel 给
     * [McpServer.handleJsonRpc]。本方法在 Binder 线程同步执行（不 ANR）。
     */
    override fun handleJsonRpc(jsonRpcRequest: String): String {
        val reqId = extractId(jsonRpcRequest) // B3：先取 id，供错误帧回显
        // 等 Dart entrypoint 注册完处理器（上限 5s，对齐 goodhub 冷启 5s，R2）。
        if (!ready.completeFutureOrDefault(false, 5, TimeUnit.SECONDS)) {
            return errorJson(reqId, -32000, "MCP Binder 引擎未就绪（Dart entrypoint 超时）")
        }
        // 本 Flutter 版 MethodChannel.invokeMethod 返回 void，结果经 Result 回调投递；
        // 用 CompletableFuture 在 Binder 线程阻塞等待 Dart 回传（§1.2.3：Binder 线程非主线程，不 ANR）。
        // invokeMethod 必须在引擎主线程执行（@UiThread），故 post 到 mainHandler。
        val ch = channel
        if (ch == null) return errorJson(reqId, -32603, "MCP Binder 通道未建立")
        val resultFuture = CompletableFuture<String?>()
        mainHandler.post {
            try {
                ch.invokeMethod(
                    "dispatch",
                    jsonRpcRequest,
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            resultFuture.complete(result as? String)
                        }
                        override fun error(code: String, msg: String?, details: Any?) {
                            resultFuture.completeExceptionally(Exception(msg ?: code))
                        }
                        override fun notImplemented() {
                            resultFuture.completeExceptionally(Exception("Dart 未实现 dispatch"))
                        }
                    },
                )
            } catch (e: Exception) {
                resultFuture.completeExceptionally(e)
            }
        }
        // B1：加 per-call ≤5s 超时，避免 Dart 不回（工具死锁/引擎异常）时 Binder 线程永久阻塞（致命）。
        // 长工具（>5s，含 sampling）的彻底解在 #4/#5 用 _async + onEvent 终帧，使 call 永远秒回。
        return try {
            val result = resultFuture.get(5, TimeUnit.SECONDS)
            result ?: errorJson(reqId, -32603, "Dart 返回空响应")
        } catch (e: TimeoutException) {
            errorJson(reqId, -32000, "MCP Binder call timeout")
        } catch (e: Exception) {
            errorJson(reqId, -32603, "MCP Binder 调用失败: ${e.message}")
        }
    }

    /**
     * 宿主 registerCallback / 注销（传 null）：把回调汇集进进程内 [McpCallbackHub]
     * （供 MainActivity 侧 task_queued 通知桥），并通知 Dart 通道可用状态。
     */
    override fun onHostCallback(cb: IMcpCallback?) {
        // Register 到进程内汇集点：供 UI 主 isolate 的通知桥转发（§3.12）。
        // 注销（传 null）同步摘钩——goodhub 主动解绑后不再给它推帧。
        McpCallbackHub.attach(cb)
        // 通知 Dart 侧回调通道已建立（异步事件 / 反向请求可用，#4/#5 批次接）。
        // invokeMethod 须引擎主线程执行。
        mainHandler.post { runCatching { channel?.invokeMethod("hostCallbackReady", cb != null) } }
    }

    /**
     * 宿主对插件反向请求的应答回程（server→client 反向请求闭环，§5）。
     * 基类已按 id 关联并唤醒 Kotlin 侧在途 future；goodshare 反向请求走 Dart 在途表，
     * 故这里把应答 post 到 MethodChannel `answerReverse` 转给 Dart [McpServer.answerReverse]。
     */
    override fun onHostAnswerReverse(jsonRpcResponse: String) {
        // 引擎未就绪时静默丢弃（超时会由 completer.timeout 兜底）；invokeMethod 须主线程。
        mainHandler.post { runCatching { channel?.invokeMethod("answerReverse", jsonRpcResponse) } }
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            flutterEngine?.destroy()
        } catch (_: Exception) {
            // 引擎销毁异常忽略。
        }
        flutterEngine = null
        channel = null
        McpCallbackHub.attach(null) // 服务销毁：桥出口一并注销
    }

    companion object {
        /** serverId：与 AndroidManifest meta-data com.zzh.goodhub.SERVER_ID 保持一致（冻结）。 */
        const val SERVER_ID = "goodshare"
        /** serverTitle：与 AndroidManifest meta-data com.zzh.goodhub.SERVER_TITLE 保持一致（冻结）。 */
        const val SERVER_TITLE = "GoodShare"

        const val CHANNEL = "goodshare/mcp_binder"
        const val ENTRYPOINT = "mcpBinderMain"

        /** JSON-RPC error 帧（Binder call 需返回字符串；回显请求 id，见 B3）。 */
        private fun errorJson(id: Any?, code: Int, message: String): String =
            JSONObject().apply {
                put("jsonrpc", "2.0")
                // id 为 null / JSONObject.NULL → 写 JSON null；number/string 原样（自动加引号）
                put("id", if (id == null) JSONObject.NULL else id)
                put(
                    "error",
                    JSONObject().apply {
                        put("code", code)
                        put("message", message)
                    },
                )
            }.toString()

        /** 从请求 JSON 解析 id（number/string/null），供错误帧回显（B3）。 */
        private fun extractId(request: String): Any? = try {
            JSONObject(request).opt("id")
        } catch (_: Exception) {
            null
        }

        /**
         * [CompletableFuture.get] 超时兜底（Kotlin 1.8 无 `completeOnTimeout`，1.9+ 才有）：
         * 等 [ready] 至多 [timeout]；到点未就绪返回 [default]（永不抛，避免 call 挂死）。
         */
        private fun CompletableFuture<Boolean>.completeFutureOrDefault(
            default: Boolean,
            timeout: Long,
            unit: TimeUnit,
        ): Boolean = try {
            get(timeout, unit)
        } catch (_: Exception) {
            default
        }
    }
}
