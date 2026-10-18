package com.zzh.goodshare

import android.os.DeadObjectException
import android.os.RemoteException
import com.zzh.goodhub.mcp.IMcpCallback

/**
 * goodhub 已注册回调的**进程内**汇集点（§3.12 `task_queued` 通知桥的信号跳板）。
 *
 * 为什么需要：`IMcpCallback` 由 goodhub 注册在 [McpBinderService] 持有的 headless
 * FlutterEngine（Binder isolate），而任务入队发生在 MainActivity 主 isolate——两边是
 * **两个独立 FlutterEngine**，Dart 层无共享内存；但 Manifest 未给 [McpBinderService]
 * 声明 `android:process`，故二者在**同一个 Android 进程**内，可用进程内单例做单向转发。
 * （若将来声明了独立进程，此处改为 `startService` 显式 Intent 即可，调用方不变。）
 *
 * 语义克制（对齐 §3.12 红线）：只在此转**一个信号帧**，不透业务数据、不等返回值；
 * 无回调在线即返回 false 由调用方静默丢弃——通知 best-effort，正确性仍由宿主侧
 * catch-up 兜底（§3.12.4）。
 */
object McpCallbackHub {

    @Volatile
    private var callback: IMcpCallback? = null

    /** 宿主注册 / 注销回调（注销传 null）。 */
    fun attach(cb: IMcpCallback?) {
        callback = cb
    }

    /** 是否有在线回调（= goodhub 已连入并完成 registerCallback）。 */
    val isAttached: Boolean
        get() = callback != null

    /**
     * 向 goodhub 推一帧已序列化的 JSON-RPC；返回是否投递成功。
     * 远端已死则就地摘除，避免后续每次都走异常路径（更不该让异常冒到入队调用链）。
     */
    fun broadcast(json: String): Boolean {
        val cb = callback ?: return false
        return try {
            cb.onEvent(json)
            true
        } catch (_: DeadObjectException) {
            attach(null) // 宿主进程已死：摘除，等下次 registerCallback 重建
            false
        } catch (_: RemoteException) {
            false
        }
    }
}
