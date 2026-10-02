package com.zzh.goodshare

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "goodshare/secure_window")
            .setMethodCallHandler { call, result ->
                if (call.method == "setSecure") {
                    val secure = call.arguments as? Boolean ?: false
                    runOnUiThread {
                        if (secure) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                    }
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
        // 附件 URI 持久化权限桥（content-pipeline §7 引用模式补救）：
        // persistUri 对 content:// 尝试 takePersistableUriPermission；
        // 源 app 未授 FLAG_GRANT_PERSISTABLE_URI_PERMISSION 时抛 SecurityException，
        // 返回 false 由 Dart 层降级（条目仍为 ref，走迁移清单兜底）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "goodshare/attach")
            .setMethodCallHandler { call, result ->
                if (call.method == "persistUri") {
                    val uri = call.arguments as? String
                    if (uri == null) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    result.success(
                        try {
                            contentResolver.takePersistableUriPermission(
                                android.net.Uri.parse(uri),
                                android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION,
                            )
                            true
                        } catch (_: SecurityException) {
                            false
                        } catch (_: IllegalArgumentException) {
                            false
                        }
                    )
                } else {
                    result.notImplemented()
                }
            }
        // 端侧 LLM 桥（docs/design/on-device-llm.md）：isAvailable/unavailableReason/
        // generate/socModel 四方法协议，实现见 LlmBridge。
        LlmBridge.register(
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "goodshare/llm"),
            this,
        )
    }
}
