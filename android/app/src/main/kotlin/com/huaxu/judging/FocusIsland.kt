package com.huaxu.judging

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import org.json.JSONArray
import org.json.JSONObject
import java.lang.reflect.Method

/**
 * 小米 HyperOS「焦点通知/超级岛」协议：
 * 往通知 extras 写 miui.focus.param（param_v2 JSON）让系统在灵动岛弹胶囊，
 * 倒计时数字由系统 timerInfo 自行跳动。不需要任何服务器或推送通道。
 */
internal object FocusIsland {
    const val ChannelId = "focus_island_v1"
    const val FocusParameter = "miui.focus.param"
    private const val SmallPicture = "miui.focus.pic_small"
    private const val Prefs = "zhiji_focus_island"
    private const val KeySchedules = "island_schedules"
    private const val KeySequence = "island_sequence"

    fun isXiaomiDevice(manufacturer: String, brand: String): Boolean =
        listOf(manufacturer, brand).any {
            it.equals("xiaomi", true) || it.equals("redmi", true) || it.equals("poco", true)
        }

    fun isXiaomiDevice(context: Context): Boolean =
        isXiaomiDevice(Build.MANUFACTURER.orEmpty(), Build.BRAND.orEmpty())

    /** HyperOS 灵动岛系统开关（第三方应用只读探测）。 */
    fun isSystemSupported(): Boolean = runCatching {
        val sp = Class.forName("android.os.SystemProperties")
        val get: Method = sp.getMethod(
            "getBoolean", String::class.java, Boolean::class.javaPrimitiveType)
        get.invoke(null, "persist.sys.feature.island", false) as Boolean
    }.getOrDefault(false)

    /**
     * 焦点通知权限（小米把它与通知权限分开管理）。
     * null = 探测不可用（非小米/老版本），此时按「不拦截」处理。
     */
    fun canShowFocus(context: Context): Boolean? = runCatching {
        val extras = Bundle().apply { putString("package", context.packageName) }
        context.contentResolver.call(
            android.net.Uri.parse("content://miui.statusbar.notification.public"),
            "canShowFocus", null, extras,
        )?.getBoolean("canShowFocus")
    }.getOrNull()

    fun status(context: Context): java.util.HashMap<String, Any?> {
        val map = java.util.HashMap<String, Any?>()
        map["isXiaomi"] = isXiaomiDevice(context)
        map["systemSupported"] = isSystemSupported()
        map["canShowFocus"] = canShowFocus(context)
        return map
    }

    fun isEnabled(context: Context): Boolean {
        val prefs = context.getSharedPreferences(Prefs, Context.MODE_PRIVATE)
        return prefs.getBoolean("enabled", false) && isXiaomiDevice(context)
    }

    fun setEnabled(context: Context, enabled: Boolean) {
        context.getSharedPreferences(Prefs, Context.MODE_PRIVATE)
            .edit().putBoolean("enabled", enabled).apply()
    }

    fun ensureChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannel(
            NotificationChannel(ChannelId, "超级岛提醒", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "以灵动岛胶囊弹出的到点提醒"
                setShowBadge(true)
            })
    }

    private fun nextSequence(context: Context): Long {
        val prefs = context.getSharedPreferences(Prefs, Context.MODE_PRIVATE)
        val next = maxOf(
            prefs.getLong(KeySequence, 0L),
            System.currentTimeMillis(),
        ) + 1L
        prefs.edit().putLong(KeySequence, next).commit()
        return next
    }

    /** 组装 param_v2 JSON（按一次性提醒简化）。 */
    internal fun parameters(
        title: String,
        bodyText: String,
        countdownTargetMillis: Long,
        nowMillis: Long,
        timeoutSeconds: Int,
        sequenceValue: Long,
    ): String {
        val card = JSONObject()
            .put("type", 2)
            .put("title", title)
            .put("content", bodyText)
            .put("subTitle", "").put("subContent", "")
            .put("extraTitle", "").put("specialTitle", "")
            .put("showDivider", true).put("showContentDivider", false)
            .put("colorTitle", "#111111").put("colorTitleDark", "#ffffff")
            .put("colorContent", "#333333").put("colorContentDark", "#cccccc")
        val hint = JSONObject()
            .put("type", 2)
            .put("content", "之计提醒")
            .put("title", "")
            .put("subContent", "").put("subTitle", "")
            .put("colorContent", "#666666").put("colorContentDark", "#aaaaaa")
            .put("colorTitle", "#222222").put("colorTitleDark", "#eeeeee")
            .put("timerInfo", timerInfo(countdownTargetMillis, nowMillis))
        val island = JSONObject()
            .put("islandProperty", 1)
            .put("islandTimeout", timeoutSeconds.toLong().coerceIn(60L, 43_200L))
            .put("bigIslandArea", JSONObject()
                .put("templateNo", 2)
                .put("imageTextInfoLeft", JSONObject()
                    .put("type", 1)
                    .put("textInfo", JSONObject()
                        .put("title", title).put("content", "")
                        .put("showHighlightColor", false).put("narrowFont", false)))
                .put("textInfo", JSONObject()
                    .put("frontTitle", "").put("title", title).put("content", "")
                    .put("showHighlightColor", false).put("narrowFont", false)))
            .put("smallIslandArea", JSONObject()
                .put("picInfo", JSONObject()
                    .put("type", 1)
                    .put("pic", SmallPicture)
                    .put("picDark", "miui.focus.pic_small_dark")))
        val parameters = JSONObject()
            .put("protocol", 1)
            .put("business", "zhiji_reminder")
            .put("enableFloat", true)
            .put("updatable", true)
            .put("outEffectSrc", "outer_glow")
            .put("islandFirstFloat", true)
            .put("aodTitle", title)
            .put("reopen", "reopen")
            .put("sequence", sequenceValue)
            .put("baseInfo", card)
            .put("picInfo", JSONObject().put("type", 1).put("pic", ""))
            .put("hintInfo", hint)
            .put("param_island", island)
        return JSONObject().put("param_v2", parameters).toString()
    }

    private fun timerInfo(targetMillis: Long?, nowMillis: Long): JSONObject {
        val countdown = (targetMillis ?: 0L) > 0
        val info = JSONObject()
        info.put("timerType", if (countdown) -1 else 0)
        info.put("timerWhen", if (countdown) targetMillis else 0L)
        info.put("timerTotal", 0L)
        info.put("timerSystemCurrent", if (countdown) nowMillis else 0L)
        return info
    }

    /** 构造带焦点协议 extras 的通知。 */
    fun buildNotification(
        context: Context,
        title: String,
        bodyText: String,
        paramJson: String,
        timeoutMillis: Long,
    ): Notification {
        ensureChannel(context)
        val appIcon = Icon.createWithResource(context, R.mipmap.ic_launcher)
        val openApp = PendingIntent.getActivity(
            context, 0,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = Notification.Builder(context, ChannelId)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(bodyText)
            .setContentIntent(openApp)
            .setAutoCancel(false)
        if (timeoutMillis > System.currentTimeMillis()) {
            notification.setTimeoutAfter(timeoutMillis - System.currentTimeMillis())
        }
        notification.extras.putString(FocusParameter, paramJson)
        notification.extras.putBundle("miui.focus.pics", Bundle().apply {
            putParcelable("miui.focus.pic_app_icon", appIcon)
            putParcelable("miui.focus.pic_app_icon_dark", appIcon)
            putParcelable(SmallPicture, appIcon)
            putParcelable("miui.focus.pic_small_dark", appIcon)
        })
        return notification.build()
    }

    fun notifyNow(
        context: Context,
        id: Int,
        title: String,
        bodyText: String,
        paramJson: String,
        timeoutMillis: Long,
    ): Boolean {
        return try {
            ensureChannel(context)
            val notification = buildNotification(context, title, bodyText, paramJson, timeoutMillis)
            val manager = context.getSystemService(NotificationManager::class.java) ?: return false
            manager.notify(id, notification)
            true
        } catch (e: SecurityException) {
            false
        }
    }

    private fun alarmPendingIntent(context: Context, item: JSONObject): PendingIntent {
        val intent = Intent(context, IslandAlarmReceiver::class.java).apply {
            putExtra("id", item.optInt("id"))
            putExtra("title", item.optString("title"))
            putExtra("body", item.optString("body"))
            putExtra("target", item.optLong("target"))
            putExtra("timeout", item.optLong("timeout"))
        }
        return PendingIntent.getBroadcast(
            context, item.optInt("id"), intent,
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

    /** 排一批岛闹钟并持久化清单（重启后由 IslandBootReceiver 重建）。 */
    fun scheduleIslands(context: Context, items: JSONArray) {
        val manager = context.getSystemService(AlarmManager::class.java) ?: return
        val store = JSONArray()
        val now = System.currentTimeMillis()
        for (i in 0 until items.length()) {
            val item = items.optJSONObject(i) ?: continue
            val triggerAt = item.optLong("time")
            val timeout = item.optLong("timeout")
            if (triggerAt <= now || timeout <= now) continue
            try {
                scheduleAlarm(context, triggerAt, alarmPendingIntent(context, item))
                store.put(item)
            } catch (e: Exception) {
                continue
            }
        }
        context.getSharedPreferences(Prefs, Context.MODE_PRIVATE)
            .edit().putString(KeySchedules, store.toString()).apply()
    }

    fun cancelIslands(context: Context) {
        val manager = context.getSystemService(AlarmManager::class.java) ?: return
        val saved = context.getSharedPreferences(Prefs, Context.MODE_PRIVATE)
            .getString(KeySchedules, null) ?: return
        runCatching {
            val items = JSONArray(saved)
            for (i in 0 until items.length()) {
                val item = items.optJSONObject(i) ?: continue
                manager.cancel(alarmPendingIntent(context, item))
            }
        }
        context.getSharedPreferences(Prefs, Context.MODE_PRIVATE)
            .edit().remove(KeySchedules).apply()
    }

    /** 重启/覆盖安装后按持久化清单重建（过期条目自动丢弃）。 */
    fun restoreFromPrefs(context: Context) {
        val saved = context.getSharedPreferences(Prefs, Context.MODE_PRIVATE)
            .getString(KeySchedules, null) ?: return
        runCatching {
            val items = JSONArray(saved)
            val now = System.currentTimeMillis()
            val alive = JSONArray()
            for (i in 0 until items.length()) {
                val item = items.optJSONObject(i) ?: continue
                if (item.optLong("timeout") <= now || item.optLong("time") <= now) continue
                scheduleAlarm(context, item.optLong("time"), alarmPendingIntent(context, item))
                alive.put(item)
            }
            context.getSharedPreferences(Prefs, Context.MODE_PRIVATE)
                .edit().putString(KeySchedules, alive.toString()).apply()
        }
    }
}
