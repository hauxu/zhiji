package com.huaxu.judging

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** 任务实况边界闹钟：开始 → 拉起实况服务；结束 → 移除实况。 */
class TaskLiveAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val phase = intent.getStringExtra("phase") ?: return
        when (phase) {
            "start" -> {
                val service = Intent(context, TaskLiveUpdateService::class.java).apply {
                    putExtra("id", intent.getStringExtra("id"))
                    putExtra("title", intent.getStringExtra("title"))
                    putExtra("startAt", intent.getLongExtra("startAt", 0L))
                    putExtra("endAt", intent.getLongExtra("endAt", 0L))
                }
                androidx.core.content.ContextCompat.startForegroundService(context, service)
            }
            "end" -> TaskLiveUpdateService.stop(context)
        }
    }
}
