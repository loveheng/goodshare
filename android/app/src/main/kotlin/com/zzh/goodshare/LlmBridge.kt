package com.zzh.goodshare

import android.content.Context
import android.os.Build
import android.util.Log
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Conversation
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.ExperimentalApi
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.SamplerConfig
import com.google.ai.edge.litertlm.ThinkingConfig
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * 端侧 LLM MethodChannel 桥（2026-09-29 真推理接入，设计见 docs/design/on-device-llm.md）。
 *
 * 跑 LiteRT-LM Kotlin 运行时（com.google.ai.edge.litertlm:litertlm-android）：
 * - [Engine] 按「单模型常驻」懒加载（mmap 大文件，首次 generate 时初始化一次）；
 * - 每次生成新建 [Conversation]（一次性任务，不跨条目复用 KV，防上下文串味），用完即关；
 * - 全部推理跑在单线程 executor 上——createConversation / sendMessage 均为**阻塞调用**，
 *   绝不能上主线程；单线程同时天然串行化，与 Dart 队列的逐任务消费对齐；
 * - 错误统一 PlatformException(code=llm_error) 回传，Dart 侧降级为 null（不卡队列）。
 *
 * 协议（channel: goodshare/llm，与 iOS LlmBridge 同一套四方法）：
 * - isAvailable        → Boolean（模型文件存在 = 可用；iOS 侧语义不同，各自实现）
 * - unavailableReason  → String?（人类可读原因）
 * - generate(prompt, system?, max_tokens) → String?（空产出回 null）
 * - socModel           → String?（Build.SOC_MODEL，API 31+；低版本 null）
 */
@OptIn(ExperimentalApi::class)
object LlmBridge {
    private const val TAG = "LlmBridge"

    /** Flutter shared_preferences 在原生侧的实际落点：文件名与 key 前缀都带 flutter. 前缀。 */
    private const val PREF_SELECTED = "flutter.llm_selected_model"
    private const val DEFAULT_MODEL_ID = "qwen25-1.5b-q8"

    private val executor = Executors.newSingleThreadExecutor()
    private var engine: Engine? = null
    private var loadedPath: String? = null
    private var modelFilePath: String? = null // Dart 显式 publish 的模型绝对路径（优先于拼路径）

    /** 容器上下文上限（设计 §3.1）：Qwen q8 包 4096，Gemma NPU 包 1280。 */
    private fun maxCtxFor(modelId: String) = if (modelId.startsWith("qwen")) 4096 else 1280

    private fun selectedModelId(activity: Context): String {
        val prefs = activity.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        return prefs.getString(PREF_SELECTED, null) ?: DEFAULT_MODEL_ID
    }

    /// 选中模型的本地文件；路径与 Dart 侧 LlmModelManager（path_provider documents 目录）
    /// 严格对齐——Flutter 的 documents 在原生侧是 getDir("app_flutter")，另有 filesDir 兜底。
    ///
    /// 回退策略：精确 id 找不到时，**扫描 llm_models/ 下任意已下载模型**（优先 qwen 系），
    /// 兜住「Dart 选中 id 与已下载文件错位」的静默失败——只要设备上有已下好的模型，引擎即可用。
    private fun selectedModelFile(activity: Context): Pair<String, File>? {
        val id = selectedModelId(activity)
        // 优先 Dart 显式 publish 的绝对路径（消除 path_provider 与原生 getDir 的路径差异）
        val explicit = modelFilePath
        if (explicit != null) {
            val f = File(explicit)
            if (f.exists() && f.length() > 0) return id to f
        }
        val docs = activity.getDir("app_flutter", Context.MODE_PRIVATE)
        val candidates = listOf(
            File(File(File(docs, "llm_models"), id), "model.litertlm"),
            File(File(File(activity.filesDir, "llm_models"), id), "model.litertlm"),
        )
        for (f in candidates) {
            if (f.exists() && f.length() > 0) return id to f
        }
        // 精确 id 落空：回退到任意已下载模型（优先 qwen 系，与 DEFAULT_MODEL_ID 同族）
        return scanAnyModel(docs) ?: scanAnyModel(activity.filesDir)
    }

    /// 扫描 [root]/llm_models/<id>/model.litertlm，返回第一个已下载（size>0）的模型。
    private fun scanAnyModel(root: File): Pair<String, File>? {
        val dir = File(root, "llm_models")
        if (!dir.isDirectory) return null
        val found = dir.listFiles { d -> d.isDirectory }?.mapNotNull { d ->
            val f = File(d, "model.litertlm")
            if (f.exists() && f.length() > 0) d.name to f else null
        } ?: return null
        return found.firstOrNull { it.first.startsWith("qwen") } ?: found.firstOrNull()
    }

    fun register(channel: MethodChannel, activity: Context) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setModelPath" -> {
                    modelFilePath = call.arguments as? String
                    Log.d(TAG, "setModelPath=$modelFilePath")
                    result.success(null)
                }
                "socModel" -> result.success(
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) Build.SOC_MODEL else null
                )
                "isAvailable" -> {
                    val picked = selectedModelFile(activity)
                    Log.d(
                        TAG,
                        "isAvailable=${picked != null} selectedId=${selectedModelId(activity)} " +
                            "path=${picked?.second?.absolutePath}"
                    )
                    result.success(picked != null)
                }
                "unavailableReason" -> result.success(
                    if (selectedModelFile(activity) == null)
                        "未下载模型包（设置 → 端侧大模型 中下载）"
                    else null
                )
                "generate" -> {
                    val picked = selectedModelFile(activity)
                    if (picked == null) {
                        result.error("llm_unavailable", "模型未下载", null)
                        return@setMethodCallHandler
                    }
                    val (modelId, file) = picked
                    val prompt = call.argument<String>("prompt") ?: ""
                    val system = call.argument<String>("system")
                    val maxTokens = call.argument<Int>("max_tokens") ?: 512
                    // 推理在后台单线程执行；MethodChannel 的 result 允许跨线程回传
                    executor.execute {
                        try {
                            result.success(generateBlocking(activity, modelId, file, prompt, system, maxTokens))
                        } catch (t: Throwable) {
                            result.error("llm_error", t.message ?: "LLM 推理失败", null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** 阻塞推理：只在 executor 线程内执行。 */
    private fun generateBlocking(
        activity: Context,
        modelId: String,
        file: File,
        prompt: String,
        system: String?,
        maxOutputTokens: Int,
    ): String? {
        ensureLoaded(activity, modelId, file)
        val eng = engine ?: throw IllegalStateException("Engine 初始化失败")
        val text = if (system != null) "$system\n\n$prompt" else prompt
        // 一次性任务：每次新建会话（不跨条目复用 KV），用完即关
        val conv = eng.createConversation(
            ConversationConfig(
                samplerConfig = SamplerConfig(topK = 40, topP = 0.95, temperature = 0.7, seed = 0)
            )
        )
        try {
            val reply = conv.sendMessage(
                Message.user(text),
                maxOutputToken = maxOutputTokens,
                thinkingConfig = ThinkingConfig(enableThinking = false),
            ).toString()
            val cleaned = reply.trim()
            return cleaned.ifEmpty { null }
        } finally {
            runCatching { conv.close() }
        }
    }

    /** 引擎懒加载：路径或上下文配置变化时重建（mmap 大文件，只此一次开销）。 */
    private fun ensureLoaded(activity: Context, modelId: String, file: File) {
        val maxCtx = maxCtxFor(modelId)
        if (engine != null && loadedPath == file.absolutePath) return
        runCatching { engine?.close() }
        val cacheDir = File(activity.cacheDir, "litert_lm").apply { mkdirs() }
        val threads = Runtime.getRuntime().availableProcessors().coerceIn(1, 6)
        val eng = Engine(
            EngineConfig(
                modelPath = file.absolutePath,
                backend = Backend.CPU(threadCount = threads),
                cacheDir = cacheDir.absolutePath,
                maxNumTokens = maxCtx,
            )
        )
        eng.initialize()
        engine = eng
        loadedPath = file.absolutePath
    }
}
