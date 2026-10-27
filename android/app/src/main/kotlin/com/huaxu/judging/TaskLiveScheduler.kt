package com.huaxu.judging

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.content.edit
import org.json.JSONArray
import org.json.JSONObject

/**
 * 任务进行中实况的调度与通知构造：
 * 原生边界闹钟（开始/结束）+ ongoing 实况通知 + promoted 注入。
 */
internal object TaskLiveScheduler {
    const val Prefs = "zhiji_task_live"
    const val LIVE_ID = 20260601

    private const val ChannelId = "task_live_v1"
    private const val KeySchedules = "task_live_schedules"

    fun isEnabled(context: Context): Boolean {
        val sp = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        return sp.getBoolean("flutter.gd2_task_live", true)
    }

    fun ensureChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannel(
            NotificationChannel(ChannelId, "任务进行中", NotificationManager.IMPORTANCE_LOW).apply {
                description = "任务进行期间的常驻实况"
                setShowBadge(false)
                setSound(null, null)
                enableVibration(false)
            })
    }

    private fun alarmPendingIntent(context: Context, item: JSONObject, phase: String): PendingIntent {
        val intent = Intent(context, TaskLiveAlarmReceiver::class.java).apply {
            putExtra("phase", phase)
            putExtra("id", item.optString("id"))
            putExtra("title", item.optString("title"))
            putExtra("startAt", item.optLong("startAt"))
            putExtra("endAt", item.optLong("endAt"))
        }
        val code = (item.optString("id") + phase).hashCode()
        return PendingIntent.getBroadcast(
            context, code, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private fun scheduleAlarm(context: Context, triggerAt: Long, pending: PendingIntent) {
        val manager = context.getSystemService(AlarmManager::class.java) ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                !manager.canScheduleExactAlarms()) {
                manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pending)
            } else {
                manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pending)
            }
        } catch (e: SecurityException) {
            manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pending)
        }
    }

    /** 排一批任务实况边界闹钟（items：[{id,title,startAt,endAt}]），清单持久化。 */
    fun scheduleTaskLive(context: Context, items: JSONArray) {
        val store = JSONArray()
        val now = System.currentTimeMillis()
        for (i in 0 until items.length()) {
            val item = items.optJSONObject(i) ?: continue
            val startAt = item.optLong("startAt")
            val endAt = item.optLong("endAt")
            if (endAt <= now) continue
            if (startAt > now) {
                scheduleAlarm(context, startAt, alarmPendingIntent(context, item, "start"))
            } else {
                startLiveService(context, item)
            }
            scheduleAlarm(context, endAt, alarmPendingIntent(context, item, "end"))
            store.put(item)
        }
        context.getSharedPreferences(Prefs, Context.MODE_PRIVATE)
            .edit { putString(KeySchedules, store.toString()) }
    }

    fun cancelTaskLive(context: Context) {
        val manager = context.getSystemService(AlarmManager::class.java) ?: return
        val saved = context.getSharedPreferences(Prefs, Context.MODE_PRIVATE)
            .getString(KeySchedules, null) ?: return
        runCatching {
            val items = JSONArray(saved)
            for (i in 0 until items.length()) {
                val item = items.optJSONObject(i) ?: continue
                manager.cancel(alarmPendingIntent(context, item, "start"))
                manager.cancel(alarmPendingIntent(context, item, "end"))
            }
        }
        context.getSharedPreferences(Prefs, Context.MODE_PRIVATE)
            .edit { remove(KeySchedules) }
        TaskLiveUpdateService.stop(context)
    }

    private fun startLiveService(context: Context, item: JSONObject) {
        val intent = Intent(context, TaskLiveUpdateService::class.java).apply {
            putExtra("id", item.optString("id"))
            putExtra("title", item.optString("title"))
            putExtra("startAt", item.optLong("startAt"))
            putExtra("endAt", item.optLong("endAt"))
        }
        androidx.core.content.ContextCompat.startForegroundService(context, intent)
    }

    /** 重启/覆盖安装后按持久化清单重建（过期丢弃；进行中的立即拉起）。 */
    fun restoreFromPrefs(context: Context) {
        val saved = context.getSharedPreferences(Prefs, Context.MODE_PRIVATE)
            .getString(KeySchedules, null) ?: return
        runCatching {
            val items = JSONArray(saved)
            val now = System.currentTimeMillis()
            val alive = JSONArray()
            for (i in 0 until items.length()) {
                val item = items.optJSONObject(i) ?: continue
                val endAt = item.optLong("endAt")
                if (endAt <= now) continue
                val startAt = item.optLong("startAt")
                if (startAt > now) {
                    scheduleAlarm(context, startAt, alarmPendingIntent(context, item, "start"))
                } else {
                    startLiveService(context, item)
                }
                scheduleAlarm(context, endAt, alarmPendingIntent(context, item, "end"))
                alive.put(item)
            }
            context.getSharedPreferences(Prefs, Context.MODE_PRIVATE)
                .edit { putString(KeySchedules, alive.toString()) }
        }
    }

    /** ongoing 实况通知：显式剩余分钟 + 进度 + promoted 注入（实况窗）。 */
    fun buildLiveNotification(context: Context, p: TaskLivePayload): Notification {
        ensureChannel(context)
        val now = System.currentTimeMillis()
        val remaining = p.remainingMinutes(now)
        val body = if (remaining > 0) "剩余 $remaining 分钟" else "即将结束"
        val promoted = PromotedNotifications.capable(context)
        val builder = Notification.Builder(context, ChannelId)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle(p.title)
            .setContentText(body)
            .setContentIntent(openApp(context))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(if (promoted) Notification.CATEGORY_PROGRESS else Notification.CATEGORY_EVENT)
        if (Build.VERSION.SDK_INT >= 36) {
            try {
                val style = Notification.ProgressStyle()
                    .setProgressSegments(listOf(Notification.ProgressStyle.Segment(100)))
                    .setProgress(p.progressPercent(now))
                builder.setStyle(style)
            } catch (_: Exception) {
                builder.setProgress(100, p.progressPercent(now), false)
            }
        } else {
            builder.setProgress(100, p.progressPercent(now), false)
        }
        PromotedNotifications.apply(builder, body, promoted)
        return builder.build()
    }

    private fun openApp(context: Context): PendingIntent = PendingIntent.getActivity(
        context, 1,
        Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    fun cancelLiveNotification(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.cancel(LIVE_ID)
    }
}

/** promoted（实况窗）注入：官方 API 优先，反射与 extras 双写保底。 */
internal object PromotedNotifications {
    private const val ExtraPromotedOngoing = "android.requestPromotedOngoing"
    private const val ExtraShortCriticalText = "android.shortCriticalText"

    fun capable(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 36) return false
        return runCatching {
            val nm = context.getSystemService(NotificationManager::class.java)
            nm?.canPostPromotedNotifications() == true
        }.getOrDefault(false)
    }

    fun apply(builder: Notification.Builder, shortText: String, promoted: Boolean) {
        runCatching {
            val m = Notification.Builder::class.java.getMethod(
                "setRequestPromotedOngoing", Boolean::class.javaPrimitiveType)
            m.invoke(builder, true)
        }
        runCatching {
            val m = Notification.Builder::class.java.getMethod(
                "setShortCriticalText", CharSequence::class.java)
            m.invoke(builder, shortText)
        }
        builder.extras.putBoolean(ExtraPromotedOngoing, promoted)
        builder.extras.putCharSequence(ExtraShortCriticalText, shortText)
    }
}
