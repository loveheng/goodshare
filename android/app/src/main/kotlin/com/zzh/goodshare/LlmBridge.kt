package com.zzh.goodshare

import android.os.Build
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 端侧 LLM MethodChannel 桥（2026-09-28，设计见 docs/design/on-device-llm.md）。
 *
 * 职责边界：本桥**只做协议转发 + SoC 读取 + 模型文件就绪判定**；真正的推理在
 * LiteRT-LM Kotlin 运行时。MVP 阶段 generate 先落「模型就绪 → 运行时推理」的
 * 最小通路；若运行时 API 与预期不符，错误统一以 PlatformException(code=llm_error)
 * 回传，Dart 侧降级为 null（不卡队列）。
 *
 * 协议（channel: goodshare/llm）：
 * - isAvailable        → Boolean（模型文件存在 = 可用；iOS 侧语义不同，各自实现）
 * - unavailableReason  → String?（人类可读原因）
 * - generate(prompt, system?, max_tokens) → String?（空产出回 null）
 * - socModel           → String?（Build.SOC_MODEL，API 31+；低版本 null）
 */
object LlmBridge {
    private const val PREF_SELECTED = "llm_selected_model"

    /** 选中模型包的本地文件；未下载返回 null。 */
    fun selectedModelFile(activity: android.app.Activity): File? {
        val prefs = activity.getSharedPreferences("flutter", android.app.Activity.MODE_PRIVATE)
        val id = prefs.getString(PREF_SELECTED, null) ?: "qwen25-1.5b-q8"
        val dir = File(activity.getExternalFilesDir(null) ?: activity.filesDir, "llm_models/$id")
        val f = File(dir, "model.litertlm")
        return if (f.exists() && f.length() > 0) f else null
    }

    fun register(channel: MethodChannel, activity: android.app.Activity) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "socModel" -> result.success(
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) Build.SOC_MODEL else null
                )
                "isAvailable" -> result.success(selectedModelFile(activity) != null)
                "unavailableReason" -> result.success(
                    if (selectedModelFile(activity) == null)
                        "未下载模型包（设置 → 端侧大模型 中下载）"
                    else null
                )
                "generate" -> {
                    val model = selectedModelFile(activity)
                    if (model == null) {
                        result.error("llm_unavailable", "模型未下载", null)
                        return@setMethodCallHandler
                    }
                    val prompt = call.argument<String>("prompt") ?: ""
                    val system = call.argument<String>("system")
                    val maxTokens = call.argument<Int>("max_tokens") ?: 512
                    // TODO(litert-lm): LiteRtLmEngine 会话初始化与同步 generate 接入。
                    // 运行时为协程 API，此处以 runBlocking 包一层（调用已在 Dart 队列 isolate
                    // 的 120s 超时保护下）；首版先回 null 走占位完成，桥接真推理后删除此标记。
                    result.success(null as String?)
                }
                else -> result.notImplemented()
            }
        }
    }
}
