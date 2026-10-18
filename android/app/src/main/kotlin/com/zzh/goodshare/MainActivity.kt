package com.zzh.goodshare

import android.content.Intent
import android.view.WindowManager
import org.json.JSONObject
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
                } else if (call.method == "uriReachable") {
                    // 引用态可达性检测（content-pipeline §7）：
                    // file:// 绝对路径直接 File.exists；
                    // content:// 走 ContentResolver——openFileDescriptor 成功即可读，
                    //FileNotFoundException / SecurityException（授权失效）→ 不可达。
                    val uri = call.arguments as? String
                    if (uri == null) {
                        result.success(true)
                        return@setMethodCallHandler
                    }
                    result.success(
                        try {
                            if (uri.startsWith("content://")) {
                                contentResolver.openFileDescriptor(
                                    android.net.Uri.parse(uri), "r",
                                )?.close()
                                true
                            } else {
                                java.io.File(android.net.Uri.parse(uri).path ?: "").exists()
                            }
                        } catch (_: java.io.FileNotFoundException) {
                            false
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
        // §3.12.3 一键唤醒：拉起 goodhub（AI 宿主）接管积压任务。
        // Flutter 侧无 PackageManager 访问能力，经本通道由原生执行；**包可见性前置**：
        // Android 11+ 必须在 Manifest <queries> 补 <package android:name="com.zzh.goodhub"/>，
        // 缺该声明时 getLaunchIntentForPackage 恒返回 null（已装也误判「未安装」）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "goodshare/host_launch")
            .setMethodCallHandler { call, result ->
                if (call.method == "launchGoodhub") {
                    val intent = packageManager.getLaunchIntentForPackage(GOODHUB_PACKAGE)
                    if (intent == null) {
                        result.success(false) // 未安装 → Dart 侧给「未检测到」兜底
                    } else {
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        runCatching { startActivity(intent) }
                            .onSuccess { result.success(true) }
                            .onFailure { result.success(false) }
                    }
                } else {
                    result.notImplemented()
                }
            }
        // §3.12 通知桥（UI 主 isolate → goodhub）：goodhub 是 **Binder-only**，`IMcpCallback`
        // 注册在 McpBinderService 的 headless FlutterEngine（另一 isolate），而入队发生在主
        // isolate；两者**同一个 Android 进程**（Manifest 未给 service 声明 android:process），
        // 故经进程内单例 [McpCallbackHub] 单向转发即可闭环。帧正文由 Dart 侧唯一定义处给出，
        // 此处只负责序列化，**不改帧内容**（尤其不得补 id——§1.2.2 会被判成反向请求响应）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "goodshare/mcp_bridge")
            .setMethodCallHandler { call, result ->
                if (call.method == "notifyTaskQueued") {
                    val args = call.arguments as? Map<*, *>
                    if (args == null) {
                        result.success(false)
                    } else {
                        @Suppress("UNCHECKED_CAST")
                        val json = JSONObject(args as Map<String, Any?>).toString()
                        result.success(McpCallbackHub.broadcast(json))
                    }
                } else {
                    result.notImplemented()
                }
            }
        // 媒体探测桥（media-native P1，替换 FFprobeKit 只读元数据）：见 MediaBridge。
        MediaBridge.register(
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "goodshare/media"),
            this,
        )
    }

    companion object {
        /** goodhub 宿主包名（§3.12.3 跨仓常量族：与 Binder 发现、MCP_SERVER 权限同源）。 */
        private const val GOODHUB_PACKAGE = "com.zzh.goodhub"
    }
}
