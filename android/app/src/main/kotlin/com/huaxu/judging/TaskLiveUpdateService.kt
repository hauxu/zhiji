package com.huaxu.judging

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import androidx.core.content.edit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * 任务进行中实况：有开始/结束时间的任务
 * 进入进行时段后，以 ongoing 实况通知常驻（任务名+剩余分钟+进度），
 * 结束自动移除。支持 promoted 通知的 ROM（ColorOS 流体云/Android 16 实况窗）
 * 会把它提升为实况窗；小米超级岛开启时本服务让位给焦点通知。
 */
class TaskLiveUpdateService : Service() {

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var refreshJob: Job? = null
    private var payload: TaskLivePayload? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            clearPayload()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        // 小米超级岛开启：焦点通知直接投递，前台服务会盖住浮动岛，让位。
        if (FocusIsland.isEnabled(this)) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        TaskLiveScheduler.ensureChannel(this)
        val payload = intent?.toPayload() ?: restorePayload()
        if (payload == null || payload.shouldStop()) {
            clearPayload()
            stopSelf()
            return START_NOT_STICKY
        }
        this.payload = payload
        storePayload(payload)
        val notification = TaskLiveScheduler.buildLiveNotification(this, payload)
        startForeground(TaskLiveScheduler.LIVE_ID, notification)
        startRefreshLoop()
        return START_STICKY
    }

    override fun onDestroy() {
        refreshJob?.cancel()
        serviceScope.cancel()
        super.onDestroy()
    }

    private fun startRefreshLoop() {
        refreshJob?.cancel()
        refreshJob = serviceScope.launch {
            var first = true
            var renderedAt = System.currentTimeMillis()
            while (isActive) {
                val p = payload ?: break
                if (p.shouldStop()) {
                    clearPayload()
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    TaskLiveScheduler.cancelLiveNotification(this@TaskLiveUpdateService)
                    stopSelf()
                    return@launch
                }
                if (!first) {
                    renderedAt = System.currentTimeMillis()
                    val notification =
                        TaskLiveScheduler.buildLiveNotification(this@TaskLiveUpdateService, p)
                    startForeground(TaskLiveScheduler.LIVE_ID, notification)
                }
                first = false
                val now = System.currentTimeMillis()
                val next = p.nextRefreshAtMillis(renderedAt)
                if (next == null) {
                    if (p.shouldStop(now)) continue
                    break
                }
                delay((next - now).coerceAtLeast(1L))
            }
        }
    }

    private fun Intent.toPayload(): TaskLivePayload? {
        val id = getStringExtra("id") ?: return null
        return TaskLivePayload(
            id = id,
            title = getStringExtra("title").orEmpty().ifBlank { "任务" },
            startAtMillis = getLongExtra("startAt", 0L),
            endAtMillis = getLongExtra("endAt", 0L),
        )
    }

    private fun storePayload(p: TaskLivePayload) {
        getSharedPreferences(TaskLiveScheduler.Prefs, Context.MODE_PRIVATE).edit {
            putString("id", p.id)
                .putString("title", p.title)
                .putLong("startAt", p.startAtMillis)
                .putLong("endAt", p.endAtMillis)
        }
    }

    private fun restorePayload(): TaskLivePayload? {
        val prefs = getSharedPreferences(TaskLiveScheduler.Prefs, Context.MODE_PRIVATE)
        val id = prefs.getString("id", null) ?: return null
        val endAt = prefs.getLong("endAt", 0L)
        if (endAt <= System.currentTimeMillis()) return null
        return TaskLivePayload(
            id = id,
            title = prefs.getString("title", "任务").orEmpty(),
            startAtMillis = prefs.getLong("startAt", 0L),
            endAtMillis = endAt,
        )
    }

    private fun clearPayload() {
        payload = null
        getSharedPreferences(TaskLiveScheduler.Prefs, Context.MODE_PRIVATE).edit { clear() }
    }

    companion object {
        const val LIVE_ID = 20260601
        const val ACTION_STOP = "com.huaxu.judging.STOP_TASK_LIVE"

        fun stop(context: Context) {
            context.startService(
                Intent(context, TaskLiveUpdateService::class.java).setAction(ACTION_STOP))
        }
    }
}

/** 实况 payload：分钟文字/进度/停止判定。 */
data class TaskLivePayload(
    val id: String,
    val title: String,
    val startAtMillis: Long,
    val endAtMillis: Long,
) {
    fun shouldStop(now: Long = System.currentTimeMillis()): Boolean = now >= endAtMillis

    fun remainingMinutes(now: Long = System.currentTimeMillis()): Int =
        (((endAtMillis - now) + 59_999L) / 60_000L).toInt().coerceAtLeast(0)

    /** 分钟文字变化时刻与结束时刻的最早者（对齐目标秒，避免跳变）。 */
    fun nextRefreshAtMillis(now: Long): Long? {
        if (now >= endAtMillis) return null
        val minuteTick = now + 60_000L - (now % 60_000L)
        return minOf(minuteTick, endAtMillis).takeIf { it > now }
    }

    /** 已流逝百分比（0-100），用于进度条。 */
    fun progressPercent(now: Long): Int {
        val span = endAtMillis - startAtMillis
        if (span <= 0) return 0
        return (((now - startAtMillis) * 100) / span).toInt().coerceIn(0, 100)
    }
}
