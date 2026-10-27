package com.huaxu.judging

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * 用户把「正在保持连接」这条通知划掉时回调。
 *
 * 记住这件事，之后只更新状态不再弹提示；服务本身不动，消息照常送达。
 * 只在 Android 13+ 会触发（12 及以下前台服务通知不可清除）。
 */
class KeepAliveDismissReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != SyncKeepAliveService.ACTION_DISMISSED) return
        SyncKeepAliveService.markDismissed(context)
        Log.i("ZhijiKeepAlive", "notification dismissed by user, staying silent")
    }
}