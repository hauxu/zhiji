package com.huaxu.judging

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 岛闹钟到点：以触发时刻为基准组装焦点协议（倒计时基准才准），
 * 原生构造通知弹灵动岛，无 Dart 参与。
 */
class IslandAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getIntExtra("id", 0)
        val title = intent.getStringExtra("title") ?: return
        val body = intent.getStringExtra("body") ?: ""
        val target = intent.getLongExtra("target", 0L)
        val timeout = intent.getLongExtra("timeout", 0L)
        val now = System.currentTimeMillis()
        if (timeout in 1..now) return
        val param = FocusIsland.parameters(
            title = title,
            bodyText = body,
            countdownTargetMillis = target,
            nowMillis = now,
            timeoutSeconds = (((timeout - now + 999) / 1000).toInt()).coerceIn(60, 43_200),
            sequenceValue = now,
        )
        FocusIsland.notifyNow(context, id, title, body, param, timeout)
    }
}
